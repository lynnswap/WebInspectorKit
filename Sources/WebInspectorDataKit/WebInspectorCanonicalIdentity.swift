import Foundation
import WebInspectorProxyKit

/// Identifies one canonical record store for the lifetime of a model
/// container.
///
/// This package-only value is storage for opaque public persistent-model
/// identifiers. It is not a second public ID surface.
package struct WebInspectorContainerStoreID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Identifies one attachment attempt reserved by a model container.
///
/// The container allocates these values monotonically and never reuses a value,
/// including when native attachment or model-feed adoption fails.
package struct WebInspectorContainerAttachmentGeneration: Hashable, Comparable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (
        lhs: WebInspectorContainerAttachmentGeneration,
        rhs: WebInspectorContainerAttachmentGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Canonical Network routing authority for one protocol event.
///
/// `semanticTargetID` owns model membership while `agentTargetID` owns the
/// physical Network command and request-ID namespace. They may differ for
/// frame and worker loads.
package struct WebInspectorCanonicalNetworkEventScope: Equatable, Sendable {
    package let generation: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let navigationEpoch: ModelNavigationEpoch
    package let domBindingEpoch: ModelDOMBindingEpoch?

    package init(
        modelScope: ModelEventScope
    ) {
        generation = modelScope.generation
        semanticTargetID = modelScope.target.id
        agentTargetID = modelScope.agentTarget.id
        navigationEpoch = modelScope.navigationEpoch
        domBindingEpoch = modelScope.domBindingEpoch
    }
}

/// Canonical DOM/CSS routing authority for one exact document binding.
package struct WebInspectorCanonicalDOMEventScope: Equatable, Sendable {
    package let modelScope: ModelEventScope

    package var semanticTargetID: WebInspectorTarget.ID {
        modelScope.target.id
    }

    package var agentTargetID: WebInspectorTarget.ID {
        modelScope.agentTarget.id
    }

    package init(modelScope: ModelEventScope) {
        self.modelScope = modelScope
    }
}

package struct WebInspectorDOMTargetRouteStorage: Hashable, Sendable {
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID

    package init(
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID
    ) {
        self.semanticTargetID = semanticTargetID
        self.agentTargetID = agentTargetID
    }
}

package struct WebInspectorDOMDocumentScopeStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let pageGeneration: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let domBindingEpoch: ModelDOMBindingEpoch

    package var targetRoute: WebInspectorDOMTargetRouteStorage {
        WebInspectorDOMTargetRouteStorage(
            semanticTargetID: semanticTargetID,
            agentTargetID: agentTargetID
        )
    }

    package init?(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        eventScope: WebInspectorCanonicalDOMEventScope
    ) {
        guard let domBindingEpoch = eventScope.modelScope.domBindingEpoch else {
            return nil
        }
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        pageGeneration = eventScope.modelScope.generation
        semanticTargetID = eventScope.semanticTargetID
        agentTargetID = eventScope.agentTargetID
        self.domBindingEpoch = domBindingEpoch
    }

    package static func precedesInCanonicalOrder(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        if lhs.storeID != rhs.storeID {
            return lhs.storeID.rawValue.uuidString < rhs.storeID.rawValue.uuidString
        }
        if lhs.attachmentGeneration != rhs.attachmentGeneration {
            return lhs.attachmentGeneration < rhs.attachmentGeneration
        }
        if lhs.pageGeneration != rhs.pageGeneration {
            return lhs.pageGeneration.rawValue < rhs.pageGeneration.rawValue
        }
        if lhs.semanticTargetID != rhs.semanticTargetID {
            return lhs.semanticTargetID.rawValue < rhs.semanticTargetID.rawValue
        }
        if lhs.agentTargetID != rhs.agentTargetID {
            return lhs.agentTargetID.rawValue < rhs.agentTargetID.rawValue
        }
        return lhs.domBindingEpoch.rawValue < rhs.domBindingEpoch.rawValue
    }
}

package struct WebInspectorDOMNodeIdentityStorage: Hashable, Sendable {
    package let documentScope: WebInspectorDOMDocumentScopeStorage
    package let rawNodeID: DOM.Node.ID

    package init(
        documentScope: WebInspectorDOMDocumentScopeStorage,
        rawNodeID: DOM.Node.ID
    ) {
        self.documentScope = documentScope
        self.rawNodeID = rawNodeID
    }
}

package struct WebInspectorCSSStyleSheetIdentityStorage: Hashable, Sendable {
    package let documentScope: WebInspectorDOMDocumentScopeStorage
    package let rawStyleSheetID: CSS.StyleSheet.ID

    package init(
        documentScope: WebInspectorDOMDocumentScopeStorage,
        rawStyleSheetID: CSS.StyleSheet.ID
    ) {
        self.documentScope = documentScope
        self.rawStyleSheetID = rawStyleSheetID
    }
}

/// Canonical storage wrapped by `NetworkRequest.ID`.
///
/// Raw protocol IDs remain opaque. In particular, this type never parses the
/// target-prefixed compatibility representation used by ProxyKit's direct
/// event API.
package struct CanonicalNetworkRequestIDStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let pageGeneration: WebInspectorPage.Generation
    package let agentTargetID: WebInspectorTarget.ID
    package let rawRequestID: Network.Request.ID

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation,
        agentTargetID: WebInspectorTarget.ID,
        rawRequestID: Network.Request.ID
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        self.agentTargetID = agentTargetID
        self.rawRequestID = rawRequestID
    }
}

/// Canonical storage wrapped by `NetworkEntry.ID`.
package struct CanonicalNetworkEntryIDStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let ordinal: UInt64

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        ordinal: UInt64
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.ordinal = ordinal
    }
}

/// Canonical DOM identity used only when a Network event carries the exact DOM
/// binding epoch that owns its initiator node.
package struct CanonicalNetworkDOMInitiatorKey: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let pageGeneration: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let domBindingEpoch: ModelDOMBindingEpoch
    package let rawNodeID: DOM.Node.ID

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID,
        domBindingEpoch: ModelDOMBindingEpoch,
        rawNodeID: DOM.Node.ID
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        self.semanticTargetID = semanticTargetID
        self.agentTargetID = agentTargetID
        self.domBindingEpoch = domBindingEpoch
        self.rawNodeID = rawNodeID
    }
}

/// Opaque grouping identity used when Network knows an initiator node but does
/// not have an exact DOM binding from which a persistent DOM identity can be
/// constructed.
package struct CanonicalNetworkOpaqueInitiatorKey: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let pageGeneration: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let navigationEpoch: ModelNavigationEpoch
    package let rawNodeID: DOM.Node.ID

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID,
        navigationEpoch: ModelNavigationEpoch,
        rawNodeID: DOM.Node.ID
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        self.semanticTargetID = semanticTargetID
        self.agentTargetID = agentTargetID
        self.navigationEpoch = navigationEpoch
        self.rawNodeID = rawNodeID
    }
}

/// Canonical Network grouping identity.
package enum CanonicalNetworkGroupKey: Hashable, Sendable {
    /// A node with an exact resolvable DOM binding.
    case dom(CanonicalNetworkDOMInitiatorKey)

    /// A node that is related only within one navigation epoch.
    case opaqueInitiator(CanonicalNetworkOpaqueInitiatorKey)

    /// A request with no node initiator forms its own entry.
    case request(CanonicalNetworkRequestIDStorage)
}
