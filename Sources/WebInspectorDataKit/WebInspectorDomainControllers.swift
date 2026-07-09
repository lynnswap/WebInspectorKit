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

    /// The undo policy for the mutation.
    public var undo: WebInspectorUndoPolicy

    /// The stale-model handling policy for the mutation.
    public var staleModel: WebInspectorStaleModelPolicy

    /// Creates mutation options.
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
    /// Let DataKit record undoable WebKit DOM mutations where supported.
    case automatic

    /// Do not record an undo checkpoint for the mutation.
    case disabled
}

/// Controls how DataKit handles stale model references.
public enum WebInspectorStaleModelPolicy: Sendable, Hashable {
    /// Fail when a model no longer belongs to the current context state.
    case fail
}

/// Controls how DOM selection changes should be revealed to UI tree views.
public enum DOMRevealPolicy: Sendable, Hashable {
    /// Do not reveal or select the node.
    case none

    /// Select the node without requesting scrolling.
    case selectOnly

    /// Select and request scrolling the node into view.
    case selectAndScroll
}

/// The accepted subset of a requested DOM mutation.
public struct DOMMutationResult: Sendable, Hashable {
    /// Node identities requested by the caller.
    public var requestedNodeIDs: [DOMNode.ID]

    /// Node identities accepted by the backend mutation.
    public var acceptedNodeIDs: [DOMNode.ID]

    /// Creates a DOM mutation result.
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

    /// Returns a live tree controller rooted at the current document.
    public func treeController(isolation: isolated (any Actor) = #isolation) -> DOMTreeController {
        context.rootTreeController(isolation: isolation)
    }

    /// Requests regular child nodes for a DOM node.
    public func requestChildren(
        of nodeID: DOMNode.ID,
        depth: Int = 1,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.requestChildren(for: nodeID, depth: depth, isolation: isolation)
    }

    /// Selects a DOM node and optionally asks tree views to reveal it.
    public func select(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy = .selectAndScroll,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        try context.selectNode(nodeID, reveal: reveal, isolation: isolation)
    }

    /// Sets an attribute value on a DOM node.
    public func setAttribute(
        _ name: String,
        value: String,
        on nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setDOMAttribute(name, value: value, on: nodeID, options: options, isolation: isolation)
    }

    /// Replaces a DOM node with the supplied outer HTML.
    public func setOuterHTML(
        _ html: String,
        of nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setDOMOuterHTML(html, of: nodeID, options: options, isolation: isolation)
    }

    /// Removes DOM nodes from the inspected document.
    public func remove(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> DOMMutationResult {
        try await context.removeDOMNodes(nodeIDs, options: options, isolation: isolation)
    }

    /// Highlights a DOM node in the inspected page.
    public func highlight(
        _ nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.highlightNode(for: nodeID, isolation: isolation)
    }

    /// Clears the current DOM highlight.
    public func hideHighlight(isolation: isolated (any Actor) = #isolation) async throws {
        try await context.hideHighlight(isolation: isolation)
    }

    /// Enables or disables WebKit's element picker.
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

    /// Returns observable CSS styles for a DOM node.
    public func styles(
        for nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) throws -> CSSStyles {
        try context.styles(for: nodeID, isolation: isolation)
    }

    /// Requests a CSS style refresh for a DOM node.
    public func refreshStyles(
        for nodeID: DOMNode.ID,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        _ = try context.refreshStyles(for: nodeID, isolation: isolation)
    }

    /// Controls whether DataKit should hydrate CSS styles automatically.
    public func setStyleHydrationActive(
        _ active: Bool,
        isolation: isolated (any Actor) = #isolation
    ) {
        context.setStyleHydrationActive(active, isolation: isolation)
    }

    /// Enables or disables a CSS declaration.
    public func setProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSProperty(propertyID, enabled: enabled, options: options, isolation: isolation)
    }

    /// Starts an asynchronous CSS declaration toggle request.
    @discardableResult
    public func requestSetProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) -> Bool {
        context.requestSetCSSProperty(propertyID, enabled: enabled, options: options, isolation: isolation)
    }

    /// Replaces the declaration text for a CSS property.
    public func setDeclarationText(
        _ text: String,
        for propertyID: CSSStyleProperty.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSDeclarationText(text, for: propertyID, options: options, isolation: isolation)
    }

    /// Replaces a CSS rule selector.
    public func setRuleSelector(
        _ selector: String,
        for ruleID: CSSStyleRule.ID,
        options: WebInspectorMutationOptions = .automatic,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        try await context.setCSSRuleSelector(selector, for: ruleID, options: options, isolation: isolation)
    }

    /// Replaces the full text of a stylesheet.
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

    /// Reloads the inspected page.
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

    /// Evaluates JavaScript in the selected or supplied Runtime context.
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

    /// Creates observable network request results.
    public func fetchedResults(
        for descriptor: WebInspectorFetchDescriptor<NetworkRequest> = .init(),
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<NetworkRequest> {
        context.fetchedResults(for: descriptor, sectionBy: sectionBy, isolation: isolation)
    }

    /// Creates a controller for observable network request results.
    public func fetchedResultsController(
        for descriptor: WebInspectorFetchDescriptor<NetworkRequest> = .init(),
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>? = nil,
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResultsController<NetworkRequest> {
        WebInspectorFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionBy: sectionBy, isolation: isolation)
        )
    }

    /// Clears recorded network requests.
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

    /// Creates observable console message results.
    public func fetchedResults(
        for descriptor: WebInspectorFetchDescriptor<ConsoleMessage> = .init(),
        isolation: isolated (any Actor) = #isolation
    ) -> WebInspectorFetchedResults<ConsoleMessage> {
        context.fetchedResults(for: descriptor, isolation: isolation)
    }

    /// Creates a controller for observable console message results.
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

    /// Undoes the most recent edit recorded through DataKit.
    public func undo(isolation: isolated (any Actor) = #isolation) async throws {
        try await context.undoDOMChange(isolation: isolation)
    }

    /// Redoes the most recent edit recorded through DataKit.
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
