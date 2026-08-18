#if canImport(UIKit)
import Foundation
import ObservationBridge
import WebInspectorDataKit
import WebInspectorUIBase
import UIKit

@MainActor
package final class NetworkWebSocketPreviewViewController: UICollectionViewController {
    private static let maximumRenderedTextPayloadCharacters = 2_048
    private static let maximumTitleLineCount = 8
    private static let textPayloadTruncationMarker = "…"

    package struct RequestEpoch: Hashable, Sendable {
        private let requestID: NetworkRequest.ID
        private let requestInstance: ObjectIdentifier
        private let lifecycleRevision: UInt64
        private let webSocketInstance: ObjectIdentifier

        package init(request: NetworkRequest, webSocket: WebSocketState) {
            requestID = request.id
            requestInstance = ObjectIdentifier(request)
            lifecycleRevision = request.lifecycleRevision
            webSocketInstance = ObjectIdentifier(webSocket)
        }
    }

    package enum SectionID: Hashable, Sendable {
        case timeline
    }

    package enum ItemID: Hashable, Sendable {
        case timeline(epoch: RequestEpoch, entryID: WebSocketTimelineEntry.ID)
    }

    package struct RowContent: Equatable, Sendable {
        package enum Style: Equatable, Sendable {
            case lifecycle
            case sent
            case received
            case error
        }

        package let title: String
        package let subtitle: String
        package let symbolName: String
        package let style: Style
        package let accessibilityLabel: String
        package let accessibilityValue: String
    }

    private let frameScheduler: any NetworkFrameScheduling
    private var timelineObservation: PortableObservationTracking.Token?
    private var observationStartTask: Task<Void, Never>?
    private weak var request: NetworkRequest?
    private weak var webSocket: WebSocketState?
    private var requestEpoch: RequestEpoch?
    private var renderedEntryIDs: [WebSocketTimelineEntry.ID] = []
    private var rowContents: [ItemID: RowContent] = [:]
    private var isRenderingActive = false
    private var wasFollowingTailWhenSuspended: Bool?
    private var textPayloadCopyHandler: @MainActor (String) -> Void
    private lazy var dataSource = makeDataSource()
    private lazy var byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useBytes
        formatter.countStyle = .memory
        formatter.isAdaptive = false
        return formatter
    }()
#if DEBUG
    private var snapshotApplyCountStorageForTesting = 0
    private var tailScrollCountStorageForTesting = 0
    private var nextSnapshotApplyCompletionForTesting: (@MainActor () -> Void)?
    private var deinitHandlerForTesting: (@MainActor () -> Void)?
