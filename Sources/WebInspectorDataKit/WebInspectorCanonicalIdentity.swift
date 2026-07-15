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

/// Identifies one DOM backend binding within a page generation.
package struct WebInspectorDOMBindingScopeID: RawRepresentable, Hashable, Comparable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (
        lhs: WebInspectorDOMBindingScopeID,
        rhs: WebInspectorDOMBindingScopeID
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct WebInspectorRuntimeBindingGeneration: RawRepresentable, Hashable, Sendable {
    package let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
}

package struct WebInspectorConsoleBindingGeneration: RawRepresentable, Hashable, Sendable {
    package let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Identifies one committed loader lifetime within a semantic target.
///
/// Page generation changes only when ProxyKit replaces the inspected target.
/// A same-target navigation advances this value without changing page
/// generation or replaying domain capabilities.
package struct WebInspectorNavigationEpoch:
    RawRepresentable, Hashable, Comparable, Sendable
{
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (
        lhs: WebInspectorNavigationEpoch,
        rhs: WebInspectorNavigationEpoch
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Canonical storage wrapped by `RuntimeContext.ID`.
///
/// WebKit allocates execution-context identifiers in one physical Runtime
/// agent. Semantic frame membership is deliberately retained by the record,
/// not folded into this identity, because destroy and clear events carry only
/// agent-local authority.
package struct CanonicalRuntimeContextIDStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let pageGeneration: WebInspectorPageGeneration
    package let agentTargetID: WebInspectorTarget.ID
    package let rawContextID: Runtime.ExecutionContext.ID

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration,
        agentTargetID: WebInspectorTarget.ID,
        rawContextID: Runtime.ExecutionContext.ID
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        self.agentTargetID = agentTargetID
        self.rawContextID = rawContextID
    }
}

/// Canonical storage wrapped by `ConsoleMessage.ID`.
///
/// The ordinal is allocated once by the container store and is never reused,
/// including across page reset and reattachment. Console's protocol payload
/// has no backend message identifier from which a stable identity can be
/// reconstructed.
package struct CanonicalConsoleMessageIDStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let ordinal: UInt64

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        ordinal: UInt64
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.ordinal = ordinal
    }
}

/// Exact semantic origin selected from protocol, frame-map, or event authority.
package enum CanonicalNetworkRequestOrigin: Equatable, Sendable {
    case protocolTarget(WebInspectorTarget.ID)
    case mappedFrame(frameID: FrameID, targetID: WebInspectorTarget.ID)
    case eventTarget(WebInspectorTarget.ID)

    package var semanticTargetID: WebInspectorTarget.ID {
        switch self {
        case let .protocolTarget(targetID),
            let .mappedFrame(_, targetID),
            let .eventTarget(targetID):
            targetID
        }
    }
}

/// Navigation and DOM authority exists only when the origin target is part of
/// the canonical target graph. A present but not-yet-registered worker target
/// keeps its exact origin identity without borrowing another target's epoch.
package struct CanonicalNetworkRegisteredTargetAuthority: Equatable, Hashable, Sendable {
    package let targetID: WebInspectorTarget.ID
    package let navigationEpoch: WebInspectorNavigationEpoch
    package let domBindingEpoch: WebInspectorDOMBindingScopeID?

    package init(
        targetID: WebInspectorTarget.ID,
        navigationEpoch: WebInspectorNavigationEpoch,
        domBindingEpoch: WebInspectorDOMBindingScopeID?
    ) {
        self.targetID = targetID
        self.navigationEpoch = navigationEpoch
        self.domBindingEpoch = domBindingEpoch
    }
}

/// Canonical Network routing authority for one protocol event.
///
/// `origin` owns model membership while `agentTargetID` owns the physical
/// Network command and request-ID namespace. They may differ for frame and
/// worker loads.
package struct WebInspectorCanonicalNetworkEventScope: Equatable, Sendable {
    package let generation: WebInspectorPageGeneration
    package let origin: CanonicalNetworkRequestOrigin
    package let agentTargetID: WebInspectorTarget.ID
    package let targetAuthority: CanonicalNetworkRegisteredTargetAuthority?
    package let frameID: FrameID?
    package let loaderID: String?

    package var semanticTargetID: WebInspectorTarget.ID {
        origin.semanticTargetID
    }

    package var navigationEpoch: WebInspectorNavigationEpoch? {
        targetAuthority?.navigationEpoch
    }

    package var domBindingEpoch: WebInspectorDOMBindingScopeID? {
        targetAuthority?.domBindingEpoch
    }

    package init(
        modelScope: WebInspectorFeatureEventScope
    ) {
        generation = modelScope.generation
        origin = .eventTarget(modelScope.semanticTargetID)
        agentTargetID = modelScope.agentTargetID
        targetAuthority = CanonicalNetworkRegisteredTargetAuthority(
            targetID: modelScope.semanticTargetID,
            navigationEpoch: WebInspectorNavigationEpoch(rawValue: 0),
            domBindingEpoch: nil
        )
        frameID = nil
        loaderID = nil
    }

    package init(
        modelScope: WebInspectorFeatureEventScope,
        membership: CanonicalNetworkRequestMembership
    ) {
        generation = modelScope.generation
        origin = membership.origin
        agentTargetID = modelScope.agentTargetID
        targetAuthority = membership.targetAuthority
        frameID = membership.frameID
        loaderID = membership.loaderID
    }

    package init(
        modelScope: WebInspectorFeatureEventScope,
        origin: CanonicalNetworkRequestOrigin,
        targetAuthority: CanonicalNetworkRegisteredTargetAuthority?,
        frameID: FrameID,
        loaderID: String
    ) {
        precondition(
            targetAuthority == nil
                || targetAuthority?.targetID == origin.semanticTargetID,
            "Canonical Network target authority does not own its request origin."
        )
        generation = modelScope.generation
        self.origin = origin
        agentTargetID = modelScope.agentTargetID
        self.targetAuthority = targetAuthority
        self.frameID = frameID
        self.loaderID = loaderID
    }
}

