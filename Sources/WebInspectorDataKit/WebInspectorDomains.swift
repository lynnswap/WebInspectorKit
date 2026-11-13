import Foundation
import WebInspectorProxyKit

/// Controls how DOM selection changes should be revealed to UI tree views.
public enum DOMRevealPolicy: Sendable, Hashable {
    /// Do not reveal or select the node.
    case none

    /// Select the node without requesting scrolling.
    case selectOnly

    /// Select and request scrolling the node into view.
    case selectAndScroll
}

/// The DOM of the inspected page: its nodes, the selection, the element
/// picker, and the commands that read and edit nodes.
///
/// Commands take the ``DOMNode`` they act on. A node that is no longer
/// registered here, because its document was replaced or because it belongs
/// to another inspector, is never replaced by a later node with the
/// same identifier. See <doc:ModelRegistrationLifetimes>.
@MainActor
public final class DOMInspector {
    private let attachment: WebInspectorAttachment

    init(attachment: WebInspectorAttachment) {
        self.attachment = attachment
    }

    private var context: WebInspectorContext {
        attachment.context
    }

    /// The root node of the current document, if one is loaded.
    public var rootNode: DOMNode? {
        context.rootNode
    }

    /// The selected node.
    public var selectedNode: DOMNode? {
        context.selectedNode
    }

    /// A Boolean value indicating whether WebKit's element picker is on.
    public var isElementPickerEnabled: Bool {
        context.isElementPickerEnabled
    }

    /// Returns the registered node for an identifier, such as one read from
    /// a ``DOMTreeSnapshot``.
    public func node(for id: DOMNode.ID) -> DOMNode? {
        context.node(for: id)
    }

    /// Returns a live tree controller that follows the current document.
    public func treeController() -> DOMTreeController {
        context.rootTreeController()
    }

    /// Requests the regular child nodes of a node.
    ///
    /// The children arrive as updates to ``DOMNode/children``. A node that
    /// is not currently registered is ignored.
    public func requestChildren(
        of node: DOMNode,
        depth: Int = 1
    ) async {
        await context.requestChildren(for: node, depth: depth)
    }

    /// Selects a node and optionally asks tree views to reveal it.
    ///
    /// Passing `nil` clears the selection. A node that is not registered in
    /// this context is ignored, and the current selection is preserved.
    public func select(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) {
        context.select(node, reveal: reveal)
    }

    /// Sets an attribute value on a node.
    ///
    /// - Parameter registersUndo: Whether the edit joins WebKit's inspector
    ///   undo history, which ``undo()`` and ``redo()`` step through.
    public func setAttribute(
        _ name: String,
        value: String,
        on node: DOMNode,
        registersUndo: Bool = true
    ) async throws {
        try await context.setDOMAttribute(name, value: value, on: node, registersUndo: registersUndo)
    }

    /// Replaces a node with the supplied outer HTML.
    ///
    /// - Parameter registersUndo: Whether the edit joins WebKit's inspector
    ///   undo history, which ``undo()`` and ``redo()`` step through.
    public func setOuterHTML(
        _ html: String,
        of node: DOMNode,
        registersUndo: Bool = true
    ) async throws {
        try await context.setDOMOuterHTML(html, of: node, registersUndo: registersUndo)
    }

    /// Removes nodes from the inspected document and returns the removed
    /// nodes.
    ///
    /// Nodes are removed deepest first, and a node listed twice is removed
    /// once.
    /// - Parameter registersUndo: Whether the edit joins WebKit's inspector
    ///   undo history, which ``undo()`` and ``redo()`` step through.
    @discardableResult
    public func remove(
        _ nodes: [DOMNode],
        registersUndo: Bool = true
    ) async throws -> [DOMNode] {
        try await context.removeDOMNodes(nodes, registersUndo: registersUndo)
    }

    /// Returns text for a node in the requested format.
    public func copyText(
        _ kind: DOMNode.CopyTextKind,
        of node: DOMNode
    ) async throws -> String {
        try await context.copyText(kind, for: node)
    }

    /// Returns a CSS selector path for a node.
    public func selectorPath(for node: DOMNode) throws -> String {
        try context.selectorPath(for: node)
    }

    /// Returns an XPath expression for a node.
    public func xPath(for node: DOMNode) throws -> String {
        try context.xPath(for: node)
    }

    /// Highlights a node in the inspected page.
    public func highlight(_ node: DOMNode) async throws {
        try await context.highlight(node)
    }

    /// Clears the highlight in the inspected page.
    public func hideHighlight() async throws {
        try await context.hideHighlight()
    }