#endif

    package convenience init() {
        self.init(frameScheduler: NetworkDisplayLinkFrameScheduler())
    }

    package init(frameScheduler: any NetworkFrameScheduling) {
        self.frameScheduler = frameScheduler
        textPayloadCopyHandler = { payload in
            UIPasteboard.general.string = payload
        }
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        timelineObservation?.cancel()
        observationStartTask?.cancel()
        frameScheduler.invalidate()
#if DEBUG
        deinitHandlerForTesting?()
#endif
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        _ = dataSource
        collectionView.allowsSelection = false
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.Network.WebSocketPreview"
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        applyEmptySnapshot()
    }

    package func bind(to request: NetworkRequest) {
        loadViewIfNeeded()
        guard let webSocket = request.webSocket else {
            preconditionFailure("A WebSocket preview can only bind a request with WebSocket state.")
        }
        let nextEpoch = RequestEpoch(request: request, webSocket: webSocket)
        guard requestEpoch != nextEpoch
                || self.request !== request
                || self.webSocket !== webSocket else {
            if isRenderingActive, timelineObservation?.isActive != true {
                scheduleTimelineObservationStart()
            }
            return
        }

        timelineObservation?.cancel()
        timelineObservation = nil
        cancelTimelineObservationStart()
        frameScheduler.cancel()
        self.request = request
        self.webSocket = webSocket
        requestEpoch = nextEpoch
        renderedEntryIDs = []
        rowContents = [:]
        wasFollowingTailWhenSuspended = nil
        applyEmptySnapshot()
        if isRenderingActive {
            scheduleTimelineObservationStart()
        }
    }

    package func resumeRendering() {
        guard request != nil, webSocket != nil, requestEpoch != nil else {
            return
        }
        isRenderingActive = true
        scheduleTimelineObservationStart()
    }

    package func suspendKeepingSnapshot() {
        if isRenderingActive {
            wasFollowingTailWhenSuspended = isFollowingTail
        }
        isRenderingActive = false
        timelineObservation?.cancel()
        timelineObservation = nil
        cancelTimelineObservationStart()
        frameScheduler.cancel()
    }

    package func clear() {
        isRenderingActive = false
        timelineObservation?.cancel()
        timelineObservation = nil
        cancelTimelineObservationStart()
        frameScheduler.cancel()
        request = nil
        webSocket = nil
        requestEpoch = nil
        renderedEntryIDs = []
        rowContents = [:]
        wasFollowingTailWhenSuspended = nil
        loadViewIfNeeded()
        applyEmptySnapshot()
    }

    override package func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1,
              let indexPath = indexPaths.first,
              let itemID = dataSource.itemIdentifier(for: indexPath) else {
            return nil
        }
        return contextMenuConfiguration(for: itemID)
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout.list(using: listLayoutConfiguration)
    }

    private static var listLayoutConfiguration: UICollectionLayoutListConfiguration {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = true
        return configuration
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionID, ItemID> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemID> {
            [weak self] cell, _, itemID in
            guard let self, let content = rowContents[itemID] else {
                Self.clear(cell)
                return
            }
            configure(cell, with: content, itemID: itemID)
        }
        return UICollectionViewDiffableDataSource<SectionID, ItemID>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: itemID
            )
        }
    }

    private func scheduleTimelineObservationStart() {
        guard isRenderingActive,
              request != nil,
              webSocket != nil,
              requestEpoch != nil,
              timelineObservation?.isActive != true,
              observationStartTask == nil else {
            return
        }
        let expectedEpoch = requestEpoch
        // Keep this next-turn boundary. Nested Observation tracking merges the
        // child's access list into the parent, which would make every frame
        // bypass this controller's display-frame scheduler.
        observationStartTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard Task.isCancelled == false,
                  let self,
                  isRenderingActive,
                  requestEpoch == expectedEpoch else {
                return
            }
            observationStartTask = nil
            startObservingTimeline()
        }
    }

    private func cancelTimelineObservationStart() {
        observationStartTask?.cancel()
        observationStartTask = nil
    }

    private func startObservingTimeline() {
        guard isRenderingActive,
              let webSocket,
              let requestEpoch else {
            return
        }
        timelineObservation?.cancel()
        let token = withPortableContinuousObservation { [weak self, weak webSocket] event in
            guard let self,
                  let webSocket,
                  isRenderingActive,
                  self.webSocket === webSocket,
                  self.requestEpoch == requestEpoch else {
                return
            }
            let entries = webSocket.timelineEntries
            if event.kind == .initial {
                let followsTail = wasFollowingTailWhenSuspended ?? isFollowingTail
                wasFollowingTailWhenSuspended = nil
                appendTimeline(entries, epoch: requestEpoch, followsTail: followsTail)
                return
            }
            scheduleTimelineRendering(for: requestEpoch)
        }
        timelineObservation = token
    }

    private func scheduleTimelineRendering(for epoch: RequestEpoch) {
        frameScheduler.schedule { [weak self] in
            guard let self,
                  isRenderingActive,
                  requestEpoch == epoch,
                  let webSocket else {
                return
            }
            appendTimeline(
                webSocket.timelineEntries,
                epoch: epoch,
                followsTail: isFollowingTail
            )
        }
    }

    private func appendTimeline(
        _ entries: [WebSocketTimelineEntry],
        epoch: RequestEpoch,
        followsTail: Bool
    ) {
        guard requestEpoch == epoch else {
            return
        }
        let renderedCount = renderedEntryIDs.count
        precondition(
            entries.count >= renderedCount,
            "A WebSocket timeline cannot shrink or replace its prefix within one request epoch."
        )
        if renderedCount > 0 {
            precondition(
                entries[renderedCount - 1].id == renderedEntryIDs[renderedCount - 1],
                "A WebSocket timeline cannot shrink or replace its prefix within one request epoch."
            )
        }
        guard entries.count > renderedCount else {
            return
        }
        let suffix = entries.dropFirst(renderedCount)
        let itemIDs = suffix.map { ItemID.timeline(epoch: epoch, entryID: $0.id) }
        for (itemID, entry) in zip(itemIDs, suffix) {
            rowContents[itemID] = rowContent(for: entry)
        }
        renderedEntryIDs.append(contentsOf: suffix.map(\.id))
        var snapshot = dataSource.snapshot()
        if snapshot.sectionIdentifiers.isEmpty {
            snapshot.appendSections([.timeline])
        }
        snapshot.appendItems(itemIDs, toSection: .timeline)
        apply(snapshot, epoch: epoch, followsTail: followsTail)
    }

    private func applyEmptySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<SectionID, ItemID>()
        snapshot.appendSections([.timeline])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func apply(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionID, ItemID>,
        epoch: RequestEpoch,
        followsTail: Bool
    ) {
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else {
                return
            }
#if DEBUG
            snapshotApplyCountStorageForTesting += 1
            let testCompletion = nextSnapshotApplyCompletionForTesting
            nextSnapshotApplyCompletionForTesting = nil
            defer { testCompletion?() }
#endif
            snapshotApplyDidFinish(epoch: epoch, followsTail: followsTail)
        }
    }

    private func snapshotApplyDidFinish(epoch: RequestEpoch, followsTail: Bool) {
        guard requestEpoch == epoch else {
            return
        }
        if followsTail {
            scrollToTail(epoch: epoch)
        }
    }

    private var isFollowingTail: Bool {
        guard renderedEntryIDs.isEmpty == false else {
            return true
        }
        collectionView.layoutIfNeeded()
        let visibleBottom = collectionView.contentOffset.y
            + collectionView.bounds.height
            - collectionView.adjustedContentInset.bottom
        return visibleBottom >= collectionView.contentSize.height - 1
    }

    private func scrollToTail(epoch: RequestEpoch) {
        guard requestEpoch == epoch,
              renderedEntryIDs.isEmpty == false else {
            return
        }
        let indexPath = IndexPath(item: renderedEntryIDs.count - 1, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
#if DEBUG
        tailScrollCountStorageForTesting += 1
#endif
    }

    private func rowContent(for entry: WebSocketTimelineEntry) -> RowContent {
        let time = relativeTimeText(for: entry.timestamp)
        switch entry.kind {
        case .connectionEstablished:
            let title = localized(
                "network.websocket.connection.established",
                defaultValue: "WebSocket Connection Established"
            )
            return RowContent(
                title: title,
                subtitle: time,
                symbolName: "network",
                style: .lifecycle,
                accessibilityLabel: title,
                accessibilityValue: time
            )
        case .connectionClosed:
            let title = localized(
                "network.websocket.connection.closed",
                defaultValue: "WebSocket Connection Closed"
            )
            return RowContent(
                title: title,
                subtitle: time,
                symbolName: "xmark.circle",
                style: .lifecycle,
                accessibilityLabel: title,
                accessibilityValue: time
            )
        case let .handshakeResponse(response):
            return handshakeResponseRowContent(response, time: time)
        case .error(let message):
            let error = localized("network.websocket.error", defaultValue: "Error")
            let subtitle = [error, time].joined(separator: " · ")
            return RowContent(
                title: message,
                subtitle: subtitle,
                symbolName: "exclamationmark.triangle",
                style: .error,
                accessibilityLabel: message,
                accessibilityValue: subtitle
            )
        case .frame(let frame):
            return frameRowContent(frame, time: time)
        }
    }

    private func frameRowContent(
        _ frame: WebSocketTimelineFrame,
        time: String
    ) -> RowContent {
        let direction = directionText(frame.direction)
        let frameKind = frameKindText(frame.kind)
        let style: RowContent.Style
        let symbolName: String
        switch frame.direction {
        case .sent:
            style = .sent
            symbolName = "arrow.up"
        case .received:
            style = .received
            symbolName = "arrow.down"
        }

        let title: String
        switch frame.kind {
        case .text:
            guard case let .text(payload) = frame.payload else {
                preconditionFailure("A text WebSocket frame must carry a text payload.")
            }
            title = Self.renderedTextPayload(payload)
        case .continuation, .binary, .close, .ping, .pong, .unknown:
            title = [frameKind, byteCountText(frame.payloadLength)].joined(separator: " · ")
        }
        let subtitle = [direction, frameKind, time].joined(separator: " · ")
        return RowContent(
            title: title,
            subtitle: subtitle,
            symbolName: symbolName,
            style: style,
            accessibilityLabel: title,
            accessibilityValue: subtitle
        )
    }

    private func handshakeResponseRowContent(
        _ response: WebSocketTimelineHandshakeResponse,
        time: String
    ) -> RowContent {
        let title: String
        let symbolName: String
        let style: RowContent.Style
        switch response.disposition {
        case .switchingProtocols, .unreported:
            title = localized(
                "network.websocket.handshake.response",
                defaultValue: "WebSocket Handshake Response"
            )
            symbolName = "arrow.left.arrow.right"
            style = .lifecycle
        case .rejected:
            title = localized(
                "network.websocket.handshake.rejected",
                defaultValue: "WebSocket Handshake Rejected"
            )
            symbolName = "exclamationmark.shield"
            style = .error
        }
        let subtitle = [
            handshakeStatusText(statusCode: response.statusCode, statusText: response.statusText),
            time,
        ].joined(separator: " · ")
        return RowContent(
            title: title,
            subtitle: subtitle,
            symbolName: symbolName,
            style: style,
            accessibilityLabel: title,
            accessibilityValue: subtitle
        )
    }

    private func handshakeStatusText(
        statusCode: Int?,
        statusText: String?
    ) -> String {
        let statusText = statusText?.isEmpty == false ? statusText : nil
        switch (statusCode, statusText) {
        case let (.some(statusCode), .some(statusText)):
            return "\(statusCode) \(statusText)"
        case let (.some(statusCode), .none):
            return String(statusCode)
        case let (.none, .some(statusText)):
            let notReported = localized(
                "network.websocket.status.not_reported",
                defaultValue: "Status not reported"
            )
            return "\(notReported) · \(statusText)"
        case (.none, .none):
            return localized(
                "network.websocket.status.not_reported",
                defaultValue: "Status not reported"
            )
        }
    }

    private func directionText(_ direction: WebSocketTimelineFrame.Direction) -> String {
        switch direction {
        case .sent:
            localized("network.websocket.direction.sent", defaultValue: "Sent")
        case .received:
            localized("network.websocket.direction.received", defaultValue: "Received")
        }
    }

    private func frameKindText(_ kind: WebSocketTimelineFrame.Kind) -> String {
        switch kind {
        case .continuation:
            return localized("network.websocket.frame.continuation", defaultValue: "Continuation Frame")
        case .text:
            return localized("network.websocket.frame.text", defaultValue: "Text Frame")
        case .binary:
            return localized("network.websocket.frame.binary", defaultValue: "Binary Frame")
        case .close:
            return localized("network.websocket.frame.close", defaultValue: "Connection Close Frame")
        case .ping:
            return localized("network.websocket.frame.ping", defaultValue: "Ping Frame")
        case .pong:
            return localized("network.websocket.frame.pong", defaultValue: "Pong Frame")
        case .unknown(let opcode):
            let unknown = localized("network.websocket.frame.unknown", defaultValue: "Unknown Frame")
            let opcodeLabel = localized("network.websocket.opcode", defaultValue: "Opcode")
            return "\(unknown) (\(opcodeLabel) \(opcode))"
        }
    }

    private func byteCountText(_ payloadLength: Int) -> String {
        byteCountFormatter.string(fromByteCount: Int64(payloadLength))
    }

    private func relativeTimeText(for timestamp: Double?) -> String {
        guard let timestamp,
              let startTimestamp = request?.logicalStartTimestamp else {
            return localized("network.websocket.time.not_reported", defaultValue: "Time not reported")
        }
        let interval = timestamp - startTimestamp
        let sign = interval < 0 ? "−" : "+"
        let magnitude = abs(interval)
        if magnitude < 1 {
            return "\(sign)\((magnitude * 1_000).formatted(.number.precision(.fractionLength(0)))) ms"
        }
        return "\(sign)\(magnitude.formatted(.number.precision(.fractionLength(2)))) s"
    }

    private static func renderedTextPayload(_ payload: String) -> String {
        guard let truncationIndex = textPayloadTruncationIndex(in: payload) else {
            return payload
        }
        return String(payload[..<truncationIndex]) + textPayloadTruncationMarker
    }

    private static func textPayloadTruncationIndex(in payload: String) -> String.Index? {
        guard let index = payload.index(
            payload.startIndex,
            offsetBy: maximumRenderedTextPayloadCharacters,
            limitedBy: payload.endIndex
        ), index != payload.endIndex else {
            return nil
        }
        return index
    }

    private func configure(
        _ cell: UICollectionViewListCell,
        with content: RowContent,
        itemID: ItemID
    ) {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = content.title
        configuration.secondaryText = content.subtitle
        configuration.image = UIImage(systemName: content.symbolName)
        configuration.textProperties.numberOfLines = Self.maximumTitleLineCount
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.imageProperties.tintColor = tintColor(for: content.style)
        cell.contentConfiguration = configuration
        cell.accessories = []
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityLabel = content.accessibilityLabel
        cell.accessibilityValue = content.accessibilityValue
        if copyableTextPayload(for: itemID) != nil {
            cell.accessibilityCustomActions = [UIAccessibilityCustomAction(
                name: copyActionTitle,
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.copyTextPayload(for: itemID) ?? false
            }]
        } else {
            cell.accessibilityCustomActions = nil
        }
    }

    private func contextMenuConfiguration(for itemID: ItemID) -> UIContextMenuConfiguration? {
        guard copyableTextPayload(for: itemID) != nil else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, copyableTextPayload(for: itemID) != nil else {
                return nil
            }
            return UIMenu(children: [copyTextPayloadAction(for: itemID)])
        }
    }

    private func copyTextPayloadAction(for itemID: ItemID) -> UIAction {
        UIAction(
            title: copyActionTitle,
            image: UIImage(systemName: "doc.on.doc")
        ) { [weak self] _ in
            _ = self?.copyTextPayload(for: itemID)
        }
    }

    private var copyActionTitle: String {
        localized("Copy", defaultValue: "Copy")
    }

    private func copyTextPayload(for itemID: ItemID) -> Bool {
        guard isRenderingActive,
              viewIfLoaded?.window != nil,
              let payload = copyableTextPayload(for: itemID) else {
            return false
        }
        textPayloadCopyHandler(payload)
        return true
    }

    private func copyableTextPayload(for itemID: ItemID) -> String? {
        guard case let .timeline(epoch, entryID) = itemID,
              requestEpoch == epoch,
              let entry = webSocket?.timelineEntry(for: entryID),
              case let .frame(frame) = entry.kind,
              frame.kind == .text else {
            return nil
        }
        guard case let .text(payload) = frame.payload else {
            preconditionFailure("A text WebSocket frame must carry a text payload.")
        }
        guard Self.textPayloadTruncationIndex(in: payload) != nil else {
            return nil
        }
        return payload
    }

    private func tintColor(for style: RowContent.Style) -> UIColor {
        switch style {
        case .lifecycle:
            .secondaryLabel
        case .sent:
            .systemOrange
        case .received:
            .systemBlue
        case .error:
            .systemRed
        }
    }

    private static func clear(_ cell: UICollectionViewListCell) {
        cell.contentConfiguration = nil
        cell.accessories = []
        cell.accessibilityLabel = nil
        cell.accessibilityValue = nil
        cell.accessibilityCustomActions = nil
    }

    private func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: WebInspectorUILocalization.bundle)
    }
}

