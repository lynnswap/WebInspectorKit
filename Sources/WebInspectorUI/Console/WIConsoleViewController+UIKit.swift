#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorRuntime

@MainActor
public final class WIConsoleViewController: UIViewController, UICollectionViewDelegate {
    private enum SectionIdentifier: Hashable {
        case main
    }

    private let inspector: WIConsoleModel
    private var observationHandles: Set<ObservationHandle> = []
    private let inputField = UITextField(frame: .zero)
    private let runButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let emptyStateLabel = UILabel(frame: .zero)
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private lazy var dataSource = makeDataSource()

    public init(inspector: WIConsoleModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureBottomBar()
        configureEmptyState()
        startObservingInspector()
        reloadData()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadData()
    }

    private static func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = true
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureBottomBar() {
        let bar = UIStackView(arrangedSubviews: [inputField, runButton, clearButton])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.axis = .horizontal
        bar.spacing = 8
        bar.alignment = .fill

        inputField.borderStyle = .roundedRect
        inputField.placeholder = wiLocalized("console.prompt.placeholder", default: "Enter JavaScript")
        inputField.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.returnKeyType = .go
        inputField.clearButtonMode = .whileEditing
        inputField.addTarget(self, action: #selector(handleReturnKey), for: .editingDidEndOnExit)

        runButton.setTitle(wiLocalized("console.controls.run", default: "Run"), for: .normal)
        runButton.addTarget(self, action: #selector(handleRunButton), for: .touchUpInside)

        clearButton.setTitle(wiLocalized("console.controls.clear", default: "Clear"), for: .normal)
        clearButton.addTarget(self, action: #selector(handleClearButton), for: .touchUpInside)

        view.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: collectionView.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            inputField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    private func configureEmptyState() {
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = UIFont.preferredFont(forTextStyle: .body)
        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, WIConsoleEntry> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, WIConsoleEntry> { [weak self] cell, _, item in
            self?.configureCell(cell, entry: item)
        }

        return UICollectionViewDiffableDataSource<SectionIdentifier, WIConsoleEntry>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: item
            )
        }
    }

    private func configureCell(_ cell: UICollectionViewListCell, entry: WIConsoleEntry) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.renderedText
        content.secondaryText = secondaryText(for: entry)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 2
        content.textProperties.font = font(for: entry)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: 16 + CGFloat(entry.nestingLevel * 12),
            bottom: 8,
            trailing: 16
        )
        cell.accessories = entry.repeatCount > 1 ? [
            .label(
                text: "x\(entry.repeatCount)",
                options: .init(reservedLayoutWidth: .actual)
            )
        ] : []
    }

    private func font(for entry: WIConsoleEntry) -> UIFont {
        let basePointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        switch entry.kind {
        case .command:
            return .monospacedSystemFont(ofSize: basePointSize, weight: .semibold)
        case .result:
            return .monospacedSystemFont(ofSize: basePointSize, weight: .regular)
        case .message:
            return .preferredFont(forTextStyle: .body)
        }
    }

    private func secondaryText(for entry: WIConsoleEntry) -> String {
        var parts: [String] = []
        parts.append(DateFormatter.wiConsoleTimestampFormatter.string(from: entry.timestamp))
        parts.append(entry.source.rawValue)
        parts.append(entry.level.rawValue)
        if let location = entry.location {
            let lineDescription = location.line.map(String.init) ?? "?"
            parts.append("\(location.url):\(lineDescription)")
        } else if let stackFrame = entry.stackFrames.first {
            let lineDescription = stackFrame.line.map(String.init) ?? "?"
            parts.append("\(stackFrame.url):\(lineDescription)")
        }
        return parts.joined(separator: "  ")
    }

    private func reloadData() {
        let entries = inspector.store.entries
        let shouldStickToBottom = isScrolledNearBottom

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, WIConsoleEntry>()
        snapshot.appendSections([.main])
        snapshot.appendItems(entries, toSection: .main)

        Task { @MainActor in
            await dataSource.apply(snapshot, animatingDifferences: false)
            if shouldStickToBottom, let lastEntry = entries.last {
                self.scrollToEntry(lastEntry)
            }
            self.updateEmptyState()
        }
    }

    private var isScrolledNearBottom: Bool {
        guard collectionView.contentSize.height > 0 else {
            return true
        }
        let visibleMaxY = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return visibleMaxY >= collectionView.contentSize.height - 24
    }

    private func scrollToEntry(_ entry: WIConsoleEntry) {
        guard let indexPath = dataSource.indexPath(for: entry) else {
            return
        }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
    }

    private func updateEmptyState() {
        let isUnsupported = inspector.backendSupport.isSupported == false
        if isUnsupported {
            emptyStateLabel.text = inspector.backendSupport.failureReason
                ?? wiLocalized("console.unavailable.description", default: "Console is unavailable on this WebKit runtime.")
        } else if inspector.store.entries.isEmpty {
            emptyStateLabel.text = inspector.isAttachedToPage
                ? wiLocalized("console.empty.description", default: "No console messages yet.")
                : wiLocalized("console.disconnected.description", default: "Connect a page to start receiving console messages.")
        } else {
            emptyStateLabel.text = nil
        }

        let shouldShowEmptyState = inspector.store.entries.isEmpty
        emptyStateLabel.isHidden = shouldShowEmptyState == false
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

    @objc
    private func handleReturnKey() {
        runCurrentExpression()
    }

    private func runCurrentExpression() {
        let expression = inputField.text ?? ""
        guard expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        inputField.text = nil
        Task { [weak self] in
            await self?.inspector.evaluate(expression)
        }
    }

    var emptyStateTextForTesting: String? {
        emptyStateLabel.text
    }

    var rowCountForTesting: Int {
        inspector.store.entries.count
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
