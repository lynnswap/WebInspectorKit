#if canImport(AppKit)
import AppKit
import ObservationBridge
import WebInspectorRuntime

@MainActor
public final class WIConsoleViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let inspector: WIConsoleModel
    private var observationHandles: Set<ObservationHandle> = []
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField(frame: .zero)
    private let runButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)

    public init(inspector: WIConsoleModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let rootView = NSView(frame: .zero)
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = NSStackView(views: [inputField, runButton, clearButton])
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.alignment = .centerY

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 56
        let column = NSTableColumn(identifier: .init("console"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        scrollView.documentView = tableView

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.maximumNumberOfLines = 0

        inputField.placeholderString = wiLocalized("console.prompt.placeholder", default: "Enter JavaScript")
        inputField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        inputField.delegate = self

        runButton.title = wiLocalized("console.controls.run", default: "Run")
        runButton.target = self
        runButton.action = #selector(handleRunButton)

        clearButton.title = wiLocalized("console.controls.clear", default: "Clear")
        clearButton.target = self
        clearButton.action = #selector(handleClearButton)

        rootView.addSubview(scrollView)
        rootView.addSubview(emptyStateLabel)
        rootView.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            bottomBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            bottomBar.leadingAnchor.constraint(equalTo: rootView.layoutMarginsGuide.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: rootView.layoutMarginsGuide.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -8),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.layoutMarginsGuide.leadingAnchor),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.layoutMarginsGuide.trailingAnchor),

            inputField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        view = rootView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        startObservingInspector()
        reloadData()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        inspector.store.entries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        _ = tableColumn
        guard inspector.store.entries.indices.contains(row) else {
            return nil
        }
        let entry = inspector.store.entries[row]
        let identifier = NSUserInterfaceItemIdentifier("WIConsoleRow")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? WIConsoleTableCellView)
            ?? WIConsoleTableCellView(frame: .zero)
        view.identifier = identifier
        view.configure(entry: entry)
        return view
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        _ = control
        _ = textView
        guard commandSelector == #selector(insertNewline(_:)) else {
            return false
        }
        runCurrentExpression()
        return true
    }

    private func startObservingInspector() {
        inspector.store.observeTask(
            \.entriesGeneration,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.reloadData()
        }
        .store(in: &observationHandles)

        inspector.observeTask(
            \.isAttachedToPage,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.reloadData()
        }
        .store(in: &observationHandles)
    }

    private func reloadData() {
        let shouldStickToBottom = isScrolledNearBottom
        tableView.reloadData()
        if shouldStickToBottom, inspector.store.entries.isEmpty == false {
            tableView.scrollRowToVisible(inspector.store.entries.count - 1)
        }
        updateEmptyState()
    }

    private var isScrolledNearBottom: Bool {
        guard let contentView = scrollView.contentView as NSClipView?,
              let documentView = scrollView.documentView else {
            return true
        }
        let visibleMaxY = contentView.bounds.maxY
        return visibleMaxY >= documentView.frame.height - 24
    }

    private func updateEmptyState() {
        let isUnsupported = inspector.backendSupport.isSupported == false
        if isUnsupported {
            emptyStateLabel.stringValue = inspector.backendSupport.failureReason
                ?? wiLocalized("console.unavailable.description", default: "Console is unavailable on this WebKit runtime.")
        } else if inspector.store.entries.isEmpty {
            emptyStateLabel.stringValue = inspector.isAttachedToPage
                ? wiLocalized("console.empty.description", default: "No console messages yet.")
                : wiLocalized("console.disconnected.description", default: "Connect a page to start receiving console messages.")
        } else {
            emptyStateLabel.stringValue = ""
        }

        let shouldShowEmptyState = inspector.store.entries.isEmpty
        emptyStateLabel.isHidden = shouldShowEmptyState == false
        scrollView.isHidden = false
    }

    @objc
    private func handleRunButton() {
        runCurrentExpression()
    }

    @objc
    private func handleClearButton() {
        Task { [weak self] in
            await self?.inspector.clear()
        }
    }

    private func runCurrentExpression() {
        let expression = inputField.stringValue
        guard expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        inputField.stringValue = ""
        Task { [weak self] in
            await self?.inspector.evaluate(expression)
        }
    }

    var emptyStateTextForTesting: String {
        emptyStateLabel.stringValue
    }

    var rowCountForTesting: Int {
        inspector.store.entries.count
    }

    var tableViewWidthForTesting: CGFloat {
        tableView.frame.width
    }
}

@MainActor
private final class WIConsoleTableCellView: NSTableCellView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.maximumNumberOfLines = 2

        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.font = .preferredFont(forTextStyle: .caption1)
        secondaryLabel.lineBreakMode = .byTruncatingMiddle
        secondaryLabel.maximumNumberOfLines = 1

        let stack = NSStackView(views: [primaryLabel, secondaryLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(entry: WIConsoleEntry) {
        primaryLabel.stringValue = entry.renderedText
        primaryLabel.font = switch entry.kind {
        case .command:
            .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        case .result:
            .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case .message:
            .preferredFont(forTextStyle: .body)
        }

        var parts: [String] = []
        parts.append(DateFormatter.wiConsoleTimestampFormatter.string(from: entry.timestamp))
        parts.append(entry.source.rawValue)
        parts.append(entry.level.rawValue)
        if let location = entry.location {
            let lineDescription = location.line.map(String.init) ?? "?"
            parts.append("\(location.url):\(lineDescription)")
        } else if let firstFrame = entry.stackFrames.first {
            let lineDescription = firstFrame.line.map(String.init) ?? "?"
            parts.append("\(firstFrame.url):\(lineDescription)")
        }
        if entry.repeatCount > 1 {
            parts.append("x\(entry.repeatCount)")
        }
        secondaryLabel.stringValue = parts.joined(separator: "  ")
    }
}

private extension DateFormatter {
    static let wiConsoleTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
#endif
