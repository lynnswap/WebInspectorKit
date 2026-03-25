import Foundation
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
final class WINetworkDetailViewController: NSViewController {
    fileprivate struct DetailStructureState: Equatable {
        let requestBodyIdentity: ObjectIdentifier?
        let responseBodyIdentity: ObjectIdentifier?
        let hasError: Bool
    }

    fileprivate struct OverviewSnapshot: Equatable {
        let statusLabel: String
        let statusSeverity: NetworkStatusSeverity
        let url: String
        let durationText: String?
        let encodedBodyLengthText: String?
    }

    fileprivate struct HeaderSnapshot: Equatable {
        let name: String
        let value: String
    }

    fileprivate struct BodySnapshot: Equatable {
        let role: NetworkBody.Role
        let primaryText: String
        let summaryText: String
        let previewText: String
    }

    fileprivate struct DetailSnapshot: Equatable {
        let entryID: UUID?
        let structureState: DetailStructureState?
        let overview: OverviewSnapshot?
        let requestHeaders: [HeaderSnapshot]
        let requestBody: BodySnapshot?
        let responseHeaders: [HeaderSnapshot]
        let responseBody: BodySnapshot?
        let errorDescription: String?
    }

    private let inspector: WINetworkModel
    private var renderedSnapshot: DetailSnapshot?

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
    private var overviewSectionView: WINetworkOverviewSectionView?
    private var requestHeadersSectionView: WINetworkHeadersSectionView?
    private var requestBodySectionView: WINetworkBodySectionView?
    private var responseHeadersSectionView: WINetworkHeadersSectionView?
    private var responseBodySectionView: WINetworkBodySectionView?
    private var errorSectionView: WINetworkErrorSectionView?

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

    func display(_ entry: NetworkEntry?) {
        let snapshot = makeDetailSnapshot(for: entry)
        if displayedEntryID != snapshot.entryID {
            dismissPresentedBodyPreviewIfNeeded()
        }
        displayedEntryID = snapshot.entryID
        if renderedSnapshot?.structureState != snapshot.structureState || renderedSnapshot?.entryID != snapshot.entryID {
            rebuildContent(for: snapshot)
        }
        applySnapshot(snapshot)
        renderedSnapshot = snapshot
        updateVisibility()
    }

    func updateVisibility() {
        let hasEntries = inspector.store.entries.isEmpty == false
        let hasSelection = inspector.selectedEntry != nil
        scrollView.isHidden = hasSelection == false
        emptyStateView.isHidden = hasEntries
    }

