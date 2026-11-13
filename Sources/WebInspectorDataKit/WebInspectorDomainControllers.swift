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
///
/// Node IDs address the currently registered model in this controller's
/// context. They do not revive a retained ``DOMNode`` from an earlier document
/// or from another context. See <doc:ModelRegistrationLifetimes>.
@MainActor
public final class DOMModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// Returns a live tree controller rooted at the current document.
    public func treeController() -> DOMTreeController {
        context.rootTreeController()
    }

    /// Requests regular child nodes for a DOM node.
    public func requestChildren(
        of nodeID: DOMNode.ID,
        depth: Int = 1
    ) async throws {
        try await context.requestChildren(for: nodeID, depth: depth)
    }

    /// Selects a DOM node and optionally asks tree views to reveal it.
    public func select(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) throws {
        try context.selectNode(nodeID, reveal: reveal)
    }

    /// Sets an attribute value on a DOM node.
    public func setAttribute(
        _ name: String,
        value: String,
        on nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        try await context.setDOMAttribute(name, value: value, on: nodeID, options: options)
    }

    /// Replaces a DOM node with the supplied outer HTML.
    public func setOuterHTML(
        _ html: String,
        of nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        try await context.setDOMOuterHTML(html, of: nodeID, options: options)
    }

    /// Removes DOM nodes from the inspected document.
    public func remove(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions = .automatic
    ) async throws -> DOMMutationResult {
        try await context.removeDOMNodes(nodeIDs, options: options)
    }

    /// Highlights a DOM node in the inspected page.
    public func highlight(
        _ nodeID: DOMNode.ID
    ) async throws {
        try await context.highlightNode(for: nodeID)
    }

    /// Clears the current DOM highlight.
    public func hideHighlight() async throws {
        try await context.hideHighlight()
    }

    /// Enables or disables WebKit's element picker.
    public func setInspectMode(
        enabled: Bool
    ) async throws {
        try await context.setElementPickerEnabled(enabled)
    }

    package func toggleInspectMode() async throws {
        try await context.toggleElementPickerEnabled()
    }
}

/// Domain operation surface for CSS model commands.
@MainActor
public final class CSSModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// Returns observable CSS styles for a DOM node.
    public func styles(
        for nodeID: DOMNode.ID
    ) throws -> CSSStyles {
        try context.styles(for: nodeID)
    }

    /// Requests a CSS style refresh for a DOM node.
    public func refreshStyles(
        for nodeID: DOMNode.ID
    ) throws {
        _ = try context.refreshStyles(for: nodeID)
    }

    /// Controls whether DataKit should hydrate CSS styles automatically.
    public func setStyleHydrationActive(
        _ active: Bool
    ) {
        context.setStyleHydrationActive(active)
    }

    /// Enables or disables a CSS declaration.
    public func setProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        try await context.setCSSProperty(propertyID, enabled: enabled, options: options)
    }

    /// Starts an asynchronous CSS declaration toggle request.
    @discardableResult
    public func requestSetProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic
    ) -> Bool {
        context.requestSetCSSProperty(propertyID, enabled: enabled, options: options)
    }

    /// Replaces the declaration text for a CSS property.
    public func setDeclarationText(
        _ text: String,
        for propertyID: CSSStyleProperty.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        try await context.setCSSDeclarationText(text, for: propertyID, options: options)
    }

    /// Replaces a CSS rule selector.
    public func setRuleSelector(
        _ selector: String,
        for ruleID: CSSStyleRule.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        try await context.setCSSRuleSelector(selector, for: ruleID, options: options)
    }

    /// Replaces the full text of a stylesheet.
    public func setStyleSheetText(
        _ text: String,
        for styleSheetID: CSS.StyleSheet.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws {
        try await context.setCSSStyleSheetText(text, for: styleSheetID, options: options)
    }
}

/// Domain operation surface for page-level commands.
@MainActor
public final class PageModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// Reloads the inspected page.
    public func reload(
        ignoringCache: Bool = false
    ) async throws {
        try await context.reloadPage(ignoringCache: ignoringCache)
    }
}

/// Domain operation surface for Runtime model commands.
@MainActor
public final class RuntimeModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// Evaluates JavaScript in the selected or supplied Runtime context.
    public func evaluate(
        _ expression: String,
        in runtimeContext: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation {
        try await context.evaluate(expression, in: runtimeContext)
    }
}

/// Domain operation surface for Network model queries and commands.
@MainActor
public final class NetworkModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// The recorded network requests, in arrival order.
    ///
    /// Reading this property from an observation scope tracks insertions and
    /// removals. Use ``requestChanges`` to apply changes incrementally.
    public var requests: [NetworkRequest] {
        context.networkRequests
    }

    /// The changes to ``requests``, starting from the moment of the call.
    ///
    /// An `updated` change reports that a request's own properties changed;
    /// each ``NetworkRequest`` is also observable on its own.
    public var requestChanges: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> {
        context.networkRequestChanges
    }

    /// Clears recorded network requests.
    public func clearRequests() {
        context.clearNetworkRequests()
    }
}

/// Domain operation surface for Console model queries and commands.
@MainActor
public final class ConsoleModelController {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// The recorded console messages, in arrival order.
    ///
    /// Reading this property from an observation scope tracks insertions and
    /// removals. Use ``messageChanges`` to apply changes incrementally.
    public var messages: [ConsoleMessage] {
        context.consoleMessages
    }

    /// The changes to ``messages``, starting from the moment of the call.
    public var messageChanges: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> {
        context.consoleMessageChanges
    }
}

/// Undo/redo surface for edits recorded through DataKit model operations.
@MainActor
public final class WebInspectorEditHistory {
    private let context: WebInspectorContext

    package init(context: WebInspectorContext) {
        self.context = context
    }

    /// Undoes the most recent edit recorded through DataKit.
    public func undo() async throws {
        try await context.undoDOMChange()
    }

    /// Redoes the most recent edit recorded through DataKit.
    public func redo() async throws {
        try await context.redoDOMChange()
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