    /// Turns WebKit's element picker on or off.
    ///
    /// The latest call wins. A call made while a command is in flight
    /// replaces the pending state, and every caller returns once the picker
    /// matches the latest request. Cancelling the calling task after the
    /// request is recorded neither cancels nor reverts it.
    public func setElementPickerEnabled(_ isEnabled: Bool) async throws {
        try await context.setElementPickerEnabled(isEnabled)
    }

    package func toggleElementPicker() async throws {
        try await context.toggleElementPickerEnabled()
    }

    /// Undoes the most recent edit in WebKit's inspector undo history.
    public func undo() async throws {
        try await context.undoDOMChange()
    }

    /// Redoes the most recently undone edit.
    public func redo() async throws {
        try await context.redoDOMChange()
    }
}

/// The CSS styles of DOM nodes and the commands that edit them.
@MainActor
public final class CSSInspector {
    private let attachment: WebInspectorAttachment

    init(attachment: WebInspectorAttachment) {
        self.attachment = attachment
    }

    private var context: WebInspectorContext {
        attachment.context
    }

    /// Returns the observable styles of an element, selecting it first.
    ///
    /// - Throws: An error when the node is not an element or is not
    ///   currently registered.
    public func styles(for node: DOMNode) throws -> CSSStyles {
        try context.styles(for: node)
    }

    /// Requests a fresh load of an element's styles, selecting it first.
    public func refreshStyles(for node: DOMNode) throws {
        try context.refreshStyles(for: node)
    }

    /// Reports whether a style pane is visible.
    ///
    /// While active, stale styles of the selected node reload immediately.
    /// While inactive, they stay stale until the next activation or
    /// selection.
    public func setStyleHydrationActive(_ active: Bool) {
        context.setStyleHydrationActive(active)
    }

    /// Enables or disables a CSS declaration.
    public func setProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        registersUndo: Bool = true
    ) async throws {
        try await context.setCSSProperty(propertyID, enabled: enabled, registersUndo: registersUndo)
    }

    /// Starts enabling or disabling a CSS declaration without waiting for
    /// the command.
    ///
    /// Returns `false` without queuing a command when the property is not
    /// editable in the styles last loaded, or when a toggle for the same
    /// property is already running.
    @discardableResult
    public func requestSetProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        registersUndo: Bool = true
    ) -> Bool {
        context.requestSetCSSProperty(propertyID, enabled: enabled, registersUndo: registersUndo)
    }

    /// Replaces the declaration text for a CSS property.
    public func setDeclarationText(
        _ text: String,
        for propertyID: CSSStyleProperty.ID,
        registersUndo: Bool = true
    ) async throws {
        try await context.setCSSDeclarationText(text, for: propertyID, registersUndo: registersUndo)
    }

    /// Replaces a CSS rule selector.
    public func setRuleSelector(
        _ selector: String,
        for ruleID: CSSStyleRule.ID,
        registersUndo: Bool = true
    ) async throws {
        try await context.setCSSRuleSelector(selector, for: ruleID, registersUndo: registersUndo)
    }

    /// Replaces the full text of a stylesheet.
    public func setStyleSheetText(
        _ text: String,
        for styleSheetID: CSS.StyleSheet.ID,
        registersUndo: Bool = true
    ) async throws {
        try await context.setCSSStyleSheetText(text, for: styleSheetID, registersUndo: registersUndo)
    }
}

/// Domain operation surface for page-level commands.
@MainActor
public final class PageInspector {
    private let attachment: WebInspectorAttachment

    init(attachment: WebInspectorAttachment) {
        self.attachment = attachment
    }

    private var context: WebInspectorContext {
        attachment.context
    }

    /// Reloads the inspected page.
    public func reload(
        ignoringCache: Bool = false
    ) async throws {
        try await context.reloadPage(ignoringCache: ignoringCache)
    }
}

/// The Runtime execution contexts of the inspected page and the commands
/// that evaluate JavaScript and read remote objects.
@MainActor
public final class RuntimeInspector {
    private let attachment: WebInspectorAttachment

    init(attachment: WebInspectorAttachment) {
        self.attachment = attachment
    }

    private var context: WebInspectorContext {
        attachment.context
    }

    /// The Runtime execution contexts known to the current page.
    public var executionContexts: [RuntimeContext] {
        context.executionContexts
    }

    /// The execution context that ``evaluate(_:in:)`` uses by default.
    public var selectedContext: RuntimeContext? {
        context.selectedContext
    }

    /// Selects the execution context that ``evaluate(_:in:)`` uses by default.
    ///
    /// Passing `nil` clears the selection. Passing an execution context that
    /// is no longer registered, including one from another inspection
    /// context, does nothing and preserves the current selection.
    public func select(_ runtimeContext: RuntimeContext?) {
        context.selectContext(runtimeContext)
    }

