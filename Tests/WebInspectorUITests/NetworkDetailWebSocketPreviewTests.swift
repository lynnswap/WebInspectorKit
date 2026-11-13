#if canImport(UIKit)
import AVFoundation
import ObservationBridge
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import UIKit
@testable import WebInspectorKit
@testable import WebInspectorUINetwork
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailWebSocketPreviewTests: NetworkDetailTestSupport {
    @Test
    func webSocketPreviewRendersAllTimelineRowsWithoutDisclosingBase64Payloads() async throws {
        let context = makeContext()
        let request = try await applyWebSocket(
            to: context,
            requestID: "ws-all-rows",
            url: "wss://example.com/all-rows",
            requestTimestamp: 10,
            responseTimestamp: nil
        )
        let requestID = request.proxyID
        let frames: [Network.WebSocketEvent] = [
            (.frameSent(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 1,
                    mask: true,
                    payloadData: "hello\nworld",
                    payloadLength: 11
                ),
                timestamp: 10.005
            )),
            (.frameReceived(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 2,
                    mask: false,
                    payloadData: "QklOQVJZX1NFQ1JFVA==",
                    payloadLength: 13
                ),
                timestamp: 11.25
            )),
            (.frameSent(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 0,
                    mask: true,
                    payloadData: "Q09OVElOVUFUSU9OX1NFQ1JFVA==",
                    payloadLength: 18
                ),
                timestamp: 12
            )),
            (.frameReceived(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 8,
                    mask: false,
                    payloadData: "Q0xPU0VfU0VDUkVU",
                    payloadLength: 12
                ),
                timestamp: 13
            )),
            (.frameSent(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 9,
                    mask: true,
                    payloadData: "UElOR19TRUNSRVQ=",
                    payloadLength: 11
                ),
                timestamp: 14
            )),
            (.frameReceived(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 10,
                    mask: false,
                    payloadData: "UE9OR19TRUNSRVQ=",
                    payloadLength: 11
                ),
                timestamp: 15
            )),
            (.frameReceived(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 15,
                    mask: false,
                    payloadData: "VU5LTk9XTl9TRUNSRVQ=",
                    payloadLength: 14
                ),
                timestamp: 16
            )),
        ]
        for event in frames {
            await context.apply(.webSocket(event))
        }
        await context.apply(.webSocket(.error(
            id: requestID,
            message: "decode failed",
            timestamp: 17
        )))
        await context.apply(.webSocket(.closed(id: requestID, timestamp: 18)))

        let frameScheduler = ManualNetworkFrameScheduler()
        let viewController = NetworkWebSocketPreviewViewController(frameScheduler: frameScheduler)
        let window = showInWindow(viewController, useUIKitVisibility: true)
        defer { window.isHidden = true }
        viewController.bind(to: request)
        await resumeWebSocketPreview(viewController)

        #expect(NetworkWebSocketPreviewViewController.listLayoutConfigurationForTesting.appearance == .plain)
        #expect(viewController.collectionView.allowsSelection == false)
        #expect(viewController.snapshotForTesting.sectionIdentifiers == [.timeline])
        let itemIDs = viewController.snapshotForTesting.itemIdentifiers
        #expect(itemIDs.count == 11)
        let contents = try itemIDs.map { itemID in
            try #require(viewController.rowContentForTesting(itemID))
        }
        let notReported = String(
            localized: "network.websocket.time.not_reported",
            defaultValue: "Time not reported",
            bundle: WebInspectorUILocalization.bundle
        )
        let sent = String(
            localized: "network.websocket.direction.sent",
            defaultValue: "Sent",
            bundle: WebInspectorUILocalization.bundle
        )
        let textFrame = String(
            localized: "network.websocket.frame.text",
            defaultValue: "Text Frame",
            bundle: WebInspectorUILocalization.bundle
        )
        let binaryFrame = String(
            localized: "network.websocket.frame.binary",
            defaultValue: "Binary Frame",
            bundle: WebInspectorUILocalization.bundle
        )
        let copy = String(
            localized: "Copy",
            defaultValue: "Copy",
            bundle: WebInspectorUILocalization.bundle
        )
        let handshakeResponse = String(
            localized: "network.websocket.handshake.response",
            defaultValue: "Handshake Response",
            bundle: WebInspectorUILocalization.bundle
        )
        #expect(contents[0].title == handshakeResponse)
        #expect(contents[0].style == .lifecycle)
        #expect(contents[0].subtitle.contains("101 Switching Protocols"))
        #expect(contents[0].subtitle.contains(notReported))
        #expect(contents[1].style == .lifecycle)
        #expect(contents[2].title == "hello\nworld")
        #expect(contents[2].style == .sent)
        #expect(contents[2].symbolName == "arrow.up")
        #expect(contents[2].subtitle.contains(sent))
        #expect(contents[2].subtitle.contains(textFrame))
        #expect(contents[2].subtitle.contains("+5 ms"))
        #expect(contents[2].accessibilityLabel == "hello\nworld")
        #expect(contents[2].accessibilityValue == contents[2].subtitle)
        #expect(viewController.contextMenuConfigurationForTesting(itemIDs[2]) != nil)
        #expect(contents[3].style == .received)
        #expect(contents[3].symbolName == "arrow.down")
        #expect(contents[3].title.contains(13.formatted()))
        #expect(contents[3].title.contains(binaryFrame) == false)
        #expect(contents[3].subtitle.contains(binaryFrame))
        #expect(contents[3].accessibilityLabel.contains(binaryFrame))
        #expect(contents[3].accessibilityValue.contains(binaryFrame) == false)
        #expect(viewController.contextMenuConfigurationForTesting(itemIDs[3]) == nil)
        #expect(contents[8].subtitle.contains("15"))
        #expect(contents[9].style == .error)
        #expect(contents[9].title == "decode failed")
        #expect(contents[10].style == .lifecycle)
        let copiedText = contents.flatMap {
            [$0.title, $0.subtitle, $0.accessibilityLabel, $0.accessibilityValue]
        }.joined(separator: "\n")
        for secret in [
            "QklOQVJZX1NFQ1JFVA==",
            "Q09OVElOVUFUSU9OX1NFQ1JFVA==",
            "Q0xPU0VfU0VDUkVU",
            "UElOR19TRUNSRVQ=",
            "UE9OR19TRUNSRVQ=",
            "VU5LTk9XTl9TRUNSRVQ=",
        ] {
            #expect(copiedText.contains(secret) == false)
        }

        viewController.collectionView.layoutIfNeeded()
        let textCell = try #require(
            viewController.collectionView.cellForItem(at: IndexPath(item: 2, section: 0))
                as? UICollectionViewListCell
        )
        let configuration = try #require(
            textCell.contentConfiguration as? UIListContentConfiguration
        )
        #expect(
            configuration.textProperties.numberOfLines
                == NetworkWebSocketPreviewViewController.maximumTitleLineCountForTesting
        )
        #expect(configuration.textProperties.adjustsFontForContentSizeCategory)
        #expect(configuration.secondaryTextProperties.numberOfLines == 0)
        #expect(textCell.accessibilityCustomActions?.map(\.name) == [copy])
        viewController.collectionView.semanticContentAttribute = .forceRightToLeft
        #expect(viewController.collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft)
    }

    @Test
    func webSocketPreviewBoundsLargeTextPayloadAndResolvesFullCopyOnDemand() async throws {
        let context = makeContext()
        let request = try await applyWebSocket(
            to: context,
            requestID: "ws-large-text",
            url: "wss://example.com/large-text"
        )
        let byteLimit = NetworkWebSocketPreviewViewController
            .maximumRenderedTextPayloadUTF8BytesForTesting
        let scalarBoundaryPayload = String(repeating: "a", count: byteLimit - 1)
            + "💡"
            + "scalar-boundary-tail"
        let scalarBoundarySummary = NetworkWebSocketPreviewViewController
            .renderedTextPayloadForTesting(scalarBoundaryPayload)
        #expect(scalarBoundarySummary == String(repeating: "a", count: byteLimit - 1) + "…")
        #expect(scalarBoundarySummary.contains("�") == false)
        let payload = "a"
            + String(repeating: "\u{0301}", count: 1_000_000)
            + "full-payload-tail"
        await context.apply(.webSocket(.frameReceived(
            id: request.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: payload,
                payloadLength: payload.utf8.count
            ),
            timestamp: 12
        )))
        await context.apply(.webSocket(.frameReceived(
            id: request.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 2,
                mask: false,
                payloadData: String(repeating: "QQ==", count: byteLimit),
                payloadLength: byteLimit * 3
            ),
            timestamp: 13
        )))

        let replacement = try await applyWebSocket(
            to: context,
            requestID: "ws-large-text-replacement",
            url: "wss://example.com/large-text-replacement"
        )
        let frameScheduler = ManualNetworkFrameScheduler()
        let viewController = NetworkWebSocketPreviewViewController(frameScheduler: frameScheduler)
        var copiedPayload: String?
        viewController.setTextPayloadCopyHandlerForTesting { payload in
            copiedPayload = payload
        }
        let window = showInWindow(viewController, useUIKitVisibility: true)
        defer { window.isHidden = true }
        viewController.bind(to: request)
        await resumeWebSocketPreview(viewController)

        let itemIDs = viewController.snapshotForTesting.itemIdentifiers
        let textItemID = try #require(itemIDs.dropLast().last)
        let binaryItemID = try #require(itemIDs.last)
        let content = try #require(viewController.rowContentForTesting(textItemID))
        #expect(content.title.utf8.count <= byteLimit + "…".utf8.count)
        #expect(Array(content.title.unicodeScalars.prefix(2).map(\.value)) == [0x61, 0x301])
        #expect(content.title.hasSuffix("…"))
        #expect(content.title.contains("full-payload-tail") == false)
        #expect(content.accessibilityLabel == content.title)
        #expect(content.accessibilityValue.contains("full-payload-tail") == false)
        #expect(viewController.contextMenuConfigurationForTesting(textItemID) != nil)
        #expect(viewController.contextMenuConfigurationForTesting(binaryItemID) == nil)

        viewController.collectionView.layoutIfNeeded()
        let textIndex = try #require(itemIDs.firstIndex(of: textItemID))
        let textCell = try #require(
            viewController.collectionView.cellForItem(at: IndexPath(item: textIndex, section: 0))
                as? UICollectionViewListCell
        )
        let textConfiguration = try #require(
            textCell.contentConfiguration as? UIListContentConfiguration
        )
        #expect(
            textConfiguration.textProperties.numberOfLines
                == NetworkWebSocketPreviewViewController.maximumTitleLineCountForTesting
        )
        #expect(textConfiguration.text == content.title)
        #expect(textCell.accessibilityLabel == content.title)
        #expect(textCell.accessibilityValue?.contains("full-payload-tail") == false)
        let copyAction = try #require(textCell.accessibilityCustomActions?.first)
        #expect(copyAction.name == String(
            localized: "Copy",
            defaultValue: "Copy",
            bundle: WebInspectorUILocalization.bundle
        ))
        #expect(copyAction.actionHandler?(copyAction) == true)
        #expect(copiedPayload == payload)

        let binaryIndex = try #require(itemIDs.firstIndex(of: binaryItemID))
        let binaryCell = try #require(
            viewController.collectionView.cellForItem(at: IndexPath(item: binaryIndex, section: 0))
                as? UICollectionViewListCell
        )
        #expect(binaryCell.accessibilityCustomActions?.isEmpty ?? true)

        copiedPayload = nil
        viewController.suspendKeepingSnapshot()
        #expect(copyAction.actionHandler?(copyAction) == false)
        #expect(copiedPayload == nil)

        viewController.bind(to: replacement)
        await resumeWebSocketPreview(viewController)
        #expect(copyAction.actionHandler?(copyAction) == false)
        #expect(copiedPayload == nil)
    }

    @Test
    func webSocketPreviewRendersRejectedHandshakeWithoutEstablishedRow() async throws {
        let context = makeContext()
        let requestID = Network.Request.ID("ws-rejected-preview")
        await context.apply(.webSocket(.created(
            id: requestID,
            url: "wss://example.com/rejected-preview"
        )))
        await context.apply(.webSocket(.handshakeResponse(
            id: requestID,
            response: Network.Response(
                url: "wss://example.com/rejected-preview",
                status: 403,
                statusText: "Forbidden"
            ),
            timestamp: 2
        )))
        await context.apply(.webSocket(.error(
            id: requestID,
            message: "upgrade failed",
            timestamp: 3
        )))
        await context.apply(.webSocket(.closed(id: requestID, timestamp: 4)))
        let request = try #require(context.registeredRequest(forProxyID: requestID))
        let viewController = NetworkWebSocketPreviewViewController(
            frameScheduler: ManualNetworkFrameScheduler()
        )
        viewController.bind(to: request)
        await resumeWebSocketPreview(viewController)

        let itemIDs = viewController.snapshotForTesting.itemIdentifiers
        #expect(itemIDs.count == 3)
        let contents = try itemIDs.map { itemID in
            try #require(viewController.rowContentForTesting(itemID))
        }
        let rejectionTitle = String(
            localized: "network.websocket.handshake.rejected",
            defaultValue: "Handshake Rejected",
            bundle: WebInspectorUILocalization.bundle
        )
        let establishedTitle = String(
            localized: "network.websocket.connection.established",
            defaultValue: "Connection Established",
            bundle: WebInspectorUILocalization.bundle
        )
        #expect(contents[0].title == rejectionTitle)
        #expect(contents[0].subtitle.contains("403 Forbidden"))
        #expect(contents[0].style == .error)
        #expect(contents[0].symbolName == "exclamationmark.shield")
        #expect(contents[0].accessibilityLabel == rejectionTitle)
        #expect(contents[0].accessibilityValue.contains("403 Forbidden"))
        #expect(contents[1].title == "upgrade failed")
        #expect(contents.contains { $0.title == establishedTitle } == false)
    }

    @Test
    func webSocketPreviewKeepsQuietAndUnreportedHandshakeResponsesNeutral() async throws {
        let handshakeTitle = String(
            localized: "network.websocket.handshake.response",
            defaultValue: "Handshake Response",
            bundle: WebInspectorUILocalization.bundle
        )
        let establishedTitle = String(
            localized: "network.websocket.connection.established",
            defaultValue: "Connection Established",
            bundle: WebInspectorUILocalization.bundle
        )
        let statusNotReported = String(
            localized: "network.websocket.status.not_reported",
            defaultValue: "Status not reported",
            bundle: WebInspectorUILocalization.bundle
        )
        for (suffix, status, statusText) in [
            ("switching", Optional(101), Optional("Switching Protocols")),
            ("unreported", Optional<Int>.none, Optional("Opaque Response")),
        ] {
            let context = makeContext()
            let requestID = Network.Request.ID("ws-neutral-\(suffix)")
            await context.apply(.webSocket(.created(
                id: requestID,
                url: "wss://example.com/neutral-\(suffix)"
            )))
            await context.apply(.webSocket(.handshakeResponse(
                id: requestID,
                response: Network.Response(status: status, statusText: statusText),
                timestamp: 2
            )))
            let request = try #require(context.registeredRequest(forProxyID: requestID))
            let viewController = NetworkWebSocketPreviewViewController(
                frameScheduler: ManualNetworkFrameScheduler()
            )
            viewController.bind(to: request)
            await resumeWebSocketPreview(viewController)

            let itemIDs = viewController.snapshotForTesting.itemIdentifiers
            #expect(itemIDs.count == 1)
            let content = try #require(viewController.rowContentForTesting(itemIDs[0]))
            #expect(content.title == handshakeTitle)
            #expect(content.style == .lifecycle)
            #expect(content.accessibilityLabel == handshakeTitle)
            #expect(content.title != establishedTitle)
            #expect(request.webSocket?.readyState == .connecting)
            if let status {
                #expect(content.subtitle.contains(String(status)))
                #expect(content.subtitle.contains(statusText ?? ""))
            } else {
                #expect(content.subtitle.contains(statusNotReported))
                #expect(content.subtitle.contains(statusText ?? ""))
            }
        }
    }

    @Test
    func webSocketFirstFramePublishesEstablishedAndFrameInOneObservationDelivery() async throws {
        let webSocket = WebSocketState()
        let observation = withPortableContinuousObservation { _ in
            _ = webSocket.timelineEntries
            _ = webSocket.frames
        }
        defer { observation.cancel() }
        let values = await observation.values {
            [webSocket.timelineEntries.count, webSocket.frames.count]
        }
        defer { values.cancel() }
        let deliveryBaseline = values.snapshot().count

        webSocket.appendFrame(
            Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "first",
                payloadLength: 5
            ),
            direction: .received,
            timestamp: 4,
            lifecycleRevision: 3,
            chronologySequence: 8
        )

        #expect(await values.waitUntilValue([2, 1]))
        #expect(values.snapshot().count == deliveryBaseline + 1)
        #expect(values.snapshot().contains([1, 0]) == false)
        #expect(webSocket.readyState == .open)
        #expect(webSocket.timelineEntries.map(\.id) == [
            .init(
                lifecycleRevision: 3,
                chronologySequence: 8,
                ordinalWithinEvent: 0
            ),
            .init(
                lifecycleRevision: 3,
                chronologySequence: 8,
                ordinalWithinEvent: 1
            ),
        ])
    }

    @Test
    func webSocketPreviewCoalescesLiveSuffixAndRetainsExistingRows() async throws {
        let context = makeContext()
        let request = try await applyWebSocket(
            to: context,
            requestID: "ws-live-suffix",
            url: "wss://example.com/live-suffix"
        )
        let requestID = request.proxyID
        await context.apply(.webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "initial",
                payloadLength: 7
            ),
            timestamp: 12
        )))

        let frameScheduler = ManualNetworkFrameScheduler()
        let viewController = NetworkWebSocketPreviewViewController(frameScheduler: frameScheduler)
        let window = showInWindow(viewController, useUIKitVisibility: true)
        defer { window.isHidden = true }
        viewController.bind(to: request)
        await resumeWebSocketPreview(viewController)
        let initialIDs = viewController.snapshotForTesting.itemIdentifiers
        #expect(initialIDs.count == 3)
        let initialCell = try #require(
            viewController.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
        )
        let initialCellIdentity = ObjectIdentifier(initialCell)
        let scheduledFrameBaseline = frameScheduler.scheduledFrameCount

        for (index, timestamp) in [13.0, 12.5, 14.0].enumerated() {
            await context.apply(.webSocket(.frameSent(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 1,
                    mask: true,
                    payloadData: "live-\(index)",
                    payloadLength: 6
                ),
                timestamp: timestamp
            )))
        }

        #expect(await waitUntilWebSocketRenderingFrameScheduled(
            frameScheduler,
            in: viewController
        ))
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 1)
        #expect(frameScheduler.hasScheduledFrame)
        #expect(viewController.snapshotForTesting.itemIdentifiers == initialIDs)
        await fireWebSocketRenderingFrame(frameScheduler, in: viewController)

        let renderedIDs = viewController.snapshotForTesting.itemIdentifiers
        #expect(renderedIDs.count == 6)
        #expect(Array(renderedIDs.prefix(initialIDs.count)) == initialIDs)
        #expect(
            viewController.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
                .map(ObjectIdentifier.init) == initialCellIdentity
        )
        let renderedEntryIDs = viewController.renderedEntryIDsForTesting
        #expect(zip(renderedEntryIDs, renderedEntryIDs.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        })
    }

    @Test
    func webSocketPreviewFollowsTailOnlyWhilePinned() async throws {
        let context = makeContext()
        let request = try await applyWebSocket(
            to: context,
            requestID: "ws-tail",
            url: "wss://example.com/tail"
        )
        let requestID = request.proxyID
        for index in 0..<30 {
            await context.apply(.webSocket(.frameReceived(
                id: requestID,
                frame: Network.WebSocketFrame(
                    opcode: 1,
                    mask: false,
                    payloadData: "row-\(index)",
                    payloadLength: 6
                ),
                timestamp: 12 + Double(index)
            )))
        }

        let frameScheduler = ManualNetworkFrameScheduler()
        let viewController = NetworkWebSocketPreviewViewController(frameScheduler: frameScheduler)
        let window = showInWindow(viewController, useUIKitVisibility: true)
        defer { window.isHidden = true }
        viewController.bind(to: request)
        await resumeWebSocketPreview(viewController)
        #expect(viewController.tailScrollCountForTesting == 1)
        #expect(viewController.isFollowingTailForTesting)
        let epoch = try #require(viewController.requestEpochForTesting)
        let priorApplyGeneration = viewController.snapshotApplyGenerationForTesting
        let priorUserScrollRevision = viewController.userScrollRevisionForTesting

        viewController.collectionView.setContentOffset(
            CGPoint(x: 0, y: -viewController.collectionView.adjustedContentInset.top),
            animated: false
        )
        viewController.collectionView.layoutIfNeeded()
        #expect(viewController.isFollowingTailForTesting == false)
        let offsetBeforeUnpinnedAppend = viewController.collectionView.contentOffset.y
        let scrollCountBeforeUnpinnedAppend = viewController.tailScrollCountForTesting
        await context.apply(.webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "while-unpinned",
                payloadLength: 14
            ),
            timestamp: 50
        )))
        #expect(await waitUntilWebSocketRenderingFrameScheduled(
            frameScheduler,
            in: viewController
        ))
        await fireWebSocketRenderingFrame(frameScheduler, in: viewController)
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeUnpinnedAppend)
        #expect(abs(viewController.collectionView.contentOffset.y - offsetBeforeUnpinnedAppend) < 0.5)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: priorApplyGeneration,
            userScrollRevision: priorUserScrollRevision
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeUnpinnedAppend)

        let lastIndexPath = IndexPath(
            item: viewController.snapshotForTesting.itemIdentifiers.count - 1,
            section: 0
        )
        viewController.collectionView.scrollToItem(
            at: lastIndexPath,
            at: .bottom,
            animated: false
        )
        viewController.collectionView.layoutIfNeeded()
        #expect(viewController.isFollowingTailForTesting)
        let scrollCountBeforePinnedAppend = viewController.tailScrollCountForTesting
        await context.apply(.webSocket(.frameReceived(
            id: requestID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "while-pinned",
                payloadLength: 12
            ),
            timestamp: 51
        )))
        #expect(await waitUntilWebSocketRenderingFrameScheduled(
            frameScheduler,
            in: viewController
        ))
        await fireWebSocketRenderingFrame(frameScheduler, in: viewController)
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforePinnedAppend + 1)
        #expect(viewController.isFollowingTailForTesting)

        let completedApplyGeneration = viewController.snapshotApplyGenerationForTesting
        let userScrollRevisionBeforeDrag = viewController.userScrollRevisionForTesting
        let scrollCountBeforeDrag = viewController.tailScrollCountForTesting
        viewController.scrollViewWillBeginDragging(viewController.collectionView)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionBeforeDrag
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)

        let userScrollRevisionAtDragStart = viewController.userScrollRevisionForTesting
        #expect(viewController.isUserScrollingForTesting)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionAtDragStart
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)
        viewController.scrollViewDidScroll(viewController.collectionView)
        #expect(viewController.userScrollRevisionForTesting > userScrollRevisionAtDragStart)
        viewController.scrollViewDidEndDragging(
            viewController.collectionView,
            willDecelerate: false
        )
        #expect(viewController.isUserScrollingForTesting == false)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionAtDragStart
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)

        viewController.scrollViewWillBeginDragging(viewController.collectionView)
        let userScrollRevisionBeforeDeceleration = viewController.userScrollRevisionForTesting
        viewController.scrollViewDidEndDragging(
            viewController.collectionView,
            willDecelerate: true
        )
        #expect(viewController.isUserScrollingForTesting)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionBeforeDeceleration
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)
        viewController.scrollViewDidScroll(viewController.collectionView)
        viewController.scrollViewDidEndDecelerating(viewController.collectionView)
        #expect(viewController.isUserScrollingForTesting == false)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionBeforeDeceleration
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)

        #expect(viewController.scrollViewShouldScrollToTop(viewController.collectionView))
        let userScrollRevisionAtScrollToTopStart = viewController.userScrollRevisionForTesting
        #expect(viewController.isUserScrollingForTesting)
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionAtScrollToTopStart
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)
        viewController.scrollViewDidScrollToTop(viewController.collectionView)
        #expect(viewController.isUserScrollingForTesting == false)
        #expect(
            viewController.userScrollRevisionForTesting
                > userScrollRevisionAtScrollToTopStart
        )
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionAtScrollToTopStart
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)

        let userScrollRevisionBeforeNonDragScroll = viewController.userScrollRevisionForTesting
        viewController.scrollViewDidScroll(viewController.collectionView)
        #expect(
            viewController.userScrollRevisionForTesting
                > userScrollRevisionBeforeNonDragScroll
        )
        viewController.invokeSnapshotApplyCompletionForTesting(
            epoch: epoch,
            followsTail: true,
            applyGeneration: completedApplyGeneration,
            userScrollRevision: userScrollRevisionBeforeNonDragScroll
        )
        #expect(viewController.tailScrollCountForTesting == scrollCountBeforeDrag)
    }

    @Test
    func webSocketPreviewRoutesOnlyTheActiveGroupedRequestAndReturnsToBodyPreview() async throws {
        let context = makeContext()
        let frameID = FrameID("ws-group-frame")
        installNavigationVisit(in: context, frameID: frameID)

        let webSocketFirstNodeID = DOM.Node.ID("ws-first-node")
        let webSocketFirst = try await applyGroupedWebSocket(
            to: context,
            requestID: "ws-group-first",
            url: "wss://example.com/first",
            frameID: frameID,
            initiatorNodeID: webSocketFirstNodeID,
            timestamp: 1
        )
        await context.apply(.webSocket(.closed(id: webSocketFirst.proxyID, timestamp: 3)))
        let ordinarySecond = try #require(await applyGroupedRequest(
            to: context,
            requestID: "ws-group-ordinary-second",
            url: "https://example.com/second.json",
            frameID: frameID,
            initiatorNodeID: webSocketFirstNodeID,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            resourceType: .xhr,
            timestamp: 4
        ))
        applyResponseBody(
            to: context,
            request: ordinarySecond,
            body: #"{"request":"ordinary-second"}"#
        )

        let ordinaryFirstNodeID = DOM.Node.ID("ordinary-first-node")
        let ordinaryFirst = try #require(await applyGroupedRequest(
            to: context,
            requestID: "ws-group-ordinary-first",
            url: "https://example.com/ordinary-first.json",
            frameID: frameID,
            initiatorNodeID: ordinaryFirstNodeID,
            responseHeaders: ["content-type": "application/json"],
            responseMIMEType: "application/json",
            resourceType: .xhr,
            timestamp: 10
        ))
        applyResponseBody(
            to: context,
            request: ordinaryFirst,
            body: #"{"request":"ordinary-first"}"#
        )
        let webSocketSecond = try await applyGroupedWebSocket(
            to: context,
            requestID: "ws-group-second",
            url: "wss://example.com/second",
            frameID: frameID,
            initiatorNodeID: ordinaryFirstNodeID,
            timestamp: 14
        )

        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: webSocketFirst, in: model)
        let frameScheduler = ManualNetworkFrameScheduler()
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .preview,
            webSocketFrameScheduler: frameScheduler
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilWebSocketPreviewBound(to: webSocketFirst, in: viewController))
        #expect(viewController.webSocketPreviewViewControllerForTesting.view.isHidden == false)
        #expect(viewController.securityViewControllerForTesting.view.isHidden)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 2
        )
        #expect(viewController.previewViewForTesting.isHidden)
        #expect(viewController.isPreviewRoleControlHiddenForTesting)
        #expect(webSocketFirst.canFetchResponseBody == false)
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
        #expect(
            viewController.contentScrollView(for: .top)
                === viewController.webSocketPreviewViewControllerForTesting.collectionView
        )
        #expect(viewController.requestPickerItemForTesting != nil)

        selectMode(.security, on: viewController)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .security
                && viewController.securityViewControllerForTesting.view.isHidden == false
                && viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && viewController.webSocketPreviewViewControllerForTesting
                    .timelineObservationDeliveryForTesting == nil
        })
        #expect(viewController.requestPickerItemForTesting != nil)
        #expect(
            viewController.contentScrollView(for: .top)
                === viewController.securityViewControllerForTesting.collectionView
        )
        let webSocketSnapshotBeforeSecurityUpdate = viewController.webSocketPreviewViewControllerForTesting
            .snapshotForTesting.itemIdentifiers
        let hiddenRawTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.webSocket(.frameReceived(
            id: webSocketFirst.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "security-hidden-update",
                payloadLength: 22
            ),
            timestamp: 2.5
        )))
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: hiddenRawTransactionBaseline))
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers == webSocketSnapshotBeforeSecurityUpdate
        )

        selectMode(.preview, on: viewController)
        #expect(await waitUntilWebSocketPreviewBound(to: webSocketFirst, in: viewController))
        #expect(await waitUntilRendered(in: viewController) {
            viewController.securityViewControllerForTesting.view.isHidden
                && viewController.webSocketPreviewViewControllerForTesting.view.isHidden == false
                && viewController.webSocketPreviewViewControllerForTesting
                    .snapshotForTesting.itemIdentifiers.count == 3
                && viewController.webSocketPreviewViewControllerForTesting
                    .timelineObservationDeliveryForTesting?.isActive == true
        })
        #expect(
            viewController.contentScrollView(for: .top)
                === viewController.webSocketPreviewViewControllerForTesting.collectionView
        )

        let parentRenderBaseline = viewController.selectedRequestRenderCountForTesting
        let scheduledFrameBaseline = frameScheduler.scheduledFrameCount
        let webSocketSnapshotBeforeFrame = viewController.webSocketPreviewViewControllerForTesting
            .snapshotForTesting.itemIdentifiers
        let childObservation = try #require(
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting
        )
        let didScheduleChildFrame = await childObservation.values {
            frameScheduler.hasScheduledFrame
        }
        defer { didScheduleChildFrame.cancel() }
        let rawTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.webSocket(.frameReceived(
            id: webSocketFirst.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "child-only-update",
                payloadLength: 17
            ),
            timestamp: 3
        )))
        #expect(await didScheduleChildFrame.waitUntilValue(true))
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: rawTransactionBaseline))
        #expect(viewController.selectedRequestRenderCountForTesting == parentRenderBaseline)
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 1)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers == webSocketSnapshotBeforeFrame
        )
        await fireWebSocketRenderingFrame(
            frameScheduler,
            in: viewController.webSocketPreviewViewControllerForTesting
        )
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 4
        )

        model.selectRequest(ordinarySecond)
        #expect(await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && viewController.previewViewForTesting.isHidden == false
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text
                    .contains("ordinary-second")
        })
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting == nil
        )

        try selectEntry(containing: ordinaryFirst, in: model)
        #expect(await waitUntilPreparedTextPreviewRendered(in: viewController) {
            viewController.webSocketPreviewViewControllerForTesting.view.isHidden
                && viewController.bodyViewControllerForTesting.syntaxViewForTesting.text
                    .contains("ordinary-first")
        })

        model.selectRequest(webSocketSecond)
        #expect(await waitUntilWebSocketPreviewBound(to: webSocketSecond, in: viewController))
        #expect(viewController.webSocketPreviewViewControllerForTesting.view.isHidden == false)
        #expect(viewController.previewViewForTesting.isHidden)
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
    }

    @Test
    func webSocketPreviewSuspendsCatchesUpAndRebindsAcrossRestartAndSameIDReregistrationAfterClear() async throws {
        let context = makeContext()
        let first = try await applyWebSocket(
            to: context,
            requestID: "ws-rebind-first",
            url: "wss://example.com/rebind-first"
        )
        let second = try await applyWebSocket(
            to: context,
            requestID: "ws-rebind-second",
            url: "wss://example.com/rebind-second"
        )
        let model = NetworkPanelModel(context: context)
        model.selectRequest(first)
        let frameScheduler = ManualNetworkFrameScheduler()
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .preview,
            webSocketFrameScheduler: frameScheduler
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilWebSocketPreviewBound(to: first, in: viewController))
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 1
        )
        let firstTimelineObservation = try #require(
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting
        )
        let snapshotBeforeHide = viewController.webSocketPreviewViewControllerForTesting
            .snapshotForTesting.itemIdentifiers
        let requestEpochBeforeHide = try #require(
            viewController.webSocketPreviewViewControllerForTesting.requestEpochForTesting
        )
        let applyGenerationBeforeHide = viewController.webSocketPreviewViewControllerForTesting
            .snapshotApplyGenerationForTesting
        let userScrollRevisionBeforeHide = viewController.webSocketPreviewViewControllerForTesting
            .userScrollRevisionForTesting

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        #expect(firstTimelineObservation.isActive == false)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting == nil
        )
        await context.apply(.webSocket(.frameReceived(
            id: first.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "hidden",
                payloadLength: 6
            ),
            timestamp: 12
        )))
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers == snapshotBeforeHide
        )

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        #expect(await waitUntilWebSocketPreviewBound(to: first, in: viewController))
        #expect(await waitUntilRendered(in: viewController) {
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 3
        })
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting?.isActive == true
        )
        let tailScrollCountAfterResume = viewController.webSocketPreviewViewControllerForTesting
            .tailScrollCountForTesting
        viewController.webSocketPreviewViewControllerForTesting
            .invokeSnapshotApplyCompletionForTesting(
                epoch: requestEpochBeforeHide,
                followsTail: true,
                applyGeneration: applyGenerationBeforeHide,
                userScrollRevision: userScrollRevisionBeforeHide
            )
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .tailScrollCountForTesting == tailScrollCountAfterResume
        )

        let firstRequestEpoch = try #require(
            viewController.webSocketPreviewViewControllerForTesting.requestEpochForTesting
        )
        let firstApplyGeneration = viewController.webSocketPreviewViewControllerForTesting
            .snapshotApplyGenerationForTesting
        let firstUserScrollRevision = viewController.webSocketPreviewViewControllerForTesting
            .userScrollRevisionForTesting
        model.selectRequest(second)
        #expect(await waitUntilWebSocketPreviewBound(to: second, in: viewController))
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 1
        )
        let tailScrollCountAfterRebind = viewController.webSocketPreviewViewControllerForTesting
            .tailScrollCountForTesting
        viewController.webSocketPreviewViewControllerForTesting
            .invokeSnapshotApplyCompletionForTesting(
                epoch: firstRequestEpoch,
                followsTail: true,
                applyGeneration: firstApplyGeneration,
                userScrollRevision: firstUserScrollRevision
            )
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .tailScrollCountForTesting == tailScrollCountAfterRebind
        )
        let secondSnapshot = viewController.webSocketPreviewViewControllerForTesting
            .snapshotForTesting.itemIdentifiers
        await context.apply(.webSocket(.frameReceived(
            id: first.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "stale-first",
                payloadLength: 11
            ),
            timestamp: 13
        )))
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers == secondSnapshot
        )

        let priorWebSocket = try #require(second.webSocket)
        let priorLifecycleRevision = second.lifecycleRevision
        let priorTimelineObservation = try #require(
            viewController.webSocketPreviewViewControllerForTesting
                .timelineObservationDeliveryForTesting
        )
        let restartTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.webSocket(.closed(id: second.proxyID, timestamp: 14)))
        #expect(await model.waitForRawTransactionDeliveryForTesting(
            after: restartTransactionBaseline
        ))
        let createdTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.webSocket(.created(
            id: second.proxyID,
            url: "wss://example.com/rebind-second-restarted"
        )))
        #expect(await model.waitForRawTransactionDeliveryForTesting(
            after: createdTransactionBaseline
        ))
        let restartedWebSocket = try #require(second.webSocket)
        #expect(restartedWebSocket !== priorWebSocket)
        #expect(await waitUntilWebSocketPreviewBound(
            to: second,
            webSocket: restartedWebSocket,
            in: viewController
        ))
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.isEmpty
        )
        #expect(priorTimelineObservation.isActive == false)
        #expect(frameScheduler.hasScheduledFrame == false)

        priorWebSocket.appendError(
            "stale-old-state",
            timestamp: 15,
            lifecycleRevision: priorLifecycleRevision,
            chronologySequence: 1_000
        )
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.isEmpty
        )

        let transactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.webSocket(.handshakeResponse(
            id: second.proxyID,
            response: Network.Response(
                url: second.url,
                status: 101,
                statusText: "Switching Protocols"
            ),
            timestamp: 16
        )))
        #expect(await waitUntilWebSocketRenderingFrameScheduled(
            frameScheduler,
            in: viewController.webSocketPreviewViewControllerForTesting
        ))
        await fireWebSocketRenderingFrame(
            frameScheduler,
            in: viewController.webSocketPreviewViewControllerForTesting
        )
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 1
        )
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: transactionBaseline))

        let clearedWebSocket = try #require(second.webSocket)
        let reregistrationTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        context.network.clearRequests()
        let reregistered = try await applyWebSocket(
            to: context,
            requestID: "ws-rebind-second",
            url: "wss://example.com/rebind-second-reregistered",
            requestTimestamp: 20,
            responseTimestamp: 21
        )
        #expect(reregistered !== second)
        #expect(await model.waitForRawTransactionDeliveryForTesting(
            after: reregistrationTransactionBaseline + 1
        ))
        model.selectRequest(reregistered)
        #expect(await waitUntilWebSocketPreviewBound(to: reregistered, in: viewController))
        #expect(model.selectedRequest === reregistered)
        #expect(
            viewController.webSocketPreviewViewControllerForTesting
                .snapshotForTesting.itemIdentifiers.count == 1
        )
        clearedWebSocket.appendError(
            "stale-cleared-instance",
            timestamp: 22,
            lifecycleRevision: second.lifecycleRevision,
            chronologySequence: 2_002
        )
        #expect(frameScheduler.hasScheduledFrame == false)
    }

    @Test
    func webSocketPreviewClearAndDeinitReleaseRenderingLifecycle() async throws {
        let context = makeContext()
        let request = try await applyWebSocket(
            to: context,
            requestID: "ws-clear",
            url: "wss://example.com/clear"
        )
        let frameScheduler = ManualNetworkFrameScheduler()
        var viewController: NetworkWebSocketPreviewViewController? =
            NetworkWebSocketPreviewViewController(frameScheduler: frameScheduler)
        viewController?.bind(to: request)
        await resumeWebSocketPreview(try #require(viewController))
        let observation = try #require(viewController?.timelineObservationDeliveryForTesting)

        await context.apply(.webSocket(.frameReceived(
            id: request.proxyID,
            frame: Network.WebSocketFrame(
                opcode: 1,
                mask: false,
                payloadData: "pending",
                payloadLength: 7
            ),
            timestamp: 12
        )))
        #expect(await waitUntilWebSocketRenderingFrameScheduled(
            frameScheduler,
            in: try #require(viewController)
        ))
        viewController?.clear()
        #expect(observation.isActive == false)
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(viewController?.boundRequestForTesting == nil)
        #expect(viewController?.boundWebSocketForTesting == nil)
        #expect(viewController?.snapshotForTesting.itemIdentifiers.isEmpty == true)

        viewController?.bind(to: request)
        viewController?.resumeRendering()
        let deferredObservationStart = try #require(
            viewController?.observationStartTaskForTesting
        )
        #expect(viewController?.hasPendingObservationStartForTesting == true)
        viewController?.clear()
        await deferredObservationStart.value
        #expect(viewController?.timelineObservationDeliveryForTesting == nil)
        #expect(viewController?.snapshotForTesting.itemIdentifiers.isEmpty == true)
        #expect(frameScheduler.hasScheduledFrame == false)

        var didDeinitialize = false
        viewController?.setDeinitHandlerForTesting {
            didDeinitialize = true
        }
        viewController = nil
        #expect(didDeinitialize)
        #expect(frameScheduler.invalidationCount == 1)
    }
}
}
#endif
