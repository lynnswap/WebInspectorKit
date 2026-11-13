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
struct NetworkListRenderingTests: NetworkDetailTestSupport {
    @Test
    func resourceFilterSpecialistTitlesFollowWebInspectorLabels() {
        #expect(NetworkDisplay.ResourceFilter.stylesheet.localizedTitle == "CSS")
        #expect(NetworkDisplay.ResourceFilter.media.localizedTitle == String(localized: "network.filter.media", bundle: WebInspectorUILocalization.bundle))
        #expect(localizedResourceString("network.filter.media", locale: "en") == "Media")
        #expect(NetworkDisplay.ResourceFilter.script.localizedTitle == "JS")
        #expect(NetworkDisplay.ResourceFilter.xhrFetch.localizedTitle == "XHR / Fetch")
    }

    @Test
    func listShowsSimpleEmptyStateWithoutRequests() {
        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.collectionViewForTesting.isHidden)
        #expect(viewController.contentUnavailableConfiguration != nil)
        let configuration = viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        #expect(
            configuration?.text == String(
                localized: "network.empty.none.title",
                defaultValue: "None",
                bundle: WebInspectorUILocalization.bundle
            )
        )
        #expect(configuration?.secondaryText == nil)
        #expect(configuration?.image == nil)
        #expect(configuration?.textProperties.color == .secondaryLabel)
    }

    @Test
    func listDistinguishesNoMatchesFromNoRequests() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
            to: context,
            requestID: "empty-state-search",
            url: "https://example.com/app.js"
        ))
        let model = NetworkPanelModel(context: context)
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
        defer { window.isHidden = true }
        await viewController.flushPendingSnapshotUpdateForTesting()

        var transactionBaseline = viewController.listTransactionDeliveryCountForTesting
        model.setSearchText("does-not-match")
        #expect(await waitUntilListShows(
            [],
            in: viewController,
            afterTransactionDeliveryCount: transactionBaseline
        ))

        let noResults = try #require(
            viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        )
        #expect(noResults.text == String(
            localized: "network.no_results.title",
            defaultValue: "No Results",
            bundle: WebInspectorUILocalization.bundle
        ))
        #expect(noResults.secondaryText == nil)
        #expect(noResults.image != nil)
        #expect(viewController.collectionViewForTesting.isHidden)

        transactionBaseline = viewController.listTransactionDeliveryCountForTesting
        model.setSearchText("")
        #expect(await waitUntilListShows(
            [try #require(model.displayRequests.first?.id)],
            in: viewController,
            afterTransactionDeliveryCount: transactionBaseline
        ))

        #expect(viewController.contentUnavailableConfiguration == nil)
        #expect(viewController.collectionViewForTesting.isHidden == false)
    }

    @Test
    func listUsesNativeInsetGroupedLayout() {
        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        let window = showInWindow(viewController, makeVisible: true)
        defer { window.isHidden = true }

        #expect(
            viewController.collectionViewForTesting.collectionViewLayout
                is UICollectionViewCompositionalLayout
        )
        let configuration = NetworkListViewController.listLayoutConfigurationForTesting
        #expect(configuration.appearance == .insetGrouped)
        #expect(configuration.showsSeparators)
    }

    @Test
    func listCanDisableBackgroundDrawing() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let model = NetworkPanelModel(context: makeContext())
        let viewController = NetworkListViewController(model: model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.backgroundColor == .clear)
    }

    @Test
    func listLoadDefersFilterMenuBuildUntilPresentation() throws {
        let model = NetworkPanelModel(context: makeContext())
        model.setResourceFilter(.media, enabled: true)
        let viewController = NetworkListViewController(model: model)

        viewController.loadViewIfNeeded()

        let filterItem = viewController.filterItemForTesting
        #expect(filterItem.accessibilityIdentifier == "WebInspector.Network.FilterButton")
        #expect(filterItem.isSelected)
        #expect(viewController.filterMenuBuildCountForTesting == 0)
        let menu = try #require(filterItem.menu)
        #expect(menu.children.count == 1)
        let child = try #require(menu.children.first)
        #expect(child is UIDeferredMenuElement)
    }

    @Test
    func listLoadDoesNotEvaluateDisplayRequestsUntilAppearing() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/api/data.json",
            responseHeaders: ["content-type": "application/json"],
            responseMimeType: "application/json"
        ))
        let model = NetworkPanelModel(context: context)
        let viewController = NetworkListViewController(model: model)

        viewController.loadViewIfNeeded()

        #expect(viewController.displayRequestIDsEvaluationCountForTesting == 0)
        #expect(viewController.displayedRequestIDsForTesting.isEmpty)

        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        await viewController.flushPendingSnapshotUpdateForTesting()

        #expect(viewController.displayedRequestIDsForTesting == model.displayRequestIDs)
        #expect(viewController.displayRequestIDsEvaluationCountForTesting == 1)
    }

    @Test
    func visibleListAppliesLiveInsertThroughListTransactions() async throws {
        let context = makeContext()
        let firstRequest = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/first.js"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [firstRequest.id])

        let evaluationCountBeforeInsert = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeInsert = listViewController.snapshotApplyCountForTesting
        let transactionDeliveryCountBeforeInsert = listViewController.listTransactionDeliveryCountForTesting
        let secondRequest = try #require(await applyRequest(
            to: context,
            requestID: "2",
            url: "https://example.com/second.js"
        ))

        let didRenderInsert = await waitUntilListShows(
            [secondRequest.id, firstRequest.id],
            in: listViewController,
            afterTransactionDeliveryCount: transactionDeliveryCountBeforeInsert
        )
        #expect(didRenderInsert)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeInsert + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeInsert + 1)
    }

    @Test
    func visibleListCoalescesContinuousTopologyTransactionsAtDisplayUpdateBoundary() async throws {
        let context = makeContext()
        let selectedRequestID = context.seedNetworkRequest(
            requestID: "selected-request",
            url: "https://example.test/selected.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: -1
        )
        let model = NetworkPanelModel(context: context)
        let selectedRequest = try #require(context.network.request(for: selectedRequestID))
        model.selectRequest(selectedRequest)
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer {
            listViewController.suspendRenderingForTesting()
            window.isHidden = true
        }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [selectedRequest.id])
        let snapshotApplyBaseline = listViewController.snapshotApplyCountForTesting
        let projectionFlushBaseline = listViewController.listProjectionFlushCountForTesting
        let targetCaptureBaseline = listViewController.displayRequestIDsEvaluationCountForTesting
        let scheduledFrameBaseline = frameScheduler.scheduledFrameCount
        let insertedRequestCount = 2_305
        let frameRequestDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        let rawTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        for index in 0..<insertedRequestCount {
            context.seedNetworkRequest(
                requestID: "request-\(index)",
                url: "https://example.test/\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }

        try #require(await model.waitForRawTransactionDeliveryForTesting(
            after: rawTransactionBaseline + insertedRequestCount - 1,
            timeout: .seconds(10)
        ))
        try #require(await listViewController.waitForListTransactionDeliveryForTesting(
            after: frameRequestDeliveryBaseline
        ))
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 1)
        try #require(frameScheduler.hasScheduledFrame)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)

        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        let buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 2)
        #expect(buildStatistics.maximumActiveBuildCount == 1)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()

        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 2)
        try #require(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        let finalEntryIDs = model.displayEntryIDs
        #expect(listViewController.displayedEntryIDsForTesting == finalEntryIDs)
        #expect(finalEntryIDs.count == insertedRequestCount + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline + 1)
        #expect(listViewController.listProjectionFlushCountForTesting == projectionFlushBaseline + 1)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == targetCaptureBaseline + 1)
        #expect(model.selectedRequest === selectedRequest)
        let selectedEntryID = try #require(model.selectedEntryID)
        #expect(
            listViewController.collectionViewForTesting.indexPathsForSelectedItems
                == [IndexPath(
                    item: try #require(finalEntryIDs.firstIndex(of: selectedEntryID)),
                    section: 0
                )]
        )
    }

    @Test
    func completedListSnapshotBuildWaitsForDisplayFrameBeforeApplying() async throws {
        let context = makeContext()
        let requestID = context.seedNetworkRequest(
            requestID: "frame-admission",
            url: "https://example.test/frame-admission.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let request = try #require(context.network.request(for: requestID))
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        #expect(listViewController.snapshotApplyCountForTesting == 0)
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()

        try #require(listViewController.snapshotApplyCountForTesting == 0)
        try #require(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.snapshotApplyCountForTesting == 1)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func concreteListSnapshotBuilderFactoryMakesDedicatedActors() async throws {
        let context = makeContext()
        context.seedNetworkRequest(
            requestID: "actor-builder",
            url: "https://example.test/actor-builder.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let target = NetworkPanelListProjection(
            version: NetworkPanelListVersion(revision: 41, entryIdentityGeneration: 0),
            content: .entries(model.displayEntryIDs)
        )
        let input = makeNetworkListSnapshotBuildInput(target: target)
        let builderFactory = NetworkListSnapshotBuilderFactory()
        let builder = builderFactory.makeBuilder()
        let nextBuilder = builderFactory.makeBuilder()

        let artifact = try await builder.build(input)

        #expect(ObjectIdentifier(builder) != ObjectIdentifier(nextBuilder))
        #expect(artifact.input == input)
        #expect(artifact.snapshot.sectionIdentifiers == [.main])
        #expect(artifact.snapshot.itemIdentifiers == input.target.entryIDs)
        #expect(artifact.changeCounts.inserted == 1)
    }

    @Test
    func concreteListSnapshotBuilderRetainsEveryEntryAcrossCooperativeBatches() async throws {
        let context = makeContext()
        let entryCount = 769
        for index in 0..<entryCount {
            context.seedNetworkRequest(
                requestID: "cooperative-builder-\(index)",
                url: "https://example.test/cooperative-builder-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let target = NetworkPanelListProjection(
            version: NetworkPanelListVersion(revision: 42, entryIdentityGeneration: 0),
            content: .entries(NetworkPanelModel(context: context).displayEntryIDs)
        )
        let input = makeNetworkListSnapshotBuildInput(target: target)
        let builder = NetworkListSnapshotBuilderFactory().makeBuilder()

        let artifact = try await builder.build(input)

        #expect(input.target.entryIDs.count == entryCount)
        #expect(artifact.input == input)
        #expect(artifact.snapshot.itemIdentifiers == input.target.entryIDs)
        #expect(artifact.changeCounts.inserted == entryCount)
    }

    @Test
    func listInvalidationAccumulatorCoalescesBurstAndRetainsEntryIdentityGeneration() async {
        let accumulator = NetworkListInvalidationAccumulator()

        for revision in 1...4 {
            await accumulator.receiveForTesting(NetworkPanelListInvalidation(
                version: NetworkPanelListVersion(
                    revision: UInt64(revision),
                    entryIdentityGeneration: revision >= 3 ? 1 : 0
                )
            ))
        }

        var state = await accumulator.stateForTesting
        #expect(state.latestVersion == NetworkPanelListVersion(
            revision: 4,
            entryIdentityGeneration: 1
        ))
        #expect(state.frameRequestPublicationCount == 1)
        #expect(state.outstandingRevision == 1)

        await accumulator.didCapture(NetworkPanelListVersion(
            revision: 4,
            entryIdentityGeneration: 1
        ))
        state = await accumulator.stateForTesting
        #expect(state.frameRequestPublicationCount == 1)
        #expect(state.outstandingRevision == nil)
    }

    @Test
    func staleListCaptureAcknowledgementCannotClearANewerFrameRequest() async {
        let accumulator = NetworkListInvalidationAccumulator()
        let version1 = NetworkPanelListVersion(revision: 1, entryIdentityGeneration: 0)
        let version2 = NetworkPanelListVersion(revision: 2, entryIdentityGeneration: 0)
        let version3 = NetworkPanelListVersion(revision: 3, entryIdentityGeneration: 1)

        await accumulator.receiveForTesting(NetworkPanelListInvalidation(version: version1))
        await accumulator.didCapture(version2)
        await accumulator.receiveForTesting(NetworkPanelListInvalidation(version: version3))

        var state = await accumulator.stateForTesting
        #expect(state.lastCapturedRevision == 2)
        #expect(state.outstandingRevision == 3)
        #expect(state.frameRequestPublicationCount == 2)

        await accumulator.didCapture(version1)

        state = await accumulator.stateForTesting
        #expect(state.lastCapturedRevision == 2)
        #expect(state.outstandingRevision == 3)
        #expect(state.frameRequestPublicationCount == 2)

        await accumulator.didCapture(version3)
        state = await accumulator.stateForTesting
        #expect(state.lastCapturedRevision == 3)
        #expect(state.outstandingRevision == nil)
        #expect(state.frameRequestPublicationCount == 2)
    }

    @Test
    func displayCriteriaChangesDoNotAdvanceEntryIdentityGeneration() async throws {
        let context = makeContext()
        for name in ["alpha", "beta"] {
            context.seedNetworkRequest(
                requestID: "criteria-\(name)",
                url: "https://example.test/criteria-\(name).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: 0
            )
        }
        let model = NetworkPanelModel(context: context)
        let baselineProjection = model.captureListProjection()
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineProjection.entryIDs,
            version: baselineProjection.version,
            generation: 5
        )

        model.setSearchText("alpha")
        let filteredProjection = model.captureListProjection()
        let artifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: filteredProjection
            )
        )

        #expect(filteredProjection.entryIDs.count == 1)
        #expect(
            filteredProjection.version.entryIdentityGeneration
                == baselineProjection.version.entryIdentityGeneration
        )
        #expect(artifact.changeCounts.reconfigured == 0)
        #expect(artifact.snapshot.reconfiguredItemIdentifiers.isEmpty)

        model.setSearchText("no-match")
        let emptyProjection = model.captureListProjection()
        #expect(emptyProjection.entryIDs.isEmpty)
        #expect(emptyProjection.version.revision > filteredProjection.version.revision)
        #expect(
            emptyProjection.version.entryIdentityGeneration
                == baselineProjection.version.entryIdentityGeneration
        )
    }

    @Test
    func concreteListSnapshotBuilderReconfiguresStableRowsAfterReset() async throws {
        let context = makeContext()
        for index in 0..<3 {
            context.seedNetworkRequest(
                requestID: "reset-rebind-\(index)",
                url: "https://example.test/reset-rebind-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let entryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: entryIDs,
            version: NetworkPanelListVersion(revision: 7, entryIdentityGeneration: 0),
            generation: 3
        )
        let input = makeNetworkListSnapshotBuildInput(
            baseline: baseline,
            target: NetworkPanelListProjection(
                version: NetworkPanelListVersion(revision: 8, entryIdentityGeneration: 1),
                content: .entries(entryIDs)
            )
        )

        let artifact = try await NetworkListSnapshotBuilder().build(input)

        #expect(artifact.snapshot.itemIdentifiers == entryIDs)
        #expect(Set(artifact.snapshot.reconfiguredItemIdentifiers) == Set(entryIDs))
        let cleanBaseline = artifact.makeSubmittedBaseline(generation: 4)
        let cleanArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: cleanBaseline,
                target: input.target
            )
        )
        #expect(cleanArtifact.snapshot.reconfiguredItemIdentifiers.isEmpty)
        #expect(artifact.changeCounts == NetworkListSnapshotChangeCounts(
            inserted: 0,
            deleted: 0,
            moved: 0,
            reconfigured: entryIDs.count
        ))
    }

    @Test
    func listSnapshotBaselineConstructsOneCanonicalMainSection() async throws {
        let context = makeContext()
        for index in 0..<3 {
            context.seedNetworkRequest(
                requestID: "canonical-baseline-\(index)",
                url: "https://example.test/canonical-baseline-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let entryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let version = NetworkPanelListVersion(revision: 20, entryIdentityGeneration: 0)
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: entryIDs,
            version: version,
            generation: 8
        )

        let artifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(version: version, content: .entries(entryIDs))
            )
        )

        #expect(baseline.entryIDs == entryIDs)
        #expect(artifact.snapshot.sectionIdentifiers == [.main])
        #expect(artifact.snapshot.itemIdentifiers == entryIDs)
        #expect(artifact.changeCounts.requiresApply == false)
    }

    @Test
    func listSnapshotStateOwnsNoOpAndBothFreshnessBoundaries() async throws {
        let context = makeContext()
        for index in 0..<2 {
            context.seedNetworkRequest(
                requestID: "state-freshness-\(index)",
                url: "https://example.test/state-freshness-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let allEntryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baselineEntryIDs = Array(allEntryIDs.prefix(1))
        let version1 = NetworkPanelListVersion(revision: 21, entryIdentityGeneration: 0)
        let version2 = NetworkPanelListVersion(revision: 22, entryIdentityGeneration: 0)
        let version3 = NetworkPanelListVersion(revision: 23, entryIdentityGeneration: 0)
        let version4 = NetworkPanelListVersion(revision: 24, entryIdentityGeneration: 0)
        let originalBaseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineEntryIDs,
            version: version1,
            generation: 4
        )
        var state = NetworkListViewController.SnapshotState(
            submittedBaseline: originalBaseline
        )
        let noOpArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: originalBaseline,
                target: NetworkPanelListProjection(
                    version: version2,
                    content: .entries(baselineEntryIDs)
                )
            )
        )

        let noOpResult = state.receive(noOpArtifact, currentVersion: version2)
        #expect(noOpResult == .unchanged)
        #expect(state.submittedBaseline.generation == originalBaseline.generation)
        #expect(state.submittedBaseline.version == version2)
        #expect(state.submittedBaseline.entryIDs == baselineEntryIDs)
        #expect(state.hasReadyArtifact == false)

        let oldBaselineArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: originalBaseline,
                target: NetworkPanelListProjection(
                    version: version3,
                    content: .entries(allEntryIDs)
                )
            )
        )
        let staleBaselineResult = state.receive(
            oldBaselineArtifact,
            currentVersion: version3
        )
        #expect(staleBaselineResult == .stale)
        #expect(state.hasReadyArtifact == false)

        let currentArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(
                    version: version3,
                    content: .entries(allEntryIDs)
                )
            )
        )
        let currentResult = state.receive(currentArtifact, currentVersion: version3)
        #expect(currentResult == .ready)
        guard case .stale = state.prepare(currentVersion: version4) else {
            Issue.record("A ready artifact must be rejected when its target version becomes stale.")
            return
        }
        #expect(state.isApplying == false)
        #expect(state.hasReadyArtifact == false)
        #expect(state.submittedBaseline.version == version2)
    }

    @Test
    func staleIncomingSnapshotArtifactPreservesAnExistingCurrentReadyArtifact() async throws {
        let context = makeContext()
        for index in 0..<2 {
            context.seedNetworkRequest(
                requestID: "state-ready-\(index)",
                url: "https://example.test/state-ready-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let allEntryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baselineEntryIDs = Array(allEntryIDs.prefix(1))
        let version1 = NetworkPanelListVersion(revision: 25, entryIdentityGeneration: 0)
        let version2 = NetworkPanelListVersion(revision: 26, entryIdentityGeneration: 0)
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineEntryIDs,
            version: version1,
            generation: 2
        )
        var state = NetworkListViewController.SnapshotState(submittedBaseline: baseline)
        let currentArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(
                    version: version2,
                    content: .entries(allEntryIDs)
                )
            )
        )
        let staleArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(
                    version: version1,
                    content: .entries(baselineEntryIDs)
                )
            )
        )

        let currentResult = state.receive(currentArtifact, currentVersion: version2)
        #expect(currentResult == .ready)
        let preservedReadyResult = state.receive(staleArtifact, currentVersion: version2)
        #expect(preservedReadyResult == .ready)
        #expect(state.hasReadyArtifact)
        guard case .apply(let application) = state.prepare(currentVersion: version2) else {
            Issue.record("The current ready artifact must remain available after a stale arrival.")
            return
        }
        #expect(application.snapshot.itemIdentifiers == allEntryIDs)
        let finishResult = state.finish(application.id)
        #expect(finishResult == .idle)
    }

    @Test
    func listSnapshotStateSerializesReadyArtifactsAndRejectsOldApplicationCompletions() async throws {
        let context = makeContext()
        context.seedNetworkRequest(
            requestID: "state-application-id",
            url: "https://example.test/state-application-id.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let entryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let version1 = NetworkPanelListVersion(revision: 27, entryIdentityGeneration: 0)
        let version2 = NetworkPanelListVersion(revision: 28, entryIdentityGeneration: 1)
        let version3 = NetworkPanelListVersion(revision: 29, entryIdentityGeneration: 2)
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: entryIDs,
            version: version1,
            generation: 0
        )
        var state = NetworkListViewController.SnapshotState(submittedBaseline: baseline)
        let firstArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(version: version2, content: .entries(entryIDs))
            )
        )
        let firstReceiveResult = state.receive(firstArtifact, currentVersion: version2)
        #expect(firstReceiveResult == .ready)
        guard case .apply(let firstApplication) = state.prepare(currentVersion: version2) else {
            Issue.record("The first reconfiguration must begin applying.")
            return
        }
        #expect(state.isApplying)
        #expect(state.submittedBaseline.generation == 1)

        let secondArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(version: version3, content: .entries(entryIDs))
            )
        )
        let secondReceiveResult = state.receive(secondArtifact, currentVersion: version3)
        #expect(secondReceiveResult == .ready)
        let preservedQueuedResult = state.receive(firstArtifact, currentVersion: version3)
        #expect(preservedQueuedResult == .ready)
        #expect(state.hasReadyArtifact)
        guard case .none = state.prepare(currentVersion: version3) else {
            Issue.record("A second artifact must wait for the active UIKit application.")
            return
        }
        let firstFinishResult = state.finish(firstApplication.id)
        #expect(firstFinishResult == .ready)
        guard case .apply(let secondApplication) = state.prepare(currentVersion: version3) else {
            Issue.record("The queued artifact must apply after the first completion.")
            return
        }
        #expect(secondApplication.id != firstApplication.id)
        let staleFinishResult = state.finish(firstApplication.id)
        #expect(staleFinishResult == .stale)
        #expect(state.isApplying)
        let secondFinishResult = state.finish(secondApplication.id)
        #expect(secondFinishResult == .idle)
        #expect(state.isApplying == false)

        let cleanArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(version: version3, content: .entries(entryIDs))
            )
        )
        #expect(cleanArtifact.changeCounts.requiresApply == false)
        #expect(cleanArtifact.snapshot.reconfiguredItemIdentifiers.isEmpty)
    }

    @Test
    func listSnapshotStateNoOpAndDiscardSupersedeQueuedArtifacts() async throws {
        let context = makeContext()
        for index in 0..<2 {
            context.seedNetworkRequest(
                requestID: "state-discard-\(index)",
                url: "https://example.test/state-discard-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let allEntryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baselineEntryIDs = Array(allEntryIDs.prefix(1))
        let version1 = NetworkPanelListVersion(revision: 30, entryIdentityGeneration: 0)
        let version2 = NetworkPanelListVersion(revision: 31, entryIdentityGeneration: 0)
        let version3 = NetworkPanelListVersion(revision: 32, entryIdentityGeneration: 0)
        let version4 = NetworkPanelListVersion(revision: 33, entryIdentityGeneration: 0)
        let version5 = NetworkPanelListVersion(revision: 34, entryIdentityGeneration: 0)
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineEntryIDs,
            version: version1,
            generation: 0
        )
        var state = NetworkListViewController.SnapshotState(submittedBaseline: baseline)
        let readyArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(version: version2, content: .entries(allEntryIDs))
            )
        )
        let noOpArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(version: version3, content: .entries(baselineEntryIDs))
            )
        )

        let readyResult = state.receive(readyArtifact, currentVersion: version2)
        #expect(readyResult == .ready)
        let noOpResult = state.receive(noOpArtifact, currentVersion: version3)
        #expect(noOpResult == .unchanged)
        #expect(state.hasReadyArtifact == false)
        #expect(state.submittedBaseline.version == version3)

        let applyingArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(version: version4, content: .entries(allEntryIDs))
            )
        )
        let applyingResult = state.receive(applyingArtifact, currentVersion: version4)
        #expect(applyingResult == .ready)
        guard case .apply(let application) = state.prepare(currentVersion: version4) else {
            Issue.record("The current artifact must begin applying.")
            return
        }
        let queuedArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(
                    version: version5,
                    content: .entries(baselineEntryIDs)
                )
            )
        )
        let queuedResult = state.receive(queuedArtifact, currentVersion: version5)
        #expect(queuedResult == .ready)
        let discardedReadyArtifact = state.discardReadyArtifact()
        #expect(discardedReadyArtifact)
        #expect(state.hasReadyArtifact == false)
        #expect(state.isApplying)
        let finishResult = state.finish(application.id)
        #expect(finishResult == .idle)
        guard case .none = state.prepare(currentVersion: version5) else {
            Issue.record("Discarding queued work must leave no application to prepare.")
            return
        }
    }

    @Test
    func listSnapshotStateNoOpSupersedesQueuedWorkWithoutFinishingTheActiveApplication() async throws {
        let context = makeContext()
        for index in 0..<3 {
            context.seedNetworkRequest(
                requestID: "state-applying-no-op-\(index)",
                url: "https://example.test/state-applying-no-op-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let allEntryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baselineEntryIDs = Array(allEntryIDs.prefix(1))
        let applyingEntryIDs = Array(allEntryIDs.prefix(2))
        let version1 = NetworkPanelListVersion(revision: 35, entryIdentityGeneration: 0)
        let version2 = NetworkPanelListVersion(revision: 36, entryIdentityGeneration: 0)
        let version3 = NetworkPanelListVersion(revision: 37, entryIdentityGeneration: 0)
        let version4 = NetworkPanelListVersion(revision: 38, entryIdentityGeneration: 0)
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineEntryIDs,
            version: version1,
            generation: 0
        )
        var state = NetworkListViewController.SnapshotState(submittedBaseline: baseline)
        let applyingArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: baseline,
                target: NetworkPanelListProjection(
                    version: version2,
                    content: .entries(applyingEntryIDs)
                )
            )
        )
        let applyingReceiveResult = state.receive(
            applyingArtifact,
            currentVersion: version2
        )
        #expect(applyingReceiveResult == .ready)
        guard case .apply(let application) = state.prepare(currentVersion: version2) else {
            Issue.record("The first artifact must begin applying.")
            return
        }
        let submittedGeneration = state.submittedBaseline.generation

        let queuedArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(version: version3, content: .entries(allEntryIDs))
            )
        )
        let noOpArtifact = try await NetworkListSnapshotBuilder().build(
            makeNetworkListSnapshotBuildInput(
                baseline: state.submittedBaseline,
                target: NetworkPanelListProjection(
                    version: version4,
                    content: .entries(applyingEntryIDs)
                )
            )
        )
        let queuedResult = state.receive(queuedArtifact, currentVersion: version3)
        #expect(queuedResult == .ready)
        let noOpResult = state.receive(noOpArtifact, currentVersion: version4)

        #expect(noOpResult == .unchanged)
        #expect(state.isApplying)
        #expect(state.hasReadyArtifact == false)
        #expect(state.submittedBaseline.generation == submittedGeneration)
        #expect(state.submittedBaseline.version == version4)
        #expect(state.submittedBaseline.entryIDs == applyingEntryIDs)

        let finishResult = state.finish(application.id)
        #expect(finishResult == .idle)
        guard case .none = state.prepare(currentVersion: version4) else {
            Issue.record("A no-op must supersede queued work without creating another apply.")
            return
        }
    }

    @Test
    func visibleStableRowRebindsToRebuiltEntryAfterModelReset() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "stable-reset-rebind",
            url: "https://example.test/stable-reset-rebind.json"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()

        let entryID = try #require(model.entryID(containing: request.id))
        let originalEntry = try #require(model.entry(for: entryID))
        let indexPath = try #require(listViewController.collectionViewForTesting.indexPathsForVisibleItems.first)
        let cell = try #require(listViewController.networkListCellForTesting(at: indexPath))
        #expect(cell.observedEntryForTesting === originalEntry)
        let frameRequestBaseline = listViewController.listTransactionDeliveryCountForTesting

        model.rebuildEntriesForTesting()
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: frameRequestBaseline
        ))
        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()

        let rebuiltEntry = try #require(model.entry(for: entryID))
        #expect(rebuiltEntry !== originalEntry)
        #expect(cell.observedEntryForTesting === rebuiltEntry)
    }

    @Test
    func staleVisibleListCellCannotSelectARebuiltSameIDEntry() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "stale-list-entry",
            url: "https://example.test/stale-list-entry.json"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()
        let indexPath = try #require(
            listViewController.collectionViewForTesting.indexPathsForVisibleItems.first
        )
        let cell = try #require(listViewController.networkListCellForTesting(at: indexPath))
        let oldEntry = try #require(cell.observedEntryForTesting)
        let entryID = try #require(model.entryID(containing: request.id))

        model.rebuildEntriesForTesting()
        let rebuiltEntry = try #require(model.entry(for: entryID))
        #expect(rebuiltEntry !== oldEntry)
        #expect(cell.observedEntryForTesting === oldEntry)

        listViewController.collectionViewForTesting.selectItem(
            at: indexPath,
            animated: false,
            scrollPosition: []
        )
        #expect(
            listViewController.collectionViewForTesting.indexPathsForSelectedItems == [indexPath]
        )
        listViewController.collectionView(
            listViewController.collectionViewForTesting,
            didSelectItemAt: indexPath
        )

        #expect(model.detailSubject == nil)
        #expect(
            (listViewController.collectionViewForTesting.indexPathsForSelectedItems ?? []).isEmpty
        )
    }

    @Test
    func concreteListSnapshotBuilderAppliesExactTenThousandRowDelta() async throws {
        let context = makeContext()
        let entryCount = 10_000
        for index in 0..<entryCount {
            context.seedNetworkRequest(
                requestID: "ten-thousand-\(index)",
                url: "https://example.test/ten-thousand-\(index).json",
                resourceTypeRawValue: "Fetch",
                responseMIMEType: "application/json",
                responseStatus: 200,
                responseStatusText: "OK",
                timestamp: Double(index)
            )
        }
        let allEntryIDs = NetworkPanelModel(context: context).displayEntryIDs
        let baselineEntryIDs = Array(allEntryIDs.prefix(entryCount - 10))
        let deletedEntryIDs = Set(allEntryIDs[200..<210])
        let rotatedEntryIDs = Array(allEntryIDs[100..<5_000])
            + Array(allEntryIDs[0..<100])
            + Array(allEntryIDs[5_000..<entryCount])
        let targetEntryIDs = rotatedEntryIDs.filter { deletedEntryIDs.contains($0) == false }
        let baseline = makeNetworkListSnapshotBaseline(
            entryIDs: baselineEntryIDs,
            version: NetworkPanelListVersion(revision: 11, entryIdentityGeneration: 0),
            generation: 4
        )
        let input = makeNetworkListSnapshotBuildInput(
            baseline: baseline,
            target: NetworkPanelListProjection(
                version: NetworkPanelListVersion(revision: 12, entryIdentityGeneration: 0),
                content: .entries(targetEntryIDs)
            )
        )

        let artifact = try await NetworkListSnapshotBuilder().build(input)

        #expect(artifact.snapshot.itemIdentifiers == targetEntryIDs)
        #expect(
            artifact.makeSubmittedBaseline(generation: 5).entryIDs
                == targetEntryIDs
        )
        #expect(artifact.changeCounts.inserted == 10)
        #expect(artifact.changeCounts.deleted == 10)
        #expect(artifact.changeCounts.moved > 0)
        #expect(artifact.changeCounts.reconfigured == 0)
    }

    @Test
    func concreteListSnapshotBuilderObservesCancellationBeforeConstruction() async throws {
        let context = makeContext()
        context.seedNetworkRequest(
            requestID: "cancel-builder",
            url: "https://example.test/cancel-builder.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let target = NetworkPanelListProjection(
            version: NetworkPanelListVersion(revision: 13, entryIdentityGeneration: 0),
            content: .entries(NetworkPanelModel(context: context).displayEntryIDs)
        )
        let input = makeNetworkListSnapshotBuildInput(target: target)
        let gate = NetworkListBuilderStartGate()
        let builder = NetworkListSnapshotBuilder()
        let task = Task {
            await gate.waitForRelease()
            return try await builder.build(input)
        }

        await gate.waitUntilWaiting()
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func staleReadySnapshotNeverAppliesAfterNewerTransactionArrives() async throws {
        let context = makeContext()
        let initialRequestID = context.seedNetworkRequest(
            requestID: "applying-a",
            url: "https://example.test/applying-a.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        _ = try #require(context.network.request(for: initialRequestID))
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let applyCompletionScheduler = ManualNetworkListSnapshotApplyCompletionScheduler()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder,
            snapshotApplyCompletionScheduler: applyCompletionScheduler
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(1)
        #expect(listViewController.snapshotApplyCountForTesting == 1)

        var transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "ready-b",
            url: "https://example.test/ready-b.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        try #require(frameScheduler.hasScheduledFrame)

        transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "latest-c",
            url: "https://example.test/latest-c.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))

        applyCompletionScheduler.runNextCompletion()
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        #expect(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        #expect(listViewController.snapshotApplyCountForTesting == 1)

        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        try #require(frameScheduler.hasScheduledFrame)

        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(2)

        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)

        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)
        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(applyCompletionScheduler.pendingCompletionCount == 0)
    }

    @Test
    func listSnapshotBuildSerializesRunningWorkAndKeepsLatestReplacement() async throws {
        let context = makeContext()
        let selectedRequestID = context.seedNetworkRequest(
            requestID: "selected-request",
            url: "https://example.test/selected.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let selectedRequest = try #require(context.network.request(for: selectedRequestID))
        model.selectRequest(selectedRequest)
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [selectedRequest.id])
        let snapshotApplyBaseline = listViewController.snapshotApplyCountForTesting
        let projectionFlushBaseline = listViewController.listProjectionFlushCountForTesting
        let scheduledFrameBaseline = frameScheduler.scheduledFrameCount

        var transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "first-replacement",
            url: "https://example.test/first.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)

        transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "superseded-replacement",
            url: "https://example.test/superseded.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()

        transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        context.seedNetworkRequest(
            requestID: "latest-replacement",
            url: "https://example.test/latest.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 3
        )
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        frameScheduler.fireScheduledFrame()

        var buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 2)
        #expect(buildStatistics.activeBuildCount == 1)
        #expect(buildStatistics.maximumActiveBuildCount == 1)

        await snapshotBuilder.releaseBuild(2)
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 3)
        #expect(buildStatistics.activeBuildCount == 1)
        #expect(buildStatistics.maximumActiveBuildCount == 1)

        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(frameScheduler.scheduledFrameCount == scheduledFrameBaseline + 4)
        #expect(frameScheduler.hasScheduledFrame)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)

        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        let finalEntryIDs = model.displayEntryIDs
        #expect(listViewController.displayedEntryIDsForTesting == finalEntryIDs)
        #expect(finalEntryIDs.count == 4)
        #expect(listViewController.listProjectionFlushCountForTesting == projectionFlushBaseline + 3)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline + 1)
        #expect(model.selectedRequest === selectedRequest)
        let selectedEntryID = try #require(model.selectedEntryID)
        #expect(
            listViewController.collectionViewForTesting.indexPathsForSelectedItems
                == [IndexPath(
                    item: try #require(finalEntryIDs.firstIndex(of: selectedEntryID)),
                    section: 0
                )]
        )
    }

    @Test
    func visibleListContentUpdateSkipsSnapshotAndRendersObservedCell() async throws {
        let context = makeContext()
        let request = try #require(await applyRequestWithoutResponse(
            to: context,
            requestID: "content-update",
            url: "https://example.test/content-update"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        listViewController.collectionViewForTesting.layoutIfNeeded()
        let cell = try #require(listViewController.networkListCellForTesting(
            at: IndexPath(item: 0, section: 0)
        ))
        let entryObservation = try #require(cell.entryObservationForTesting)
        let renderedFileType = await entryObservation.values {
            cell.fileTypeLabelForTesting
        }
        defer { renderedFileType.cancel() }
        let snapshotApplyBaseline = listViewController.snapshotApplyCountForTesting
        let transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting

        await applyResponseReceived(
            to: context,
            requestID: "content-update",
            url: request.url,
            responseHeaders: ["content-type": "text/css"],
            responseMimeType: "text/css",
            timestamp: 4
        )

        #expect(await renderedFileType.waitUntilValue("css"))
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyBaseline)
        #expect(
            listViewController.listTransactionDeliveryCountForTesting
                == transactionDeliveryBaseline
        )
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func visibleListAppliesDescriptorResetThroughListTransactions() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        model.setResourceFilter(.media, enabled: true)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        let evaluationCountBeforeUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeUpdate = listViewController.snapshotApplyCountForTesting
        let transactionDeliveryCountBeforeUpdate = listViewController.listTransactionDeliveryCountForTesting

        model.setSearchText("does-not-match")
        let didRenderReset = await waitUntilListShows(
            [],
            in: listViewController,
            afterTransactionDeliveryCount: transactionDeliveryCountBeforeUpdate
        )

        #expect(didRenderReset)
        #expect(model.displayRequestIDs.isEmpty)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeUpdate + 1)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeUpdate + 1)
    }

    @Test
    func hiddenListDefersSnapshotEvaluationUntilAppearingAgain() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let transactionDeliveryCountBeforeHiddenUpdate = listViewController
            .listTransactionDeliveryCountForTesting

        listViewController.suspendRenderingForTesting()
        model.setSearchText("does-not-match")
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryCountBeforeHiddenUpdate
        ))

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)

        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
    }

    @Test
    func repeatedHideShowBoundsRetiredSnapshotBuildsAndAppliesLatestRevision() async throws {
        let context = makeContext()
        let firstRequestID = context.seedNetworkRequest(
            requestID: "first",
            url: "https://example.test/first.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let firstRequest = try #require(context.network.request(for: firstRequestID))
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [firstRequest.id])
        var transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        let secondRequestID = context.seedNetworkRequest(
            requestID: "second",
            url: "https://example.test/second.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        let secondRequest = try #require(context.network.request(for: secondRequestID))
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        #expect(listViewController.hasActiveListSnapshotBuildForTesting)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasActiveListSnapshotBuildForTesting == false)
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        await snapshotBuilder.waitUntilCancellationObservedCount(1)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        var statistics = await snapshotBuilder.statistics()
        #expect(statistics.startedBuildCount == 2)
        await snapshotBuilder.releaseBuild(2)
        await snapshotBuilder.waitUntilCancelledBuildCount(1)
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedRequestIDsForTesting == [secondRequest.id, firstRequest.id])
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.activeBuildCount == 0)
        #expect(statistics.cancellationObservedCount == 1)
        #expect(statistics.cancelledBuildCount == 1)
        #expect(statistics.finishedBuildIDs.contains(3))
        #expect(statistics.maximumActiveBuildCount == 1)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)

        transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        let thirdRequestID = context.seedNetworkRequest(
            requestID: "third",
            url: "https://example.test/third.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 2
        )
        let thirdRequest = try #require(context.network.request(for: thirdRequestID))
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(4)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        #expect(frameScheduler.hasScheduledFrame == false)
        await snapshotBuilder.waitUntilCancellationObservedCount(2)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.startedBuildCount == 4)

        await snapshotBuilder.releaseBuild(4)
        await snapshotBuilder.waitUntilCancelledBuildCount(2)
        await snapshotBuilder.waitUntilStartedBuildCount(5)
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        await snapshotBuilder.releaseBuild(5)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(
            listViewController.displayedRequestIDsForTesting
                == [thirdRequest.id, secondRequest.id, firstRequest.id]
        )

        transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        let fourthRequestID = context.seedNetworkRequest(
            requestID: "fourth",
            url: "https://example.test/fourth.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 3
        )
        let fourthRequest = try #require(context.network.request(for: fourthRequestID))
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(6)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        #expect(frameScheduler.hasScheduledFrame == false)
        await snapshotBuilder.waitUntilCancellationObservedCount(3)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting)
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.startedBuildCount == 6)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)

        await snapshotBuilder.releaseBuild(6)
        await snapshotBuilder.waitUntilCancelledBuildCount(3)
        await snapshotBuilder.waitUntilStartedBuildCount(7)
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 1)
        await snapshotBuilder.releaseBuild(7)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(
            listViewController.displayedRequestIDsForTesting
                == [fourthRequest.id, thirdRequest.id, secondRequest.id, firstRequest.id]
        )
        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.activeBuildCount == 0)
        #expect(statistics.maximumActiveBuildCount == 1)
        #expect(statistics.cancellationObservedCount == 3)
        #expect(statistics.cancelledBuildCount == 3)
        #expect(statistics.finishedBuildIDs.isSuperset(of: [3, 5, 7]))
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)

        await listViewController.waitForTrackedListSnapshotBuildTasksForTesting()
        statistics = await snapshotBuilder.statistics()
        #expect(statistics.activeBuildCount == 0)
        #expect(statistics.cancelledBuildCount == 3)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)
        #expect(statistics.startedBuildPriorities.allSatisfy { $0 == .userInitiated })
    }

    @Test
    func hiddenListReconcilesAfterInFlightApplyCompletesWhileHidden() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let applyCompletionScheduler = ManualNetworkListSnapshotApplyCompletionScheduler()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder,
            snapshotApplyCompletionScheduler: applyCompletionScheduler
        )
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(1)
        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        var transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        model.setSearchText("does-not-match")
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(2)

        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        #expect(frameScheduler.hasScheduledFrame == false)

        transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        model.setSearchText("")
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        applyCompletionScheduler.runNextCompletion()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting.isEmpty)
        #expect(frameScheduler.hasScheduledFrame == false)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(3)
        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate + 1)
        #expect(applyCompletionScheduler.pendingCompletionCount == 0)
    }

    @Test
    func listSnapshotStateSurvivesCompactToRegularReparentDuringDelayedApply() async throws {
        let context = makeContext()
        let firstRequestID = context.seedNetworkRequest(
            requestID: "reparent-first",
            url: "https://example.test/reparent-first.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 0
        )
        let model = NetworkPanelModel(context: context)
        let firstRequest = try #require(context.network.request(for: firstRequestID))
        model.selectRequest(firstRequest)
        let selectedSubject = try #require(model.detailSubject)
        let frameScheduler = ManualNetworkFrameScheduler()
        let snapshotBuilder = BarrierNetworkListSnapshotBuilderFactory()
        let applyCompletionScheduler = ManualNetworkListSnapshotApplyCompletionScheduler()
        let listViewController = NetworkListViewController(
            model: model,
            listFrameScheduler: frameScheduler,
            listSnapshotBuilderFactory: snapshotBuilder,
            snapshotApplyCompletionScheduler: applyCompletionScheduler
        )
        let detailViewController = NetworkDetailViewController(model: model)
        let compactViewController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(compactViewController, makeVisible: false)
        defer { window.isHidden = true }
        listViewController.resumeRenderingForTesting()

        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(1)
        await snapshotBuilder.releaseBuild(1)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(1)
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        #expect(applyCompletionScheduler.pendingCompletionCount == 1)

        let transactionDeliveryBaseline = listViewController
            .listTransactionDeliveryCountForTesting
        let secondRequestID = context.seedNetworkRequest(
            requestID: "reparent-second",
            url: "https://example.test/reparent-second.json",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: 1
        )
        let secondRequest = try #require(context.network.request(for: secondRequestID))
        #expect(await listViewController.waitForListTransactionDeliveryForTesting(
            after: transactionDeliveryBaseline
        ))
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(2)
        await snapshotBuilder.releaseBuild(2)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)
        #expect(listViewController.snapshotApplyCountForTesting == 1)
        try #require(frameScheduler.hasScheduledFrame)

        listViewController.suspendRenderingForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        #expect(frameScheduler.hasScheduledFrame == false)
        #expect(applyCompletionScheduler.pendingCompletionCount == 1)

        let splitViewController = NetworkSplitViewController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        window.rootViewController = splitViewController
        splitViewController.loadViewIfNeeded()
        splitViewController.view.frame = window.bounds
        window.layoutIfNeeded()
        let primaryNavigationController = try #require(
            splitViewController.viewController(for: .primary) as? UINavigationController
        )
        #expect(primaryNavigationController.viewControllers.first === listViewController)
        #expect(compactViewController.viewControllers.contains(where: { $0 === listViewController }) == false)

        listViewController.resumeRenderingForTesting()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await snapshotBuilder.waitUntilStartedBuildCount(3)
        await snapshotBuilder.releaseBuild(3)
        await listViewController.waitForListSnapshotBuildIdleForTesting()
        #expect(listViewController.hasPendingSnapshotUpdateForTesting)
        #expect(listViewController.snapshotApplyCountForTesting == 1)

        applyCompletionScheduler.runNextCompletion()
        try #require(frameScheduler.hasScheduledFrame)
        frameScheduler.fireScheduledFrame()
        await applyCompletionScheduler.waitUntilScheduledCompletionCount(2)
        #expect(listViewController.snapshotApplyCountForTesting == 2)
        #expect(
            listViewController.displayedRequestIDsForTesting
                == [secondRequest.id, firstRequest.id]
        )

        applyCompletionScheduler.runNextCompletion()
        await listViewController.waitForSnapshotPipelineQuiescenceForTesting()

        #expect(listViewController.displayedEntryIDsForTesting == model.displayEntryIDs)
        #expect(model.detailSubject?.hasSameIdentity(as: selectedSubject) == true)
        let selectedEntryID = try #require(model.selectedEntryID)
        #expect(
            listViewController.collectionViewForTesting.indexPathsForSelectedItems
                == [IndexPath(
                    item: try #require(
                        model.displayEntryIDs.firstIndex(of: selectedEntryID)
                    ),
                    section: 0
                )]
        )
        #expect(applyCompletionScheduler.pendingCompletionCount == 0)
        #expect(listViewController.hasPendingSnapshotUpdateForTesting == false)
        #expect(listViewController.hasActiveListSnapshotBuildForTesting == false)
        #expect(listViewController.hasDeferredListSnapshotBuildForTesting == false)
        #expect(listViewController.trackedListSnapshotBuildTaskCountForTesting == 0)
        let buildStatistics = await snapshotBuilder.statistics()
        #expect(buildStatistics.startedBuildCount == 3)
        #expect(buildStatistics.activeBuildCount == 0)
        #expect(buildStatistics.maximumActiveBuildCount == 1)
    }

    @Test
    func hiddenFilteredListSkipsSnapshotReloadWhenRowsRemainVisible() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        model.setResourceFilter(.media, enabled: true)
        let listViewController = NetworkListViewController(model: model)
        listViewController.loadViewIfNeeded()
        listViewController.resumeRenderingForTesting()
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        let evaluationCountBeforeHiddenUpdate = listViewController.displayRequestIDsEvaluationCountForTesting
        let snapshotApplyCountBeforeHiddenUpdate = listViewController.snapshotApplyCountForTesting

        listViewController.suspendRenderingForTesting()
        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "image/png"],
            responseMimeType: "image/png",
            timestamp: 4
        )

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        listViewController.resumeRenderingForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])

        await listViewController.flushPendingSnapshotUpdateForTesting()

        #expect(listViewController.displayRequestIDsEvaluationCountForTesting == evaluationCountBeforeHiddenUpdate)
        #expect(listViewController.snapshotApplyCountForTesting == snapshotApplyCountBeforeHiddenUpdate)
        #expect(listViewController.displayedRequestIDsForTesting == [request.id])
    }

    @Test
    func networkListCellSuspendsBoundRenderingUntilReactivated() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "1",
            url: "https://media.example.com/clip.mp4",
            responseHeaders: ["content-type": "video/mp4"],
            responseMimeType: "video/mp4"
        ))
        let model = NetworkPanelModel(context: context)
        let entry = try #require(model.displayEntries.first)
        let cell = NetworkListCell(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        cell.bind(entry: entry, renderingActive: true)
        #expect(cell.fileTypeLabelForTesting == "mp4")
        #expect(cell.hasActiveRequestObservationForTesting)
        let content = try #require(
            cell.contentConfiguration as? UIListContentConfiguration
        )
        #expect(content.textProperties.adjustsFontForContentSizeCategory)

        cell.setRenderingActive(false)
        #expect(cell.hasActiveRequestObservationForTesting == false)

        await applyResponseReceived(
            to: context,
            requestID: "1",
            url: request.url,
            responseHeaders: ["content-type": "text/css"],
            responseMimeType: "text/css",
            timestamp: 4
        )

        #expect(cell.fileTypeLabelForTesting == "mp4")

        cell.setRenderingActive(true)

        #expect(cell.hasActiveRequestObservationForTesting)
        #expect(cell.fileTypeLabelForTesting == "css")
    }

    @Test
    func visibleGroupedListKeepsEntryIdentityWhenMemberArrives() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("grouped-loader")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first",
            url: "https://example.com/first.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let model = NetworkPanelModel(context: context)
        let stableEntryID = try #require(model.entryID(containing: firstRequest.id))
        let stableEntry = try #require(model.entry(for: stableEntryID))
        let listViewController = NetworkListViewController(model: model)
        let window = showInWindow(listViewController, makeVisible: true)
        defer { window.isHidden = true }
        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedEntryIDsForTesting == [stableEntryID])

        let transactionDeliveryBaseline = listViewController.listTransactionDeliveryCountForTesting
        let entryObservation = withPortableContinuousObservation { _ in
            _ = stableEntry.requests
        }
        let groupedRequestIDs = await entryObservation.values {
            stableEntry.requests.map(\.id)
        }
        defer {
            groupedRequestIDs.cancel()
            entryObservation.cancel()
        }
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second",
            url: "https://example.com/second.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let didUpdateStableEntry = await groupedRequestIDs.waitUntilValue([
            firstRequest.id,
            secondRequest.id,
        ])

        #expect(didUpdateStableEntry)
        #expect(listViewController.listTransactionDeliveryCountForTesting == transactionDeliveryBaseline)
        #expect(listViewController.displayedEntryIDsForTesting == [stableEntryID])
        #expect(model.entry(for: stableEntryID) === stableEntry)
        #expect(stableEntry.requests.map(\.id) == [firstRequest.id, secondRequest.id])
    }

    @Test
    func filteredOutSelectionRendersLaterMembersFromSameGroup() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("filtered-group")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "first",
            url: "https://example.com/first.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: firstRequest, in: model)
        let viewController = NetworkDetailViewController(model: model)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        #expect(await waitUntilRendered(in: viewController) {
            viewController.headersTextViewForTesting.renderedTextForTesting.contains("first.js")
        })

        model.setSearchText("does-not-match")
        #expect(model.displayEntryIDs.isEmpty)

        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "second",
            url: "https://example.com/second.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))

        #expect(await waitUntilRendered(in: viewController) {
            let text = viewController.headersTextViewForTesting.renderedTextForTesting
            return text.contains("first.js") && text.contains("second.js")
        })
        #expect(model.displayEntryIDs.isEmpty)
        #expect(model.selectedEntryRequests.map(\.id) == [firstRequest.id, secondRequest.id])
    }

    @Test
    func listControllerDeallocatesWhileListTransactionTaskIsActive() async throws {
        let model = NetworkPanelModel(context: makeContext())
        let deinitProbe = UITestDeinitProbe()
        weak var weakViewController: NetworkListViewController?

        do {
            let viewController = NetworkListViewController(model: model)
            viewController.loadViewIfNeeded()
            viewController.setDeinitHandlerForTesting {
                deinitProbe.signalDeinit()
            }
            weakViewController = viewController
        }

        let didDeallocate = await deinitProbe.wait()
        #expect(didDeallocate)
        #expect(weakViewController == nil)
    }
}
}
#endif