    private func rebuildContent(for snapshot: DetailSnapshot) {
        contentStack.arrangedSubviews.forEach { subview in
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        requestBodyButton = nil
        responseBodyButton = nil
        renderedSectionTitles = []
        overviewSectionView = nil
        requestHeadersSectionView = nil
        requestBodySectionView = nil
        responseHeadersSectionView = nil
        responseBodySectionView = nil
        errorSectionView = nil

        guard snapshot.entryID != nil else {
            view.needsLayout = true
            return
        }

        var sections: [NSView] = []
        let overviewTitle = wiLocalized("network.detail.section.overview", default: "Overview")
        let overviewSectionView = WINetworkOverviewSectionView(title: overviewTitle)
        self.overviewSectionView = overviewSectionView
        sections.append(overviewSectionView)
        renderedSectionTitles.append(overviewTitle)

        let requestTitle = wiLocalized("network.section.request", default: "Request")
        let requestHeadersSectionView = WINetworkHeadersSectionView(title: requestTitle)
        self.requestHeadersSectionView = requestHeadersSectionView
        sections.append(requestHeadersSectionView)
        renderedSectionTitles.append(requestTitle)

        if snapshot.requestBody != nil {
            let requestBodyTitle = wiLocalized("network.section.body.request", default: "Request Body")
            let requestBodySectionView = WINetworkBodySectionView(title: requestBodyTitle)
            requestBodySectionView.actionButton.target = self
            requestBodySectionView.actionButton.action = #selector(showRequestBodyPreview)
            self.requestBodySectionView = requestBodySectionView
            requestBodyButton = requestBodySectionView.actionButton
            sections.append(requestBodySectionView)
            renderedSectionTitles.append(requestBodyTitle)
        }

        let responseTitle = wiLocalized("network.section.response", default: "Response")
        let responseHeadersSectionView = WINetworkHeadersSectionView(title: responseTitle)
        self.responseHeadersSectionView = responseHeadersSectionView
        sections.append(responseHeadersSectionView)
        renderedSectionTitles.append(responseTitle)

        if snapshot.responseBody != nil {
            let responseBodyTitle = wiLocalized("network.section.body.response", default: "Response Body")
            let responseBodySectionView = WINetworkBodySectionView(title: responseBodyTitle)
            responseBodySectionView.actionButton.target = self
            responseBodySectionView.actionButton.action = #selector(showResponseBodyPreview)
            self.responseBodySectionView = responseBodySectionView
            responseBodyButton = responseBodySectionView.actionButton
            sections.append(responseBodySectionView)
            renderedSectionTitles.append(responseBodyTitle)
        }

        if let errorDescription = snapshot.errorDescription, errorDescription.isEmpty == false {
            let errorTitle = wiLocalized("network.section.error", default: "Error")
            let errorSectionView = WINetworkErrorSectionView(title: errorTitle)
            self.errorSectionView = errorSectionView
            sections.append(errorSectionView)
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

    private func applySnapshot(_ snapshot: DetailSnapshot) {
        overviewSectionView?.apply(snapshot: snapshot.overview)
        requestHeadersSectionView?.apply(snapshot: snapshot.requestHeaders)
        requestBodySectionView?.apply(snapshot: snapshot.requestBody)
        responseHeadersSectionView?.apply(snapshot: snapshot.responseHeaders)
        responseBodySectionView?.apply(snapshot: snapshot.responseBody)
        errorSectionView?.apply(errorDescription: snapshot.errorDescription ?? "")
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

    private func makeDetailSnapshot(for entry: NetworkEntry?) -> DetailSnapshot {
        Self.makeDetailSnapshot(from: entry)
    }
}

fileprivate extension WINetworkDetailViewController {
    static func makeDetailSnapshot(from entry: NetworkEntry?) -> DetailSnapshot {
        guard let entry else {
            return DetailSnapshot(
                entryID: nil,
                structureState: nil,
                overview: nil,
                requestHeaders: [],
                requestBody: nil,
                responseHeaders: [],
                responseBody: nil,
                errorDescription: nil
            )
        }

        let structureState = DetailStructureState(
            requestBodyIdentity: entry.requestBody.map(ObjectIdentifier.init),
            responseBodyIdentity: entry.responseBody.map(ObjectIdentifier.init),
            hasError: (entry.errorDescription?.isEmpty == false)
        )
        let overview = OverviewSnapshot(
            statusLabel: entry.statusLabel,
            statusSeverity: entry.statusSeverity,
            url: entry.url,
            durationText: entry.duration.map(entry.durationText(for:)),
            encodedBodyLengthText: entry.encodedBodyLength.map(entry.sizeText(for:))
        )
        let requestHeaders = entry.requestHeaders.fields.map { HeaderSnapshot(name: $0.name, value: $0.value) }
        let responseHeaders = entry.responseHeaders.fields.map { HeaderSnapshot(name: $0.name, value: $0.value) }

        return DetailSnapshot(
            entryID: entry.id,
            structureState: structureState,
            overview: overview,
            requestHeaders: requestHeaders,
            requestBody: entry.requestBody.map { body in
                BodySnapshot(
                    role: body.role,
                    primaryText: networkDetailBodyPrimaryText(entry: entry, body: body),
                    summaryText: body.summary ?? "",
                    previewText: networkDetailBodySecondaryText(body)
                )
            },
            responseHeaders: responseHeaders,
            responseBody: entry.responseBody.map { body in
                BodySnapshot(
                    role: body.role,
                    primaryText: networkDetailBodyPrimaryText(entry: entry, body: body),
                    summaryText: body.summary ?? "",
                    previewText: networkDetailBodySecondaryText(body)
                )
            },
            errorDescription: entry.errorDescription.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

@MainActor
private final class WINetworkOverviewSectionView: NSStackView {
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

    init(title: String) {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(snapshot: WINetworkDetailViewController.OverviewSnapshot?) {
        guard let snapshot else {
            statusLabel.stringValue = ""
            statusImageView.contentTintColor = networkStatusColor(for: .neutral)
            urlLabel.stringValue = ""
            applyMetric(durationMetricView, label: durationLabel, text: nil)
            applyMetric(encodedMetricView, label: encodedLabel, text: nil)
            return
        }

        statusLabel.stringValue = snapshot.statusLabel
        statusImageView.contentTintColor = networkStatusColor(for: snapshot.statusSeverity)
        urlLabel.stringValue = snapshot.url
        applyMetric(durationMetricView, label: durationLabel, text: snapshot.durationText)
        applyMetric(encodedMetricView, label: encodedLabel, text: snapshot.encodedBodyLengthText)
    }

    private func applyMetric(_ metricView: NSStackView, label: NSTextField, text: String?) {
        label.stringValue = text ?? ""
        metricView.isHidden = text == nil
    }
}

@MainActor
private final class WINetworkHeadersSectionView: NSStackView {
    private let rowsStack = NSStackView()

    init(title: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10

        addArrangedSubview(WINetworkAppKitViewFactory.makeSectionTitleLabel(title))
        addArrangedSubview(rowsStack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(snapshot: [WINetworkDetailViewController.HeaderSnapshot]) {
        rowsStack.arrangedSubviews.forEach { subview in
            rowsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        if snapshot.isEmpty {
            rowsStack.addArrangedSubview(
                WINetworkAppKitViewFactory.makeSecondaryLabel(
                    wiLocalized("network.headers.empty", default: "No headers")
                )
            )
            return
        }

        for field in snapshot {
            rowsStack.addArrangedSubview(makeNetworkHeaderFieldView(field))
        }
    }
}

@MainActor
private final class WINetworkBodySectionView: NSStackView {
    let actionButton = NSButton(title: "", target: nil, action: nil)

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

    init(title: String) {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(snapshot: WINetworkDetailViewController.BodySnapshot?) {
        actionButton.title = snapshot?.primaryText
            ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        summaryLabel.stringValue = snapshot?.summaryText ?? ""
        summaryLabel.isHidden = (snapshot?.summaryText.isEmpty ?? true)
        previewLabel.stringValue = snapshot?.previewText
            ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
    }
}

@MainActor
private final class WINetworkErrorSectionView: NSStackView {
    private let errorLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize),
        color: .systemOrange,
        lineBreakMode: .byWordWrapping,
        numberOfLines: 0,
        selectable: true
    )

    init(title: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        addArrangedSubview(WINetworkAppKitViewFactory.makeSectionTitleLabel(title))
        addArrangedSubview(errorLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(errorDescription: String) {
        errorLabel.stringValue = errorDescription
    }
}

@MainActor
private func makeNetworkHeaderFieldView(_ field: WINetworkDetailViewController.HeaderSnapshot) -> NSView {
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
