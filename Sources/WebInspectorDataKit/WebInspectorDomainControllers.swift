import Foundation
import WebInspectorProxyKit

public struct WebInspectorMutationOptions: Sendable, Hashable {
    public static let automatic = WebInspectorMutationOptions(
        undo: .automatic,
        staleModel: .fail
    )

    public var undo: WebInspectorUndoPolicy
    public var staleModel: WebInspectorStaleModelPolicy

    public init(
        undo: WebInspectorUndoPolicy = .automatic,
        staleModel: WebInspectorStaleModelPolicy = .fail
    ) {
        self.undo = undo
        self.staleModel = staleModel
    }
}

public enum WebInspectorUndoPolicy: Sendable, Hashable {
    case automatic
    case disabled
}

public enum WebInspectorStaleModelPolicy: Sendable, Hashable {
    case fail
}

public enum DOMRevealPolicy: Sendable, Hashable {
    case none
    case selectOnly
    case selectAndScroll
}

public struct DOMMutationResult: Sendable, Hashable {
    public var requestedNodeIDs: [DOMNode.ID]
    public var acceptedNodeIDs: [DOMNode.ID]

    public init(requestedNodeIDs: [DOMNode.ID], acceptedNodeIDs: [DOMNode.ID]) {
        self.requestedNodeIDs = requestedNodeIDs
        self.acceptedNodeIDs = acceptedNodeIDs
    }
}

public final class DOMModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func treeController(isolation: isolated (any Actor) = #isolation) -> DOMTreeController {
        context.rootTreeController(isolation: isolation)
    }

    public func requestChildren(
        of nodeID: DOMNode.ID,
        depth: Int = 1,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.requestChildren(for: nodeID, depth: depth, isolation: isolation)
    }

    public func select(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy = .selectAndScroll,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        try context.selectNode(nodeID, reveal: reveal, isolation: isolation)
    }

    public func setAttribute(
        _ name: String,
        value: String,
        on nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setDOMAttribute(name, value: value, on: nodeID, options: options, isolation: isolation)
    }

    public func setOuterHTML(
        _ html: String,
        of nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setDOMOuterHTML(html, of: nodeID, options: options, isolation: isolation)
    }

    public func remove(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> DOMMutationResult {
        try await context.removeDOMNodes(nodeIDs, options: options, isolation: isolation)
    }

    public func highlight(
        _ nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.highlightNode(for: nodeID, isolation: isolation)
    }

    public func hideHighlight(isolation: isolated (any Actor) = #isolation) async throws {
        try await context.hideHighlight(isolation: isolation)
    }

    public func setInspectMode(
        enabled: Bool,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setElementPickerEnabled(enabled, isolation: isolation)
    }
}

public final class CSSModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func styles(
        for nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) throws -> CSSStyles {
        try context.styles(for: nodeID, isolation: isolation)
    }

    public func refreshStyles(
        for nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        _ = try context.refreshStyles(for: nodeID, isolation: isolation)
    }

    public func setStyleHydrationActive(
        _ active: Bool,
        isolation: isolated (any Actor) = #isolation
    ) {
        context.setStyleHydrationActive(active, isolation: isolation)
    }

    public func setProperty(
        _ propertyID: CSS.Property.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSProperty(propertyID, enabled: enabled, options: options, isolation: isolation)
    }

    @discardableResult
    public func requestSetProperty(
        _ propertyID: CSS.Property.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) -> Bool {
        context.requestSetCSSProperty(propertyID, enabled: enabled, options: options, isolation: isolation)
    }

    public func setDeclarationText(
        _ text: String,
        for propertyID: CSS.Property.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        _ = text
        _ = propertyID
        _ = options
        throw WebInspectorProxyError.commandFailed(
            domain: "CSS",
            method: "setStyleText",
            message: "CSS declaration text editing is not implemented by WebInspectorDataKit yet."
        )
    }

    public func setRuleSelector(
        _ selector: String,
        for ruleID: CSS.Rule.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSRuleSelector(selector, for: ruleID, options: options, isolation: isolation)
    }

    public func setStyleSheetText(
        _ text: String,
        for styleSheetID: CSS.StyleSheet.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSStyleSheetText(text, for: styleSheetID, options: options, isolation: isolation)
    }
}

public final class PageModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func reload(
        ignoringCache: Bool = false,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.reloadPage(ignoringCache: ignoringCache, isolation: isolation)
    }
}

public final class RuntimeModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func evaluate(
        _ expression: String,
        in runtimeContext: RuntimeContext? = nil,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> RuntimeEvaluation {
        try await context.evaluate(expression, in: runtimeContext, isolation: isolation)
    }
}

public final class NetworkModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func fetchedResults(
        for descriptor: WebInspectorFetchDescriptor<NetworkRequest> = .init(),
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<NetworkRequest> {
        context.fetchedResults(for: descriptor, sectionBy: sectionBy, isolation: isolation)
    }

    public func fetchedResultsController(
        for descriptor: WebInspectorFetchDescriptor<NetworkRequest> = .init(),
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<NetworkRequest> {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: sectionBy, isolation: isolation)
        )
    }

    public func clearRequests(isolation: isolated (any Actor) = #isolation) {
        context.clearNetworkRequests(isolation: isolation)
    }
}

public final class ConsoleModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func fetchedResults(
        for descriptor: WebInspectorFetchDescriptor<ConsoleMessage> = .init(),
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<ConsoleMessage> {
        context.fetchedResults(for: descriptor, isolation: isolation)
    }

    public func fetchedResultsController(
        for descriptor: WebInspectorFetchDescriptor<ConsoleMessage> = .init(),
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<ConsoleMessage> {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, isolation: isolation)
        )
    }
}

public final class WebInspectorEditHistory {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    public func undo(isolation: isolated (any Actor) = #isolation) async throws {
        try await context.undoDOMChange(isolation: isolation)
    }

    public func redo(isolation: isolated (any Actor) = #isolation) async throws {
        try await context.redoDOMChange(isolation: isolation)
    }
}

public extension WebInspectorContext {
    var dom: DOMModelController {
        DOMModelController(context: self)
    }

    var css: CSSModelController {
        CSSModelController(context: self)
    }

    var network: NetworkModelController {
        NetworkModelController(context: self)
    }

    var runtime: RuntimeModelController {
        RuntimeModelController(context: self)
    }

    var console: ConsoleModelController {
        ConsoleModelController(context: self)
    }

    var page: PageModelController {
        PageModelController(context: self)
    }

    var editHistory: WebInspectorEditHistory {
        WebInspectorEditHistory(context: self)
    }
}