/// Canonical DOM/CSS routing authority for one exact document binding.
package struct WebInspectorCanonicalDOMEventScope: Equatable, Sendable {
    package let modelScope: WebInspectorFeatureEventScope
    package let bindingScopeID: WebInspectorDOMBindingScopeID

    package var semanticTargetID: WebInspectorTarget.ID {
        modelScope.semanticTargetID
    }

    package var agentTargetID: WebInspectorTarget.ID {
        modelScope.agentTargetID
    }

    package init(
        modelScope: WebInspectorFeatureEventScope,
        bindingScopeID: WebInspectorDOMBindingScopeID
    ) {
        self.modelScope = modelScope
        self.bindingScopeID = bindingScopeID
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
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let pageGeneration: WebInspectorPageGeneration
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let domBindingEpoch: WebInspectorDOMBindingScopeID

    package var targetRoute: WebInspectorDOMTargetRouteStorage {
        WebInspectorDOMTargetRouteStorage(
            semanticTargetID: semanticTargetID,
            agentTargetID: agentTargetID
        )
    }

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID,
        domBindingEpoch: WebInspectorDOMBindingScopeID
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        self.semanticTargetID = semanticTargetID
        self.agentTargetID = agentTargetID
        self.domBindingEpoch = domBindingEpoch
    }

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        eventScope: WebInspectorCanonicalDOMEventScope
    ) {
        self.init(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            pageGeneration: eventScope.modelScope.generation,
            semanticTargetID: eventScope.semanticTargetID,
            agentTargetID: eventScope.agentTargetID,
            domBindingEpoch: eventScope.bindingScopeID
        )
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

/// Feature-assigned canonical storage wrapped by `NetworkRequest.ID`.
package struct CanonicalNetworkRequestIDStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let ordinal: UInt64

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        ordinal: UInt64
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.ordinal = ordinal
    }
}

/// Generation-scoped routing authority for one raw backend request ID.
///
/// This value is an actor-owned lookup key. It is never exposed as persistent
/// model identity and is discarded on page or attachment replacement.
package struct CanonicalNetworkRawRequestAlias: Hashable, Sendable {
    package let pageGeneration: WebInspectorPageGeneration
    package let agentTargetID: WebInspectorTarget.ID
    package let rawRequestID: Network.Request.ID

    package init(
        pageGeneration: WebInspectorPageGeneration,
        agentTargetID: WebInspectorTarget.ID,
        rawRequestID: Network.Request.ID
    ) {
        self.pageGeneration = pageGeneration
        self.agentTargetID = agentTargetID
        self.rawRequestID = rawRequestID
    }

    package init(
        rawRequestID: Network.Request.ID,
        scope: WebInspectorCanonicalNetworkEventScope
    ) {
        self.init(
            pageGeneration: scope.generation,
            agentTargetID: scope.agentTargetID,
            rawRequestID: rawRequestID
        )
    }
}

/// Canonical storage wrapped by `NetworkEntry.ID`.
package struct CanonicalNetworkEntryIDStorage: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let ordinal: UInt64

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        ordinal: UInt64
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.ordinal = ordinal
    }
}

/// Opaque grouping identity used when Network knows an initiator node but does
/// not have an exact DOM binding from which a persistent DOM identity can be
/// constructed.
package struct CanonicalNetworkOpaqueInitiatorKey: Hashable, Sendable {
    package let storeID: WebInspectorContainerStoreID
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let pageGeneration: WebInspectorPageGeneration
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let frameID: FrameID?
    package let targetAuthority: CanonicalNetworkRegisteredTargetAuthority?
    package let rawNodeID: DOM.Node.ID

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID,
        frameID: FrameID? = nil,
        targetAuthority: CanonicalNetworkRegisteredTargetAuthority?,
        rawNodeID: DOM.Node.ID
    ) {
        self.storeID = storeID
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        self.semanticTargetID = semanticTargetID
        self.agentTargetID = agentTargetID
        self.frameID = frameID
        self.targetAuthority = targetAuthority
        self.rawNodeID = rawNodeID
    }

    package init(
        storeID: WebInspectorContainerStoreID,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID,
        frameID: FrameID? = nil,
        navigationEpoch: WebInspectorNavigationEpoch,
        rawNodeID: DOM.Node.ID
    ) {
        self.init(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration,
            semanticTargetID: semanticTargetID,
            agentTargetID: agentTargetID,
            frameID: frameID,
            targetAuthority: CanonicalNetworkRegisteredTargetAuthority(
                targetID: semanticTargetID,
                navigationEpoch: navigationEpoch,
                domBindingEpoch: nil
            ),
            rawNodeID: rawNodeID
        )
    }
}

/// Canonical Network grouping identity.
package enum CanonicalNetworkGroupKey: Hashable, Sendable {
    /// A node with an exact resolvable DOM binding.
    case dom(WebInspectorDOMNodeIdentityStorage)

    /// A node that is related only within one navigation epoch.
    case opaqueInitiator(CanonicalNetworkOpaqueInitiatorKey)

    /// A request with no node initiator forms its own entry.
    case request(CanonicalNetworkRequestIDStorage)
}