    /// Evaluates JavaScript in the selected or supplied Runtime context.
    public func evaluate(
        _ expression: String,
        in runtimeContext: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation {
        try await context.evaluate(expression, in: runtimeContext)
    }

    /// Requests the own properties of a remote object.
    ///
    /// The result is empty for a value that has no remote handle, such as a
    /// primitive; see ``RuntimeObject/canRequestProperties``.
    /// - Throws: `WebInspectorProxyError.disconnected` when the object is no
    ///   longer currently registered.
    public func properties(of object: RuntimeObject) async throws -> [RuntimeObject.Property] {
        try await context.properties(for: object)
    }

    /// Requests the entries of a remote collection object.
    ///
    /// The result is empty for a value that has no remote handle, such as a
    /// primitive; see ``RuntimeObject/canRequestProperties``.
    /// - Throws: `WebInspectorProxyError.disconnected` when the object is no
    ///   longer currently registered.
    public func collectionEntries(of object: RuntimeObject) async throws -> [RuntimeObject.Entry] {
        try await context.collectionEntries(for: object)
    }
}

/// Domain operation surface for Network model queries and commands.
@MainActor
public final class NetworkInspector {
    private let attachment: WebInspectorAttachment

    init(attachment: WebInspectorAttachment) {
        self.attachment = attachment
    }

    private var context: WebInspectorContext {
        attachment.context
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
    /// The stream continues across attachments. A new attachment is reported
    /// as `removedAll`, followed by the insertion of the requests it starts
    /// with.
    ///
    /// An `updated` change reports that a Network event changed a request.
    /// Fetching a response body changes ``NetworkRequest/responseBody``
    /// without publishing a change; observe the request or its body for that.
    public var requestChanges: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> {
        attachment.requestChanges
    }

    /// The failure from the latest initial resource-tree lookup, if any.
    ///
    /// Live Network events remain available when only this lookup fails.
    public var resourceTreeError: WebInspectorProxyError? {
        context.networkResourceTreeError
    }

    /// Returns the registered request for an identifier.
    public func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        context.registeredRequest(for: id)
    }

    /// Clears recorded network requests.
    public func clearRequests() {
        context.clearNetworkRequests()
    }

    /// Fetches the response body of a finished request when it is available
    /// and not already loaded.
    ///
    /// The result is published on ``NetworkRequest/responseBody``. Concurrent
    /// callers join one protocol command. Cancelling a caller ends only that
    /// caller's wait and does not cancel the shared fetch. A request that is
    /// not currently registered is ignored.
    public func fetchResponseBody(for request: NetworkRequest) async {
        await context.fetchResponseBody(for: request)
    }
}

/// Domain operation surface for Console model queries and commands.
@MainActor
public final class ConsoleInspector {
    private let attachment: WebInspectorAttachment

    init(attachment: WebInspectorAttachment) {
        self.attachment = attachment
    }

    private var context: WebInspectorContext {
        attachment.context
    }

    /// The recorded console messages, in arrival order.
    ///
    /// Reading this property from an observation scope tracks insertions and
    /// removals. Use ``messageChanges`` to apply changes incrementally.
    public var messages: [ConsoleMessage] {
        context.consoleMessages
    }

    /// The changes to ``messages``, starting from the moment of the call.
    ///
    /// The stream continues across attachments. A new attachment is reported
    /// as `removedAll`, followed by the insertion of the messages it starts
    /// with.
    public var messageChanges: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> {
        attachment.messageChanges
    }

    /// Returns the registered message for an identifier.
    public func message(for id: ConsoleMessage.ID) -> ConsoleMessage? {
        context.registeredMessage(for: id)
    }
}

package extension WebInspectorContext {
    /// The DOM domain of this context.
    var dom: DOMInspector {
        DOMInspector(attachment: WebInspectorAttachment(context: self))
    }

    /// The CSS domain of this context.
    var css: CSSInspector {
        CSSInspector(attachment: WebInspectorAttachment(context: self))
    }

    /// The Network domain of this context.
    var network: NetworkInspector {
        NetworkInspector(attachment: WebInspectorAttachment(context: self))
    }

    /// The Runtime domain of this context.
    var runtime: RuntimeInspector {
        RuntimeInspector(attachment: WebInspectorAttachment(context: self))
    }

    /// The Console domain of this context.
    var console: ConsoleInspector {
        ConsoleInspector(attachment: WebInspectorAttachment(context: self))
    }

    /// The Page domain of this context.
    var page: PageInspector {
        PageInspector(attachment: WebInspectorAttachment(context: self))
    }
}
