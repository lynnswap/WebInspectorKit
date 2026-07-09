import Foundation
import WebInspectorProxyKit

/// Shared options for DataKit model mutations.
public struct WebInspectorMutationOptions: Sendable, Hashable {
    /// Default mutation behavior: participate in WebKit undo history and fail
    /// on stale model references.
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

/// Controls whether a mutation participates in WebKit inspector undo history.
public enum WebInspectorUndoPolicy: Sendable, Hashable {
    case automatic
    case disabled
}

/// Controls how DataKit handles stale model references.
public enum WebInspectorStaleModelPolicy: Sendable, Hashable {
    case fail
}

/// Controls how DOM selection changes should be revealed to UI tree views.
public enum DOMRevealPolicy: Sendable, Hashable {
    case none
    case selectOnly
    case selectAndScroll
}

/// The accepted subset of a requested DOM mutation.
public struct DOMMutationResult: Sendable, Hashable {
    public var requestedNodeIDs: [DOMNode.ID]
    public var acceptedNodeIDs: [DOMNode.ID]

    public init(requestedNodeIDs: [DOMNode.ID], acceptedNodeIDs: [DOMNode.ID]) {
        self.requestedNodeIDs = requestedNodeIDs
        self.acceptedNodeIDs = acceptedNodeIDs
    }
}

/// Domain operation surface for DOM model commands.
///
/// Use this controller instead of dispatching ProxyKit DOM commands directly
/// when working with DataKit-owned DOM nodes.
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

/// Domain operation surface for CSS model commands.
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
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSProperty(propertyID, enabled: enabled, options: options, isolation: isolation)
    }

    @discardableResult
    public func requestSetProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) -> Bool {
        context.requestSetCSSProperty(propertyID, enabled: enabled, options: options, isolation: isolation)
    }

    public func setDeclarationText(
        _ text: String,
        for propertyID: CSSStyleProperty.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSDeclarationText(text, for: propertyID, options: options, isolation: isolation)
    }

    public func setRuleSelector(
        _ selector: String,
        for ruleID: CSSStyleRule.ID,
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

/// Domain operation surface for page-level commands.
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

/// Domain operation surface for Runtime model commands.
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

/// Domain operation surface for Network model queries and commands.
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

/// Domain operation surface for Console model queries and commands.
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

/// Undo/redo surface for edits recorded through DataKit model operations.
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
    /// DOM model operations for this context.
    var dom: DOMModelController {
        DOMModelController(context: self)
    }

    /// CSS model operations for this context.
    var css: CSSModelController {
        CSSModelController(context: self)
    }

    /// Network model operations and fetch surfaces for this context.
    var network: NetworkModelController {
        NetworkModelController(context: self)
    }

    /// Runtime model operations for this context.
    var runtime: RuntimeModelController {
        RuntimeModelController(context: self)
    }

    /// Console model operations and fetch surfaces for this context.
    var console: ConsoleModelController {
        ConsoleModelController(context: self)
    }

    /// Page-level operations for this context.
    var page: PageModelController {
        PageModelController(context: self)
    }

    /// Undo and redo operations for edits recorded by this context.
    var editHistory: WebInspectorEditHistory {
        WebInspectorEditHistory(context: self)
    }
}
