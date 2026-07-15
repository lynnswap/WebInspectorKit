#if canImport(UIKit)
import ObservationBridge
import Testing
import UIKit
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorTestSupport
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
@Suite(.serialized)
struct DOMContainerTests {
    @Test
    func elementViewStartsEmptyWithoutAContextSelection() async throws {
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionView.numberOfSections == 0)
        #expect(fixture.model.selectedNodeID == nil)
        await fixture.close()
    }

    @Test
    func elementViewKeepsPlaceholderForASelectedNodeWithoutLoadedStyles()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)
        viewController.loadViewIfNeeded()

        fixture.model.selectNode(
            try fixture.nodeID(named: "body"),
            reveal: .selectOnly
        )

        #expect(await waitUntil {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.numberOfSections == 0
        })
        await fixture.close()
    }

    @Test
    func removingTheSelectedNodeClearsTheSharedPanelSelection()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)
        viewController.loadViewIfNeeded()
        let bodyID = try fixture.nodeID(named: "body")
        fixture.model.selectNode(bodyID, reveal: .selectOnly)
        #expect(fixture.model.selectedNodeID == bodyID)

        try await fixture.runtime.emitDOMChildNodeRemoved(
            parentID: "document",
            nodeID: "body"
        )

        #expect(await waitUntil {
            fixture.model.selectedNodeID == nil
                && viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.numberOfSections == 0
        })
        await fixture.close()
    }

    @Test
    func panelElementPickerActivatesAndCancelsThroughTheProductionFeed()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let observation = withPortableContinuousObservation { _ in
            _ = fixture.model.isPickingElement
        }
        let pickerStates = await observation.values {
            fixture.model.isPickingElement
        }
        defer {
            pickerStates.cancel()
            observation.cancel()
        }

        fixture.model.toggleElementPicker()
        #expect(await pickerStates.waitUntil { $0 } != nil)

        fixture.model.cancelElementPicker()
        #expect(await pickerStates.waitUntil { !$0 } != nil)
        await fixture.close()
    }

    @Test
    func elementViewCanDisableBackgroundDrawing() async throws {
        guard #available(iOS 26.0, *) else {
            return
        }
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.collectionView.backgroundColor == .clear)
        await fixture.close()
    }

    @Test
    func elementStyleSectionHeaderTextFormatsRuleOriginText() {
        let location = DOMElementStyleSectionHeaderText.SourceLocation(
            sourceURL: "https://styles.example/assets/result-card.css",
            line: 27,
            column: 22_164
        )
        #expect(
            DOMElementStyleSectionHeaderText.displayText(for: location)
                == "result-card.css:28:22165"
        )
        #expect(
            DOMElementStyleSectionHeaderText.fullDisplayText(for: location)
                == "https://styles.example/assets/result-card.css:28:22165"
        )
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: .init(sourceURL: "styles.css", line: 1)
        ) == "styles.css:2")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: .init(sourceURL: "styles.css", line: 0, column: 80)
        ) == "styles.css:1")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: .init(sourceURL: "styles.css", line: 0, column: 81)
        ) == "styles.css:1:82")
    }

    @Test
    func elementStylePropertyViewSendsToggleActionWithImmediateFeedback()
        async
    {
        let propertyID = CSSStyleProperty.ID("test-style:0")
        let property = CSSStyleProperty(
            id: propertyID,
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        var requestedPropertyID: CSSStyleProperty.ID?
        var requestedEnabled: Bool?
        let acceptedRequest = WebInspectorTestGate()
        propertyView.bind(property: property) { property, enabled in
            requestedPropertyID = property.id
            requestedEnabled = enabled
            acceptedRequest.open()
            return true
        }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        propertyView.tapToggleForTesting()

        #expect(propertyView.isToggleOnForTesting == false)
        await acceptedRequest.waiter.wait()
        #expect(requestedPropertyID == propertyID)
        #expect(requestedEnabled == false)

        let rejectedRequest = WebInspectorTestGate()
        propertyView.bind(property: property) { _, _ in
            rejectedRequest.open()
            return false
        }
        propertyView.tapToggleForTesting()
        await rejectedRequest.waiter.wait()
        await Task.yield()
        #expect(propertyView.isToggleOnForTesting)
    }

    @Test
    func elementStylePropertyViewIgnoresNonEditableProperties() {
        let property = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:0"),
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: false
        )
        let propertyView = DOMElementStylePropertyView()
        var requestCount = 0
        propertyView.bind(property: property) { _, _ in
            requestCount += 1
            return true
        }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        #expect(propertyView.isToggleEnabledForTesting == false)
        propertyView.tapToggleForTesting()
        #expect(requestCount == 0)
    }

    @Test
    func elementStylePropertyViewNormalizesMultilinePropertyText() {
        let property = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:0"),
            name: "background",
            value: "red",
            text: "background:\n    red;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        propertyView.bind(property: property) { _, _ in true }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        #expect(propertyView.declarationTextForTesting == "background: red;")
        #expect(propertyView.declarationTextForTesting.contains("\n") == false)
    }

    @Test
    func compactContainerInstallsNavigationActionsOnTheSharedPanelModel()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let treeViewController = DOMTreeViewController(model: fixture.model)
        let navigationController = DOMCompactNavigationController(
            rootViewController: treeViewController,
            model: fixture.model
        )

        navigationController.loadViewIfNeeded()

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(navigationController.domNavigationItemsForTesting != nil)
        #expect(navigationController.keyCommands?.isEmpty == false)
        await fixture.close()
    }

    @Test
    func splitContainerInstallsTreeAndElementColumnsFromOnePanelModel()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let treeViewController = DOMTreeViewController(model: fixture.model)
        let elementViewController = DOMElementViewController(model: fixture.model)
        let splitViewController = DOMSplitViewController(
            treeViewController: treeViewController,
            elementViewController: elementViewController,
            model: fixture.model
        )

        splitViewController.loadViewIfNeeded()

        #expect(splitViewController.domNavigationItemsForTesting != nil)
        #expect(splitViewController.keyCommands?.isEmpty == false)
        #expect(treeViewController.parent != nil)
        #expect(elementViewController.parent != nil)
        await fixture.close()
    }
}

@MainActor
private final class DOMContainerFixture {
    let runtime: WebInspectorDataKitTestRuntime
    let model: DOMPanelModel

    init() async throws {
        let runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.dom]),
                document: .init(children: [
                    .element(id: "body", name: "body")
                ])
            )
        )
        self.runtime = runtime
        model = try await DOMPanelModel.make(
            context: runtime.container.mainContext
        )
    }

    func close() async {
        await model.retire()
        await runtime.close()
    }

    func nodeID(named localName: String) throws -> DOMNode.ID {
        try #require(model.nodes.snapshot?.itemIDs.first { id in
            runtime.container.mainContext.model(for: id)?.localName == localName
        })
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func showViewInWindow(_ view: UIView) -> UIWindow {
    let viewController = UIViewController()
    view.translatesAutoresizingMaskIntoConstraints = false
    viewController.view.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: viewController.view.topAnchor),
        view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
        view.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
    ])
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = viewController
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}
#endif
