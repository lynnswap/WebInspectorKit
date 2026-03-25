import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
private enum WINetworkHeaderRole {
    case request
    case response
}

@MainActor
final class WINetworkDetailViewController: NSViewController {
    private struct DetailStructureState: Equatable {
        let requestBodyIdentity: ObjectIdentifier?
        let responseBodyIdentity: ObjectIdentifier?
        let hasError: Bool
    }

    private let inspector: WINetworkModel
    private var observationHandles: Set<ObservationHandle> = []
    private var selectedEntryStructureObservationHandles: Set<ObservationHandle> = []

    private let scrollView = NSScrollView()
    private let documentView = WINetworkFlippedContentView()
    private let contentStack = NSStackView()
    private let emptyStateView = WINetworkAppKitViewFactory.makeEmptyStateView(
        title: wiLocalized("network.empty.title"),
        description: wiLocalized("network.empty.description")
    )

    private weak var requestBodyButton: NSButton?
    private weak var responseBodyButton: NSButton?
    private var renderedSectionTitles: [String] = []
    private var displayedEntryID: UUID?
    private var displayedStructureState: DetailStructureState?

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var renderedSectionTitlesForTesting: [String] {
        renderedSectionTitles
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    var hasVisibleContentForTesting: Bool {
        scrollView.isHidden == false
    }

    var requestBodyButtonForTesting: NSButton? {
        requestBodyButton
    }

    var responseBodyButtonForTesting: NSButton? {
        responseBodyButton
    }

    var presentedBodyPreviewViewControllerForTesting: WINetworkBodyPreviewViewController? {
        presentedViewControllers?.first as? WINetworkBodyPreviewViewController
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        startObservingInspector()
        display(inspector.selectedEntry)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let insetWidth: CGFloat = 32
        let contentWidth = max(view.bounds.width - insetWidth, 320)
        let stackWidth = contentWidth - 32
        contentStack.frame = CGRect(
            x: 16,
            y: 16,
            width: stackWidth,
            height: max(contentStack.frame.height, 1)
        )
        contentStack.layoutSubtreeIfNeeded()
        let fittingSize = contentStack.fittingSize
        documentView.frame = CGRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: max(fittingSize.height + 32, scrollView.contentSize.height)
        )
        contentStack.frame = CGRect(x: 16, y: 16, width: stackWidth, height: fittingSize.height)
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.detachesHiddenViews = true
        documentView.addSubview(contentStack)

        scrollView.documentView = documentView

        view.addSubview(scrollView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func startObservingInspector() {
        inspector.observe(
            [\.selectedEntry],
            onChange: { [weak self] in
                guard let self else {
                    return
                }
                self.display(self.inspector.selectedEntry)
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)
    }

    func display(_ entry: NetworkEntry?) {
        let structureState = makeStructureState(for: entry)
        let entryDidChange = displayedEntryID != entry?.id
        let needsRebuild = entryDidChange || displayedStructureState != structureState
        if entryDidChange {
            dismissPresentedBodyPreviewIfNeeded()
        }
        displayedEntryID = entry?.id
        displayedStructureState = structureState
        selectedEntryStructureObservationHandles.removeAll()
        if needsRebuild {
            rebuildContent(for: entry)
        }
        updateVisibility()
        guard let entry else {
            return
        }
        startObservingEntryStructure(entry)
    }

    func updateVisibility() {
        let hasEntries = inspector.store.entries.isEmpty == false
        let hasSelection = inspector.selectedEntry != nil
        scrollView.isHidden = hasSelection == false
        emptyStateView.isHidden = hasEntries
    }

    private func startObservingEntryStructure(_ entry: NetworkEntry) {
        let initialStructureState = makeStructureState(for: entry)
        var ignoresInitialEmission = true
        entry.observe(
            [\.requestBody, \.responseBody, \.errorDescription],
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                let currentStructureState = self.makeStructureState(for: entry)
                if ignoresInitialEmission {
                    ignoresInitialEmission = false
                    guard currentStructureState != initialStructureState else {
                        return
                    }
                }
                self.display(entry)
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryStructureObservationHandles)
    }

    private func rebuildContent(for entry: NetworkEntry?) {
        contentStack.arrangedSubviews.forEach { subview in
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        requestBodyButton = nil
        responseBodyButton = nil
        renderedSectionTitles = []

        guard let entry else {
            view.needsLayout = true
            return
        }

        var sections: [NSView] = []
        let invalidateLayout: @MainActor @Sendable () -> Void = { [weak self] in
            self?.view.needsLayout = true
        }

        let overviewTitle = wiLocalized("network.detail.section.overview", default: "Overview")
        sections.append(
            WINetworkOverviewSectionView(
                inspector: inspector,
                title: overviewTitle,
                invalidateLayout: invalidateLayout
            )
        )
        renderedSectionTitles.append(overviewTitle)

        let requestTitle = wiLocalized("network.section.request", default: "Request")
        sections.append(
            WINetworkHeadersSectionView(
                inspector: inspector,
                role: .request,
                title: requestTitle,
                invalidateLayout: invalidateLayout
            )
        )
        renderedSectionTitles.append(requestTitle)

        if entry.requestBody != nil {
            let requestBodyTitle = wiLocalized("network.section.body.request", default: "Request Body")
            let requestBodySectionView = WINetworkBodySectionView(
                inspector: inspector,
                role: .request,
                title: requestBodyTitle,
                invalidateLayout: invalidateLayout
            )
            requestBodySectionView.actionButton.target = self
            requestBodySectionView.actionButton.action = #selector(showRequestBodyPreview)
            requestBodyButton = requestBodySectionView.actionButton
            sections.append(requestBodySectionView)
            renderedSectionTitles.append(requestBodyTitle)
        }

        let responseTitle = wiLocalized("network.section.response", default: "Response")
        sections.append(
            WINetworkHeadersSectionView(
                inspector: inspector,
                role: .response,
                title: responseTitle,
                invalidateLayout: invalidateLayout
            )
        )
        renderedSectionTitles.append(responseTitle)

        if entry.responseBody != nil {
            let responseBodyTitle = wiLocalized("network.section.body.response", default: "Response Body")
            let responseBodySectionView = WINetworkBodySectionView(
                inspector: inspector,
                role: .response,
                title: responseBodyTitle,
                invalidateLayout: invalidateLayout
            )
            responseBodySectionView.actionButton.target = self
            responseBodySectionView.actionButton.action = #selector(showResponseBodyPreview)
            responseBodyButton = responseBodySectionView.actionButton
            sections.append(responseBodySectionView)
            renderedSectionTitles.append(responseBodyTitle)
        }

        if let errorDescription = entry.errorDescription, errorDescription.isEmpty == false {
            let errorTitle = wiLocalized("network.section.error", default: "Error")
            sections.append(
                WINetworkErrorSectionView(
                    inspector: inspector,
                    title: errorTitle,
                    invalidateLayout: invalidateLayout
                )
            )
            renderedSectionTitles.append(errorTitle)
        }

        for (index, section) in sections.enumerated() {
            contentStack.addArrangedSubview(section)
            if index < sections.count - 1 {
                contentStack.addArrangedSubview(WINetworkAppKitViewFactory.makeSeparator())
            }
        }

        view.needsLayout = true
    }

    @objc
    private func showRequestBodyPreview() {
        showBodyPreview(for: .request)
    }

    @objc
    private func showResponseBodyPreview() {
        showBodyPreview(for: .response)
    }

    private func showBodyPreview(for role: NetworkBody.Role) {
        guard let entry = inspector.selectedEntry else {
            return
        }

        let body: NetworkBody?
        switch role {
        case .request:
            body = entry.requestBody
        case .response:
            body = entry.responseBody
        }

        guard let body else {
            return
        }

        if let presented = presentedViewControllers?.first {
            dismiss(presented)
        }

        let preview = WINetworkBodyPreviewViewController(
            inspector: inspector,
            role: body.role,
            selectedEntryIDForPresentation: entry.id
        )
        presentAsSheet(preview)
    }

    private func dismissPresentedBodyPreviewIfNeeded() {
        guard let presented = presentedViewControllers?.first else {
            return
        }
        presented.dismiss(nil)
    }

    private func makeStructureState(for entry: NetworkEntry?) -> DetailStructureState? {
        guard let entry else {
            return nil
        }
        return DetailStructureState(
            requestBodyIdentity: entry.requestBody.map(ObjectIdentifier.init),
            responseBodyIdentity: entry.responseBody.map(ObjectIdentifier.init),
            hasError: entry.errorDescription?.isEmpty == false
        )
    }
}

@MainActor
private final class WINetworkOverviewSectionView: NSStackView {
    private let inspector: WINetworkModel
    private let invalidateLayout: @MainActor () -> Void
    private var observationHandles: Set<ObservationHandle> = []

    private let statusMetricView = WINetworkAppKitViewFactory.makeMetricView(symbolName: "circle.fill", text: "")
    private let durationMetricView = WINetworkAppKitViewFactory.makeMetricView(symbolName: "clock", text: "")
    private let encodedMetricView = WINetworkAppKitViewFactory.makeMetricView(symbolName: "arrow.down.to.line", text: "")
    private let metricsStack = NSStackView()
    private let urlLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
        lineBreakMode: .byTruncatingMiddle,
        numberOfLines: 4,
        selectable: true
    )

    private var statusImageView: NSImageView {
        statusMetricView.arrangedSubviews[0] as! NSImageView
    }

    private var statusLabel: NSTextField {
        statusMetricView.arrangedSubviews[1] as! NSTextField
    }

    private var durationLabel: NSTextField {
        durationMetricView.arrangedSubviews[1] as! NSTextField
    }

    private var encodedLabel: NSTextField {
        encodedMetricView.arrangedSubviews[1] as! NSTextField
    }

    init(inspector: WINetworkModel, title: String, invalidateLayout: @escaping @MainActor () -> Void) {
        self.inspector = inspector
        self.invalidateLayout = invalidateLayout
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = 12
        metricsStack.addArrangedSubview(statusMetricView)
        metricsStack.addArrangedSubview(durationMetricView)
        metricsStack.addArrangedSubview(encodedMetricView)

        addArrangedSubview(WINetworkAppKitViewFactory.makeSectionTitleLabel(title))
        addArrangedSubview(metricsStack)
        addArrangedSubview(urlLabel)

        bindCurrentSelectedEntry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            observationHandles.removeAll()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func bindCurrentSelectedEntry() {
        observationHandles.removeAll()
        guard let entry = inspector.selectedEntry else {
            clear()
            return
        }

        apply(entry: entry)

        entry.observe(
            \.url,
            onChange: { [weak self, weak entry] _ in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.urlLabel.stringValue = entry.url
                self.invalidateLayout()
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)

        entry.observe(
            [\.statusCode, \.statusText, \.phase, \.duration, \.encodedBodyLength],
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.apply(entry: entry)
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)
    }

    private func clear() {
        statusLabel.stringValue = ""
        statusImageView.contentTintColor = networkStatusColor(for: .neutral)
        urlLabel.stringValue = ""
        applyMetric(durationMetricView, label: durationLabel, text: nil)
        applyMetric(encodedMetricView, label: encodedLabel, text: nil)
        invalidateLayout()
    }

    private func apply(entry: NetworkEntry) {
        statusLabel.stringValue = entry.statusLabel
        statusImageView.contentTintColor = networkStatusColor(for: entry.statusSeverity)
        urlLabel.stringValue = entry.url
        applyMetric(durationMetricView, label: durationLabel, text: entry.duration.map(entry.durationText(for:)))
        applyMetric(
            encodedMetricView,
            label: encodedLabel,
            text: entry.encodedBodyLength.map(entry.sizeText(for:))
        )
        invalidateLayout()
    }

    private func applyMetric(_ metricView: NSStackView, label: NSTextField, text: String?) {
        label.stringValue = text ?? ""
        metricView.isHidden = text == nil
    }
}

@MainActor
private final class WINetworkHeadersSectionView: NSStackView {
    private let inspector: WINetworkModel
    private let role: WINetworkHeaderRole
    private let invalidateLayout: @MainActor () -> Void
    private var observationHandles: Set<ObservationHandle> = []
    private let rowsStack = NSStackView()

    init(
        inspector: WINetworkModel,
        role: WINetworkHeaderRole,
        title: String,
        invalidateLayout: @escaping @MainActor () -> Void
    ) {
        self.inspector = inspector
        self.role = role
        self.invalidateLayout = invalidateLayout
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10

        addArrangedSubview(WINetworkAppKitViewFactory.makeSectionTitleLabel(title))
        addArrangedSubview(rowsStack)

        bindCurrentSelectedEntry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            observationHandles.removeAll()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func bindCurrentSelectedEntry() {
        observationHandles.removeAll()
        guard let entry = inspector.selectedEntry else {
            apply(headers: NetworkHeaders())
            return
        }

        let headersKeyPath: KeyPath<NetworkEntry, NetworkHeaders> = role == .request
            ? \.requestHeaders
            : \.responseHeaders

        apply(headers: entry[keyPath: headersKeyPath])

        entry.observe(
            headersKeyPath,
            onChange: { [weak self, weak entry] headers in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.apply(headers: headers)
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)
    }

    private func apply(headers: NetworkHeaders) {
        rowsStack.arrangedSubviews.forEach { subview in
            rowsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        if headers.isEmpty {
            rowsStack.addArrangedSubview(
                WINetworkAppKitViewFactory.makeSecondaryLabel(
                    wiLocalized("network.headers.empty", default: "No headers")
                )
            )
            invalidateLayout()
            return
        }

        for field in headers.fields {
            rowsStack.addArrangedSubview(makeNetworkHeaderFieldView(field))
        }
        invalidateLayout()
    }
}

@MainActor
private final class WINetworkBodySectionView: NSStackView {
    let actionButton = NSButton(title: "", target: nil, action: nil)

    private let inspector: WINetworkModel
    private let role: NetworkBody.Role
    private let invalidateLayout: @MainActor () -> Void
    private var observationHandles: Set<ObservationHandle> = []

    private let summaryLabel = WINetworkAppKitViewFactory.makeSecondaryLabel(
        "",
        numberOfLines: 2,
        selectable: true,
        lineBreakMode: .byWordWrapping
    )
    private let previewLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
        color: .secondaryLabelColor,
        lineBreakMode: .byWordWrapping,
        numberOfLines: 6,
        selectable: true
    )

    init(
        inspector: WINetworkModel,
        role: NetworkBody.Role,
        title: String,
        invalidateLayout: @escaping @MainActor () -> Void
    ) {
        self.inspector = inspector
        self.role = role
        self.invalidateLayout = invalidateLayout
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        detachesHiddenViews = true

        actionButton.isBordered = false
        actionButton.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        actionButton.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        actionButton.imagePosition = .imageLeading
        actionButton.contentTintColor = .controlAccentColor
        actionButton.setButtonType(.momentaryPushIn)
        actionButton.alignment = .left

        addArrangedSubview(WINetworkAppKitViewFactory.makeSectionTitleLabel(title))
        addArrangedSubview(actionButton)
        addArrangedSubview(summaryLabel)
        addArrangedSubview(previewLabel)

        bindCurrentSelectedEntry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            observationHandles.removeAll()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func bindCurrentSelectedEntry() {
        observationHandles.removeAll()
        guard let entry = inspector.selectedEntry, let body = body(from: entry) else {
            applyUnavailable()
            return
        }

        apply(entry: entry, body: body)

        let entryKeyPaths: [PartialKeyPath<NetworkEntry>] = [
            \.mimeType,
            \.decodedBodyLength,
            \.encodedBodyLength,
            \.requestBodyBytesSent,
            \.requestHeaders,
            \.responseHeaders
        ]
        entry.observe(
            entryKeyPaths,
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id, let body = self.body(from: entry) else {
                    return
                }
                self.apply(entry: entry, body: body)
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)

        body.observe(
            [
                \.role,
                \.kind,
                \.preview,
                \.full,
                \.size,
                \.isBase64Encoded,
                \.isTruncated,
                \.summary,
                \.reference,
                \.formEntries,
                \.fetchState
            ],
            onChange: { [weak self, weak entry, weak body] in
                guard let self, let entry, let body else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.apply(entry: entry, body: body)
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)
    }

    private func body(from entry: NetworkEntry) -> NetworkBody? {
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }

    private func applyUnavailable() {
        actionButton.title = wiLocalized("network.body.unavailable", default: "Body unavailable")
        summaryLabel.stringValue = ""
        summaryLabel.isHidden = true
        previewLabel.stringValue = wiLocalized("network.body.unavailable", default: "Body unavailable")
        invalidateLayout()
    }

    private func apply(entry: NetworkEntry, body: NetworkBody) {
        actionButton.title = networkDetailBodyPrimaryText(entry: entry, body: body)
        let summary = body.summary ?? ""
        summaryLabel.stringValue = summary
        summaryLabel.isHidden = summary.isEmpty
        previewLabel.stringValue = networkDetailBodySecondaryText(body)
        invalidateLayout()
    }
}

@MainActor
private final class WINetworkErrorSectionView: NSStackView {
    private let inspector: WINetworkModel
    private let invalidateLayout: @MainActor () -> Void
    private var observationHandles: Set<ObservationHandle> = []
    private let errorLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize),
        color: .systemOrange,
        lineBreakMode: .byWordWrapping,
        numberOfLines: 0,
        selectable: true
    )

    init(inspector: WINetworkModel, title: String, invalidateLayout: @escaping @MainActor () -> Void) {
        self.inspector = inspector
        self.invalidateLayout = invalidateLayout
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        addArrangedSubview(WINetworkAppKitViewFactory.makeSectionTitleLabel(title))
        addArrangedSubview(errorLabel)

        bindCurrentSelectedEntry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            observationHandles.removeAll()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func bindCurrentSelectedEntry() {
        observationHandles.removeAll()
        guard let entry = inspector.selectedEntry else {
            errorLabel.stringValue = ""
            invalidateLayout()
            return
        }

        errorLabel.stringValue = entry.errorDescription ?? ""
        invalidateLayout()
        entry.observe(
            \.errorDescription,
            onChange: { [weak self, weak entry] value in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.errorLabel.stringValue = value ?? ""
                self.invalidateLayout()
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)
    }
}

@MainActor
private func makeNetworkHeaderFieldView(_ field: NetworkHeaderField) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4

    let nameLabel = WINetworkAppKitViewFactory.makeSecondaryLabel(field.name)
    let valueLabel = WINetworkAppKitViewFactory.makeLabel(
        field.value,
        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
        lineBreakMode: .byWordWrapping,
        numberOfLines: 0,
        selectable: true
    )

    stack.addArrangedSubview(nameLabel)
    stack.addArrangedSubview(valueLabel)
    return stack
}

@MainActor
private func networkDetailBodyPrimaryText(entry: NetworkEntry, body: NetworkBody) -> String {
    var parts: [String] = []
    if let typeLabel = networkBodyTypeLabel(entry: entry, body: body) {
        parts.append(typeLabel)
    }
    if let size = networkBodySize(entry: entry, body: body) {
        parts.append(entry.sizeText(for: size))
    }
    if parts.isEmpty {
        return wiLocalized("network.body.unavailable", default: "Body unavailable")
    }
    return parts.joined(separator: "  ")
}

@MainActor
private func networkDetailBodySecondaryText(_ body: NetworkBody) -> String {
    switch body.fetchState {
    case .fetching:
        return wiLocalized("network.body.fetching", default: "Fetching body...")
    case .failed(let error):
        return error.localizedDescriptionText
    default:
        if body.kind == .form, body.formEntries.isEmpty == false {
            return body.formEntries.prefix(4).map {
                let value: String
                if $0.isFile, let fileName = $0.fileName, fileName.isEmpty == false {
                    value = fileName
                } else {
                    value = $0.value
                }
                return "\($0.name): \(value)"
            }.joined(separator: "\n")
        }
        return networkBodyPreviewText(body) ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
    }
}
#endif