#if DEBUG
extension NetworkWebSocketPreviewViewController {
    package static var listLayoutConfigurationForTesting: UICollectionLayoutListConfiguration {
        listLayoutConfiguration
    }

    package static var maximumRenderedTextPayloadCharactersForTesting: Int {
        maximumRenderedTextPayloadCharacters
    }

    package static var maximumTitleLineCountForTesting: Int {
        maximumTitleLineCount
    }

    package var timelineObservationDeliveryForTesting: PortableObservationTracking.Token? {
        timelineObservation
    }

    package var snapshotForTesting: NSDiffableDataSourceSnapshot<SectionID, ItemID> {
        dataSource.snapshot()
    }

    package var renderedEntryIDsForTesting: [WebSocketTimelineEntry.ID] {
        renderedEntryIDs
    }

    package var requestEpochForTesting: RequestEpoch? {
        requestEpoch
    }

    package func rowContentForTesting(_ itemID: ItemID) -> RowContent? {
        rowContents[itemID]
    }

    package func contextMenuConfigurationForTesting(
        _ itemID: ItemID
    ) -> UIContextMenuConfiguration? {
        contextMenuConfiguration(for: itemID)
    }

    package func setTextPayloadCopyHandlerForTesting(
        _ handler: @escaping @MainActor (String) -> Void
    ) {
        textPayloadCopyHandler = handler
    }

