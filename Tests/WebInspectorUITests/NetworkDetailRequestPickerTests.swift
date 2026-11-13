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
struct NetworkDetailRequestPickerTests: NetworkDetailTestSupport {
    @Test
    func requestPickerCellTracksLiveRequestAndDetachesOldBinding() async throws {
        let context = makeContext()
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "picker-cell-first",
            url: "https://example.com/first.json"
        ))
        let secondRequest = try #require(await applyRequest(
            to: context,
            requestID: "picker-cell-second",
            url: "https://example.com/second.json"
        ))
        let cell = NetworkDetailRequestPickerCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 44)
        )
        cell.bind(request: firstRequest, renderingActive: true)
        let firstObservation = try #require(cell.requestObservationForTesting)
        let firstRenderedValue = await firstObservation.values {
            [cell.titleForTesting, cell.subtitleForTesting]
        }
        defer { firstRenderedValue.cancel() }

        _ = await applyRequest(
            to: context,
            requestID: "picker-cell-first",
            url: "https://example.com/first-updated.json"
        )

        #expect(await firstRenderedValue.waitUntilValue([
            "first-updated.json",
            "https://example.com/first-updated.json",
        ]))

        cell.bind(request: secondRequest, renderingActive: true)
        #expect(firstObservation.isActive == false)
        #expect(cell.observedRequestForTesting === secondRequest)
        #expect(cell.titleForTesting == "second.json")
        let secondObservation = try #require(cell.requestObservationForTesting)
        let secondRenderedValue = await secondObservation.values {
            [cell.titleForTesting, cell.subtitleForTesting]
        }
        defer { secondRenderedValue.cancel() }

        _ = await applyRequest(
            to: context,
            requestID: "picker-cell-first",
            url: "https://example.com/stale-first.json"
        )

        #expect(cell.titleForTesting == "second.json")
        #expect(cell.subtitleForTesting == "https://example.com/second.json")

        _ = await applyRequest(
            to: context,
            requestID: "picker-cell-second",
            url: "https://example.com/second-updated.json"
        )

        #expect(await secondRenderedValue.waitUntilValue([
            "second-updated.json",
            "https://example.com/second-updated.json",
        ]))

        cell.prepareForReuse()
        #expect(secondObservation.isActive == false)
        #expect(cell.observedRequestForTesting == nil)
        #expect(cell.titleForTesting == nil)
    }

    @Test
    func requestPickerSearchRestartsObservationAndTracksContentMembership() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("picker-search")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-search-first",
            url: "https://example.com/alpha.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-search-second",
            url: "https://example.com/beta.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.entryID(containing: firstRequest.id))
        let entry = try #require(model.entry(for: entryID))
        let originalRequestIDs = entry.requests.map(\.id)
        model.selectEntry(entry)
        let picker = NetworkDetailRequestPickerViewController(
            model: model,
            subject: try #require(model.detailSubject)
        )
        picker.resumeRenderingForTesting()
        let emptyQueryObservation = try #require(picker.modelObservationDeliveryForTesting)

        picker.setSearchTextForTesting("needle")

        #expect(emptyQueryObservation.isActive == false)
        #expect(picker.itemIDsForTesting == [.entry(entryID)])
        let searchObservation = try #require(picker.modelObservationDeliveryForTesting)
        let includesFirstRequest = await searchObservation.values {
            picker.itemIDsForTesting.contains(.request(firstRequest.id))
        }
        defer {
            includesFirstRequest.cancel()
            picker.suspendRenderingForTesting()
        }

        await applyResponseReceived(
            to: context,
            requestID: "picker-search-first",
            url: "https://example.com/needle.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json",
            timestamp: 10
        )

        #expect(await includesFirstRequest.waitUntilValue(true))
        #expect(picker.itemIDsForTesting == [
            .entry(entryID),
            .request(firstRequest.id),
        ])
        #expect(model.entry(for: entryID) === entry)
        #expect(entry.requests.map(\.id) == originalRequestIDs)

        await applyResponseReceived(
            to: context,
            requestID: "picker-search-first",
            url: "https://example.com/miss.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json",
            timestamp: 11
        )

        #expect(await includesFirstRequest.waitUntilValue(false))
        #expect(picker.itemIDsForTesting == [.entry(entryID)])
        #expect(picker.itemIDsForTesting.contains(.request(secondRequest.id)) == false)
        #expect(model.entry(for: entryID) === entry)
        #expect(entry.requests.map(\.id) == originalRequestIDs)
    }

    @Test
    func stalePickerRequestRowCannotSelectARequestThatLeftItsBoundEntry() async throws {
        let context = makeContext()
        let frameID = FrameID("picker-stale-frame")
        let nodeID = DOM.Node.ID("picker-stale-node")
        installNavigationVisit(in: context, frameID: frameID)
        let first = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-stale-first",
            url: "https://example.com/first.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        _ = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-stale-second",
            url: "https://example.com/second.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.entryID(containing: first.id))
        let entry = try #require(model.entry(for: entryID))
        model.selectEntry(entry)
        let subject = try #require(model.detailSubject)
        let picker = NetworkDetailRequestPickerViewController(model: model, subject: subject)
        let window = showInWindow(picker, useUIKitVisibility: true)
        defer { window.isHidden = true }
        picker.resumeRenderingForTesting()
        let firstIndex = try #require(
            picker.itemIDsForTesting.firstIndex(of: .request(first.id))
        )
        let firstCell = try #require(picker.requestCellForTesting(requestID: first.id))
        #expect(firstCell.boundRequest === first)
        picker.suspendRenderingForTesting()

        first.applyRequestWillBeSent(
            request: Network.Request(
                id: first.proxyID,
                url: first.url,
                method: first.method
            ),
            initiator: nil,
            navigationVisit: nil,
            resourceType: first.resourceType,
            timestamp: 20,
            chronologySequence: 20
        )
        model.upsertRequestForTesting(first)
        let currentSubject = try #require(model.detailSubject)
        #expect(currentSubject.intentID == subject.intentID)
        #expect(currentSubject.entry === entry)

        try selectPickerItem(
            at: IndexPath(item: firstIndex, section: 0),
            in: picker
        )

        #expect(model.detailSubject?.hasSameIdentity(as: currentSubject) == true)
        #expect(model.selection == .entry(entryID))
        #expect(model.entryID(containing: first.id) != entryID)
    }

    @Test
    func pickerCarriesExactQueryResetLineageButRejectsNewGenerationSameIDs() async throws {
        let context = makeContext()
        let frameID = FrameID("picker-lineage-frame")
        let nodeID = DOM.Node.ID("picker-lineage-node")
        installNavigationVisit(in: context, frameID: frameID)
        let first = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-lineage-first",
            url: "https://example.com/first.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        _ = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-lineage-second",
            url: "https://example.com/second.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.entryID(containing: first.id))
        let entry = try #require(model.entry(for: entryID))
        model.selectEntry(entry)
        let initialSubject = try #require(model.detailSubject)
        let picker = NetworkDetailRequestPickerViewController(
            model: model,
            subject: initialSubject
        )
        picker.resumeRenderingForTesting()
        let observation = try #require(picker.modelObservationDeliveryForTesting)
        let reboundEntry = await observation.values {
            guard let currentEntry = model.detailSubject?.entry else {
                return false
            }
            return picker.renderedEntryForTesting === currentEntry
                && picker.renderedEntryForTesting !== entry
        }
        defer { reboundEntry.cancel() }

        model.rebuildEntriesForTesting()

        #expect(await reboundEntry.waitUntilValue(true))
        #expect(picker.isObservingModelForTesting)
        #expect(picker.renderedIntentIDForTesting == initialSubject.intentID)
        let carriedSubject = try #require(model.detailSubject)
        let stalePicker = NetworkDetailRequestPickerViewController(
            model: model,
            subject: carriedSubject
        )

        let generationBaseline = model.rawTransactionDeliveryCountForTesting
        context.clearNetworkRequests()
        let replacementFirst = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-lineage-first",
            url: "https://example.com/replacement-first.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 20
        ))
        _ = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-lineage-second",
            url: "https://example.com/replacement-second.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 23
        ))
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: generationBaseline + 6))
        let replacementEntryID = try #require(model.entryID(containing: replacementFirst.id))
        let replacementEntry = try #require(model.entry(for: replacementEntryID))
        #expect(replacementEntryID == entryID)
        model.selectEntry(replacementEntry)
        #expect(model.detailSubject?.intentID != carriedSubject.intentID)

        stalePicker.resumeRenderingForTesting()

        #expect(stalePicker.isObservingModelForTesting == false)
        #expect(stalePicker.renderedEntryForTesting === carriedSubject.entry)
    }

    @Test
    func requestPickerUsesStableEntryAndRequestItemsWithSearch() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("picker")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-first",
            url: "https://example.com/alpha.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-second",
            url: "https://example.com/beta.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let otherNodeID = DOM.Node.ID("picker-other")
        let otherFirstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-other-first",
            url: "https://example.com/other-alpha.json",
            frameID: frameID,
            initiatorNodeID: otherNodeID,
            timestamp: 7
        ))
        let otherSecondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-other-second",
            url: "https://example.com/other-beta.json",
            frameID: frameID,
            initiatorNodeID: otherNodeID,
            timestamp: 10
        ))
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.entryID(containing: firstRequest.id))
        let entry = try #require(model.entry(for: entryID))
        model.selectEntry(entry)
        let detailViewController = NetworkDetailViewController(model: model)
        let window = showInWindow(detailViewController)
        defer { window.isHidden = true }
        let picker = NetworkDetailRequestPickerViewController(
            model: model,
            subject: try #require(model.detailSubject)
        )
        let pickerWindow = showInWindow(picker, useUIKitVisibility: true)
        defer { pickerWindow.isHidden = true }
        let presentationController = UIPresentationController(
            presentedViewController: picker,
            presenting: nil
        )

        picker.resumeRenderingForTesting()

        #expect(
            detailViewController.requestPickerItemForTesting?.accessibilityIdentifier
                == "WebInspector.Network.DetailRequestPickerButton"
        )
        #expect(picker.isObservingModelForTesting)
        #expect(
            picker.adaptivePresentationStyle(
                for: presentationController,
                traitCollection: UITraitCollection(horizontalSizeClass: .compact)
            ) == .pageSheet
        )
        #expect(
            picker.adaptivePresentationStyle(
                for: presentationController,
                traitCollection: UITraitCollection(horizontalSizeClass: .regular)
            ) == .none
        )
        #expect(picker.itemIDsForTesting == [
            .entry(entryID),
            .request(firstRequest.id),
            .request(secondRequest.id),
        ])

        picker.setSearchTextForTesting("beta")

        #expect(picker.itemIDsForTesting == [
            .entry(entryID),
            .request(secondRequest.id),
        ])

        try selectPickerItem(at: IndexPath(item: 1, section: 0), in: picker)

        #expect(model.selection == .request(entryID: entryID, requestID: secondRequest.id))
        #expect(picker.isObservingModelForTesting == false)

        picker.setSearchTextForTesting("")
        picker.resumeRenderingForTesting()
        try selectPickerItem(at: IndexPath(item: 0, section: 0), in: picker)

        #expect(model.selection == .entry(entryID))

        picker.resumeRenderingForTesting()
        let observation = try #require(picker.modelObservationDeliveryForTesting)
        let selectedItem = await observation.values {
            picker.selectedItemIDForTesting
                == .request(secondRequest.id)
        }
        let itemCount = await observation.values {
            picker.itemIDsForTesting.count
        }
        let stoppedObserving = await observation.values {
            picker.isObservingModelForTesting == false
        }
        defer {
            selectedItem.cancel()
            itemCount.cancel()
            stoppedObserving.cancel()
        }

        model.selectRequest(secondRequest)

        #expect(await selectedItem.waitUntilValue(true))
        #expect(picker.isObservingModelForTesting)
        #expect(picker.boundEntryIDForTesting == entryID)

        let thirdRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "picker-third",
            url: "https://example.com/gamma.json",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 13
        ))

        #expect(await itemCount.waitUntilValue(4))
        #expect(picker.itemIDsForTesting == [
            .entry(entryID),
            .request(firstRequest.id),
            .request(secondRequest.id),
            .request(thirdRequest.id),
        ])
        let originalItemIDs = picker.itemIDsForTesting
        let otherEntryID = try #require(model.entryID(containing: otherFirstRequest.id))
        let otherEntry = try #require(model.entry(for: otherEntryID))

        model.selectEntry(otherEntry)

        #expect(await stoppedObserving.waitUntilValue(true))
        #expect(picker.isObservingModelForTesting == false)
        #expect(picker.boundEntryIDForTesting == entryID)
        #expect(picker.itemIDsForTesting == originalItemIDs)
        #expect(picker.itemIDsForTesting.contains(.request(otherFirstRequest.id)) == false)
        #expect(picker.itemIDsForTesting.contains(.request(otherSecondRequest.id)) == false)
    }

    @Test
    func requestPickerListsEveryMemberOfLargeGroupedEntry() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("large-picker")
        installNavigationVisit(in: context, frameID: frameID)
        for index in 0..<2_305 {
            await applyGroupedPendingRequest(
                to: context,
                requestID: "picker-\(index)",
                frameID: frameID,
                initiatorNodeID: nodeID,
                timestamp: Double(index)
            )
        }
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.displayEntryIDs.first)
        let entry = try #require(model.entry(for: entryID))
        model.selectEntry(entry)
        let picker = NetworkDetailRequestPickerViewController(
            model: model,
            subject: try #require(model.detailSubject)
        )

        picker.resumeRenderingForTesting()

        #expect(picker.itemIDsForTesting.count == 2_306)
        #expect(picker.itemIDsForTesting.first == .entry(entryID))
        picker.suspendRenderingForTesting()
    }
}
}
#endif
