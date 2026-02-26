import OSLog
import WebKit
import WebInspectorEngine
import WebInspectorScripts
#if canImport(AppKit)
import AppKit
#endif

private let domTreeViewLogger = Logger(subsystem: "WebInspectorKit", category: "DOMTreeView")

@MainActor
final class InspectorWebView: WKWebView {
#if canImport(AppKit)
    var domContextMenuProvider: ((Int?) -> NSMenu?)?
#endif

    convenience init() {
        self.init(frame: .zero, configuration: Self.makeDefaultConfiguration())
    }
    
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        Self.installDOMTreeViewScriptsIfNeeded(on: configuration.userContentController)
        applyInspectorDefaults()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private static func makeDefaultConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.writingToolsBehavior = .none
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController = makeInspectorContentController()
        return configuration
    }

    private static func makeInspectorContentController() -> WKUserContentController {
        let controller = WKUserContentController()
        installDOMTreeViewScriptsIfNeeded(on: controller)
        return controller
    }

    private static func installDOMTreeViewScriptsIfNeeded(on controller: WKUserContentController) {
        let existingSources = Set(controller.userScripts.map(\.source))
        do {
            let scriptSource = try WebInspectorScripts.domTreeView()
            if existingSources.contains(scriptSource) {
                return
            }
            controller.addUserScript(
                WKUserScript(
                    source: scriptSource,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        } catch {
            domTreeViewLogger.error("missing DOMTreeView script: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func applyInspectorDefaults() {
#if DEBUG
        isInspectable = true
#endif
        
#if canImport(UIKit)
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = true
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.automaticallyAdjustsScrollIndicatorInsets = true
        scrollView.clipsToBounds = true
        clipsToBounds = true
#endif
    }
    
#if canImport(UIKit)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        
        guard builder.system == .context else { return }
        
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
    
    }
#endif

#if canImport(AppKit)
    override func rightMouseDown(with event: NSEvent) {
        guard let domContextMenuProvider else {
            super.rightMouseDown(with: event)
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        let nodeID = resolveTreeNodeIDSynchronously(at: localPoint)
        guard let menu = domContextMenuProvider(nodeID) else {
            return
        }
        sanitizeContextMenu(menu)
        menu.popUp(positioning: nil, at: localPoint, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let localPoint = convert(event.locationInWindow, from: nil)
        let nodeID = resolveTreeNodeIDSynchronously(at: localPoint)
        guard let menu = domContextMenuProvider?(nodeID) else {
            return nil
        }
        sanitizeContextMenu(menu)
        return menu
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        sanitizeContextMenu(menu)
        super.willOpenMenu(menu, with: event)
    }

    private func sanitizeContextMenu(_ menu: NSMenu) {
        for item in menu.items.reversed() {
            if shouldRemoveMenuItem(item) {
                menu.removeItem(item)
                continue
            }
            if let submenu = item.submenu {
                sanitizeContextMenu(submenu)
            }
        }

        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(at: 0)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    private func shouldRemoveMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action {
            if action == #selector(reload(_:)) {
                return true
            }
            if String(describing: action).localizedCaseInsensitiveContains("reload") {
                return true
            }
        }
        return item.title.localizedCaseInsensitiveContains("reload")
    }

    private func resolveTreeNodeIDSynchronously(at point: CGPoint) -> Int? {
        let clampedX = max(0, min(point.x, bounds.width))
        let clampedY = max(0, min(point.y, bounds.height))
        let viewportY = isFlipped ? clampedY : (bounds.height - clampedY)
        let jsCoordinateStyle = FloatingPointFormatStyle<Double>.number
            .locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never)
            .precision(.fractionLength(4))
        let jsX = Double(clampedX).formatted(jsCoordinateStyle)
        let jsY = Double(viewportY).formatted(jsCoordinateStyle)
        let script = """
        (function() {
            const hoveredNodeID = Number(window.__wiLastDOMTreeHoveredNodeId);
            if (Number.isFinite(hoveredNodeID)) {
                return hoveredNodeID;
            }
            const contextNodeID = Number(window.__wiLastDOMTreeContextNodeId);
            if (Number.isFinite(contextNodeID)) {
                return contextNodeID;
            }
            const x = \(jsX);
            const y = \(jsY);
            const samples = [
                [x, y],
                [x, y + 2],
                [x, y - 2],
                [x, y + 6],
                [x, y - 6],
            ];
            const height = window.innerHeight || document.documentElement.clientHeight || 0;
            for (const sample of samples) {
                const sy = sample[1];
                if (sy < 0 || sy > height) {
                    continue;
                }
                const element = document.elementFromPoint(sample[0], sy);
                const node = element && element.closest ? element.closest('.tree-node') : null;
                if (!node) {
                    continue;
                }
                const rawNodeID = Number(node.dataset && node.dataset.nodeId);
                if (Number.isFinite(rawNodeID)) {
                    return rawNodeID;
                }
            }
            return null;
        })()
        """
        var resolvedNodeID: Int?
        var finished = false

        evaluateJavaScript(script) { result, error in
            defer { finished = true }
            guard error == nil else {
                return
            }
            if let number = result as? NSNumber {
                resolvedNodeID = number.intValue
                return
            }
            if let string = result as? String, let value = Int(string) {
                resolvedNodeID = value
            }
        }

        let deadline = Date().addingTimeInterval(0.25)
        while finished == false, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }

        return resolvedNodeID
    }
#endif
}
