#if canImport(AppKit)
import AppKit

extension InspectorWebView {
    func wiHandleRightMouseDown(_ event: NSEvent) -> Bool {
        guard let domContextMenuProvider else {
            return false
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        let nodeID = resolveTreeNodeIDSynchronously(at: localPoint)
        guard let menu = domContextMenuProvider(nodeID) else {
            return false
        }

        wiSanitizeContextMenu(menu)
        menu.popUp(positioning: nil, at: localPoint, in: self)
        return true
    }

    func wiContextMenu(for event: NSEvent) -> NSMenu? {
        let localPoint = convert(event.locationInWindow, from: nil)
        let nodeID = resolveTreeNodeIDSynchronously(at: localPoint)
        guard let menu = domContextMenuProvider?(nodeID) else {
            return nil
        }
        wiSanitizeContextMenu(menu)
        return menu
    }

    func wiSanitizeContextMenu(_ menu: NSMenu) {
        for item in menu.items.reversed() {
            if wiShouldRemoveMenuItem(item) {
                menu.removeItem(item)
                continue
            }
            if let submenu = item.submenu {
                wiSanitizeContextMenu(submenu)
            }
        }

        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(at: 0)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    func wiShouldRemoveMenuItem(_ item: NSMenuItem) -> Bool {
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

    func resolveTreeNodeIDSynchronously(at point: CGPoint) -> Int? {
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
}
#endif