    package var boundRequestForTesting: NetworkRequest? {
        request
    }

    package var boundWebSocketForTesting: WebSocketState? {
        webSocket
    }

    package var isRenderingActiveForTesting: Bool {
        isRenderingActive
    }

    package var snapshotApplyCountForTesting: Int {
        snapshotApplyCountStorageForTesting
    }

    package var tailScrollCountForTesting: Int {
        tailScrollCountStorageForTesting
    }

    package var isFollowingTailForTesting: Bool {
        isFollowingTail
    }

    package var hasPendingObservationStartForTesting: Bool {
        observationStartTask != nil
    }

    package var observationStartTaskForTesting: Task<Void, Never>? {
        observationStartTask
    }

    package func waitForTimelineObservationStartForTesting() async {
        let task = observationStartTask
        await task?.value
    }

    package func setNextSnapshotApplyCompletionForTesting(
        _ completion: @escaping @MainActor () -> Void
    ) {
        precondition(nextSnapshotApplyCompletionForTesting == nil)
        nextSnapshotApplyCompletionForTesting = completion
    }

    package func invokeSnapshotApplyCompletionForTesting(
        epoch: RequestEpoch,
        followsTail: Bool
    ) {
        snapshotApplyDidFinish(epoch: epoch, followsTail: followsTail)
    }

    package func setDeinitHandlerForTesting(_ handler: @escaping @MainActor () -> Void) {
        deinitHandlerForTesting = handler
    }
}
#endif
#endif
