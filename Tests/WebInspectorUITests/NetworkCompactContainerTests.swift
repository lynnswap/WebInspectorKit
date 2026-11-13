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
struct NetworkCompactContainerTests: NetworkDetailTestSupport {
    @Test
    func regularSplitKeepsPrimarySecondaryLayout() throws {
        let model = NetworkPanelModel(context: makeContext())
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let splitViewController = NetworkSplitViewController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )

        splitViewController.loadViewIfNeeded()

        let listNavigationController = try #require(
            splitViewController.viewController(for: .primary) as? UINavigationController
        )
        let detailNavigationController = try #require(
            splitViewController.viewController(for: .secondary) as? UINavigationController
        )
        #expect(listNavigationController.viewControllers.first === listViewController)
        #expect(detailNavigationController.viewControllers.first === detailViewController)
        if #available(iOS 26.0, *) {
            #expect(splitViewController.viewController(for: .inspector) == nil)
        }
        #expect(splitViewController.preferredDisplayMode == .oneBesideSecondary)
        #expect(splitViewController.preferredSplitBehavior == .tile)
        #expect(splitViewController.presentsWithGesture == false)
    }

    @Test
    func compactContainerPushesAndPopsDetailFromSelection() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(
            navigationController,
            makeVisible: true,
            useUIKitVisibility: true
        )
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        withUIKitAnimationsDisabled {
            model.selectRequest(nil)
        }
        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }

    @Test
    func compactContainerCanPushSameRequestAfterBackNavigation() async throws {
        let context = makeContext()
        _ = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        await listViewController.flushPendingSnapshotUpdateForTesting()
        #expect(listViewController.displayedRequestIDsForTesting.count == 1)
        let entry = try #require(model.displayEntries.first)

        model.selectEntry(entry)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)

        let poppedViewController = withUIKitAnimationsDisabled {
            navigationController.popDetailFromUserNavigationForTesting()
        }
        #expect(poppedViewController === detailViewController)
        let didReturnToList = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && (listViewController.collectionViewForTesting.indexPathsForSelectedItems ?? []).isEmpty
        }
        #expect(didReturnToList)

        model.selectEntry(entry)
        let didPushAgain = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPushAgain)
    }

    @Test
    func compactContainerDoesNotReplayDeferredDetailAfterUserPop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()
        #expect(navigationController.viewControllers == [listViewController, detailViewController])

        let poppedViewController = navigationController.popDetailFromUserNavigationForTesting {
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.selectedRequest == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactContainerDoesNotRepushDetailWhenUserPopOvertakesPushCompletion() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()
        #expect(navigationController.viewControllers == [listViewController, detailViewController])

        let poppedViewController =
            navigationController.popDetailWhilePushTransitionIsStillTrackedForTesting()
        navigationController.syncStackForTesting()

        #expect(poppedViewController === detailViewController)
        #expect(model.selectedRequest == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactContainerClearsSelectionAfterUntrackedNonanimatedPop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "untracked-pop",
                url: "https://example.com/untracked.js"
            )
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController
            .popDetailWithoutTrackedTransitionForTesting()

        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactContainerKeepsReplacementAfterUntrackedNonanimatedPop() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "untracked-pop-first",
                url: "https://example.com/first.js"
            )
        )
        let secondRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "untracked-pop-second",
                url: "https://example.com/second.js"
            )
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        let originalIntentID = try #require(model.detailSubject?.intentID)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController
            .popDetailWithoutTrackedTransitionForTesting {
            model.selectRequest(secondRequest)
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject?.intentID != originalIntentID)
        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactContainerKeepsReplacementAfterCancelledUntrackedNonanimatedPop() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "untracked-cancel-first",
                url: "https://example.com/first.js"
            )
        )
        let secondRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "untracked-cancel-second",
                url: "https://example.com/second.js"
            )
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        navigationController.syncStackForTesting()

        navigationController.cancelDetailPopWithoutTrackedTransitionForTesting {
            model.selectRequest(secondRequest)
        }

        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])

        let poppedViewController = navigationController
            .popDetailWithoutTrackedTransitionForTesting()
        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactContainerKeepsDetailAfterCancelledUserPop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        navigationController.syncStackForTesting()

        navigationController.cancelDetailPopFromUserNavigationForTesting {
            navigationController.syncStackForTesting()
        }

        #expect(model.selectedRequest === request)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactContainerKeepsReplacementAfterCancelledPopOvertakesPush() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "cancel-first",
                url: "https://example.com/first.js"
            )
        )
        let secondRequest = try #require(
            await applyRequest(
                to: context,
                requestID: "cancel-second",
                url: "https://example.com/second.js"
            )
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        let originalIntentID = try #require(model.detailSubject?.intentID)
        navigationController.syncStackForTesting()

        navigationController.cancelDetailPopWhilePushTransitionIsStillTrackedForTesting {
            model.selectRequest(secondRequest)
            navigationController.syncStackForTesting()
        }

        #expect(model.detailSubject?.intentID != originalIntentID)
        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactContainerConvergesToReplacementSelectionAfterUserPop() async throws {
        let context = makeContext()
        let firstRequest = try #require(
            await applyRequest(to: context, requestID: "1", url: "https://example.com/first.js")
        )
        let secondRequest = try #require(
            await applyRequest(to: context, requestID: "2", url: "https://example.com/second.js")
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        let originalIntentID = try #require(model.detailSubject?.intentID)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController
            .popDetailWhilePushTransitionIsStillTrackedForTesting {
            model.selectRequest(nil)
            model.selectRequest(secondRequest)
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject?.intentID != originalIntentID)
        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactBackDoesNotClearTheSameRequestExplicitlyReselectedDuringThePop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "compact-reselect",
                url: "https://example.com/reselect.js"
            )
        )
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        let originalIntentID = try #require(model.detailSubject?.intentID)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController
            .popDetailWhilePushTransitionIsStillTrackedForTesting {
            model.selectRequest(request)
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject?.intentID != originalIntentID)
        #expect(model.detailSubject?.activeRequest === request)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactBackDoesNotClearTheSameEntryExplicitlyReselectedDuringThePop() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "compact-entry-reselect",
                url: "https://example.com/entry-reselect.js"
            )
        )
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.entryID(containing: request.id))
        let entry = try #require(model.entry(for: entryID))
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectEntry(entry)
        let originalIntentID = try #require(model.detailSubject?.intentID)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController
            .popDetailWhilePushTransitionIsStillTrackedForTesting {
            model.selectEntry(entry)
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject?.intentID != originalIntentID)
        #expect(model.detailSubject?.entry === entry)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactBackClearsAnAutomaticallyRegroupedRequestWithTheCapturedIntent() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "compact-regroup",
                url: "https://example.com/regroup.js"
            )
        )
        let frameID = FrameID("compact-regroup-frame")
        let nodeID = DOM.Node.ID("compact-regroup-node")
        installNavigationVisit(in: context, frameID: frameID)
        let groupedSibling = try #require(await applyGroupedRequest(
            to: context,
            requestID: "compact-regroup-sibling",
            url: "https://example.com/sibling.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 10
        ))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(request)
        let intentID = try #require(model.detailSubject?.intentID)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController
            .popDetailWhilePushTransitionIsStillTrackedForTesting {
            request.applyRequestWillBeSent(
                request: Network.Request(
                    id: request.proxyID,
                    url: request.url,
                    method: request.method,
                    origin: Network.Request.Origin(
                        frameID: frameID,
                        loaderID: "loader",
                        targetID: "page"
                    )
                ),
                initiator: groupedSibling.initiator,
                navigationVisit: groupedSibling.navigationVisit,
                resourceType: request.resourceType,
                timestamp: 20,
                chronologySequence: 20
            )
            model.upsertRequestForTesting(request)
            #expect(model.detailSubject?.intentID == intentID)
            #expect(model.detailSubject?.entry.id == model.entryID(containing: request.id))
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.detailSubject == nil)
        #expect(navigationController.viewControllers == [listViewController])
    }

    @Test
    func compactBackPreservesReplacementRequestInTheSameEntry() async throws {
        let context = makeContext()
        let frameID = FrameID("main-frame")
        let nodeID = DOM.Node.ID("compact-replacement")
        installNavigationVisit(in: context, frameID: frameID)
        let firstRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "compact-first",
            url: "https://example.com/compact-first.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let secondRequest = try #require(await applyGroupedRequest(
            to: context,
            requestID: "compact-second",
            url: "https://example.com/compact-second.js",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        let entryID = try #require(model.entryID(containing: firstRequest.id))
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        model.selectRequest(firstRequest)
        navigationController.syncStackForTesting()

        let poppedViewController = navigationController.popDetailFromUserNavigationForTesting {
            model.selectRequest(secondRequest)
            navigationController.syncStackForTesting()
        }

        #expect(poppedViewController === detailViewController)
        #expect(model.selection == .request(entryID: entryID, requestID: secondRequest.id))
        #expect(model.selectedRequest === secondRequest)
        #expect(navigationController.viewControllers == [listViewController, detailViewController])
    }

    @Test
    func compactContainerReleasesDetailMediaPreviewResourcesWhenDetailIsRemoved() async throws {
        let context = makeContext()
        let request = try #require(
            await applyRequest(
                to: context,
                requestID: "1",
                url: "https://media.example.com/download.php",
                responseHeaders: ["content-type": "video/mp4"],
                responseMimeType: "video/mp4"
            )
        )
        applyResponseBody(to: context, request: request, body: "not a real movie", base64Encoded: false)
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        detailViewController.setModeForTesting(.preview)
        let playerFactory = MoviePreviewPlayerFactorySpy()
        detailViewController.bodyViewControllerForTesting.setMoviePreviewPlayerFactoryForTesting(
            playerFactory.makePlayer
        )
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)
        await waitUntilMediaPreviewPrepared(in: detailViewController)

        let didRenderMediaPreview = await waitUntilRendered(in: detailViewController) {
            detailViewController.bodyViewControllerForTesting.mediaPlayerURLForTesting?.pathExtension == "mp4"
        }
        #expect(didRenderMediaPreview)
        let temporaryFileURL = try #require(detailViewController.bodyViewControllerForTesting.mediaPlayerURLForTesting)
        #expect(playerFactory.players.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryFileURL.path))

        model.selectRequest(nil)

        let didReturnToListAndReleasePreview = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
                && model.selectedRequest == nil
                && detailViewController.bodyViewControllerForTesting.mediaPlayerURLForTesting == nil
                && FileManager.default.fileExists(atPath: temporaryFileURL.path) == false
        }
        #expect(didReturnToListAndReleasePreview)
        #expect(playerFactory.players.count == 1)
    }

    @Test
    func compactContainerPopsDetailWhenSelectedRequestDisappears() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(to: context, requestID: "1", url: "https://example.com/app.js"))
        let model = NetworkPanelModel(context: context)
        let listViewController = NetworkListViewController(model: model)
        let detailViewController = NetworkDetailViewController(model: model)
        let navigationController = NetworkCompactNavigationController(
            model: model,
            listViewController: listViewController,
            detailViewController: detailViewController
        )
        let window = showInWindow(navigationController, makeVisible: true)
        defer { window.isHidden = true }

        model.selectRequest(request)
        let didPush = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers.last === detailViewController
        }
        #expect(didPush)
        await waitForNavigationTransitionToFinish(in: navigationController)
        let rawTransactionBaseline = model.rawTransactionDeliveryCountForTesting

        withUIKitAnimationsDisabled {
            context.clearNetworkRequests()
        }
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: rawTransactionBaseline))
        #expect(model.selectedRequestID == nil)

        let didPop = await waitUntilNavigationStackSynced(in: navigationController) {
            navigationController.viewControllers == [listViewController]
        }
        #expect(didPop)
    }
}
}
#endif
