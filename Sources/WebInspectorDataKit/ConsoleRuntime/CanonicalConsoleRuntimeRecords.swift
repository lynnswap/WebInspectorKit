import WebInspectorProxyKit

/// Exact routing and binding authority for Console/Runtime reduction.
///
/// The generic connection scope carries only FIFO route facts. Binding
/// epochs are issued by the Console/Runtime feature actor and remain local to
/// that feature instead of leaking domain state into the connection layer.
package struct WebInspectorConsoleRuntimeEventScope: Equatable, Sendable {
    package let generation: WebInspectorPageGeneration
    package let target: WebInspectorFeatureTarget
    package let agentTarget: WebInspectorFeatureTarget
    package let navigationEpoch: WebInspectorNavigationEpoch
    package let runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration?
    package let consoleBindingEpoch: WebInspectorConsoleBindingGeneration?

    package init(
        route: WebInspectorFeatureEventScope,
        navigationEpoch: WebInspectorNavigationEpoch,
        runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration?,
        consoleBindingEpoch: WebInspectorConsoleBindingGeneration?
    ) {
        generation = route.generation
        target = route.semanticTarget
        agentTarget = route.agentTarget
        self.navigationEpoch = navigationEpoch
        self.runtimeBindingEpoch = runtimeBindingEpoch
        self.consoleBindingEpoch = consoleBindingEpoch
    }
}

package struct CanonicalRuntimeContextMembership: Equatable, Sendable {
    package let semanticTargetID: WebInspectorTarget.ID
    package let navigationEpoch: WebInspectorNavigationEpoch
    package let runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration

    package init(
        semanticTargetID: WebInspectorTarget.ID,
        navigationEpoch: WebInspectorNavigationEpoch,
        runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration
    ) {
        self.semanticTargetID = semanticTargetID
        self.navigationEpoch = navigationEpoch
        self.runtimeBindingEpoch = runtimeBindingEpoch
    }
}

package struct CanonicalRuntimeContextQueryProjection: Equatable, Sendable {
    package let id: CanonicalRuntimeContextIDStorage
    package let name: String
    package let frameID: FrameID?
    package let kind: Runtime.ContextKind
}

package struct CanonicalRuntimeContextPatch: Equatable, Sendable {
    private init() {}
}

package struct CanonicalRuntimeContextRecord: Equatable, Sendable {
    package let id: CanonicalRuntimeContextIDStorage
    package let insertionOrdinal: UInt64
    package let membership: CanonicalRuntimeContextMembership
    package let name: String
    package let frameID: FrameID?
    package let kind: Runtime.ContextKind

    package var queryProjection: CanonicalRuntimeContextQueryProjection {
        CanonicalRuntimeContextQueryProjection(
            id: id,
            name: name,
            frameID: frameID,
            kind: kind
        )
    }

    package mutating func apply(_ patch: CanonicalRuntimeContextPatch) {
        _ = patch
    }
}

package struct CanonicalConsoleCallFrame: Equatable, Sendable {
    package let functionName: String
    package let url: String
    package let line: Int
    package let column: Int

    package init(_ frame: Console.CallFrame) {
        functionName = frame.functionName
        url = frame.url
        line = frame.line
        column = frame.column
    }
}

package struct CanonicalConsoleStackTrace: Equatable, Sendable {
    package let callFrames: [CanonicalConsoleCallFrame]

    package init(_ stackTrace: Console.StackTrace) {
        callFrames = stackTrace.callFrames.map(CanonicalConsoleCallFrame.init)
    }
}

package struct CanonicalRuntimePropertyPreview: Equatable, Sendable {
    package let name: String
    package let value: String?

    package init(_ preview: Runtime.PropertyPreview) {
        name = preview.name
        value = preview.value
    }
}

package struct CanonicalRuntimeEntryPreview: Equatable, Sendable {
    package let key: String?
    package let value: String?

    package init(_ preview: Runtime.EntryPreview) {
        key = preview.key
        value = preview.value
    }
}

package struct CanonicalRuntimeObjectPreview: Equatable, Sendable {
    package let kind: Runtime.Kind?
    package let subtype: Runtime.Subtype?
    package let description: String?
    package let lossless: Bool
    package let overflow: Bool
    package let properties: [CanonicalRuntimePropertyPreview]
    package let entries: [CanonicalRuntimeEntryPreview]
    package let size: Int?

    package init(_ preview: Runtime.ObjectPreview) {
        kind = preview.kind
        subtype = preview.subtype
        description = preview.description
        lossless = preview.lossless
        overflow = preview.overflow
        properties = preview.properties.map(CanonicalRuntimePropertyPreview.init)
        entries = preview.entries.map(CanonicalRuntimeEntryPreview.init)
        size = preview.size
    }
}

/// Lossless value payload for a Console-owned Runtime parameter.
///
/// This is a context-resource seed, not a persistent model record. Its raw
/// object identifier is meaningful only together with the authority captured
/// by `CanonicalConsoleParameterAuthority`.
package struct CanonicalRuntimeRemoteObjectPayload: Equatable, Sendable {
    package let rawObjectID: Runtime.RemoteObject.ID?
    package let kind: Runtime.Kind
    package let subtype: Runtime.Subtype?
    package let className: String?
    package let description: String?
    package let value: Runtime.JSONValue?
    package let size: Int?
    package let preview: CanonicalRuntimeObjectPreview?

    package init(_ object: Runtime.RemoteObject) {
        rawObjectID = object.id
        kind = object.kind
        subtype = object.subtype
        className = object.className
        description = object.description
        value = object.value
        size = object.size
        preview = object.preview.map(CanonicalRuntimeObjectPreview.init)
    }
}

/// Exact command authority captured when WebKit publishes a Console parameter.
package struct CanonicalConsoleParameterAuthority: Equatable, Sendable {
    package let ownerMessageID: CanonicalConsoleMessageIDStorage
    package let pageGeneration: WebInspectorPageGeneration
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let navigationEpoch: WebInspectorNavigationEpoch
    package let runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration
    package let consoleBindingEpoch: WebInspectorConsoleBindingGeneration
}

package struct CanonicalConsoleParameterResourceSeed: Equatable, Sendable {
    package let payload: CanonicalRuntimeRemoteObjectPayload
    package let authority: CanonicalConsoleParameterAuthority
}

package struct CanonicalConsoleMessageMembership: Equatable, Sendable {
    package let pageGeneration: WebInspectorPageGeneration
    package let semanticTargetID: WebInspectorTarget.ID
    package let agentTargetID: WebInspectorTarget.ID
    package let navigationEpoch: WebInspectorNavigationEpoch
    package let runtimeBindingEpoch: WebInspectorRuntimeBindingGeneration
    package let consoleBindingEpoch: WebInspectorConsoleBindingGeneration
}

package enum CanonicalConsoleNetworkRequestReference: Equatable, Sendable {
    case unresolved(rawRequestID: Network.Request.ID)
    case resolved(
        rawRequestID: Network.Request.ID,
        requestID: CanonicalNetworkRequestIDStorage
    )

    package var rawRequestID: Network.Request.ID {
        switch self {
        case let .unresolved(rawRequestID),
            let .resolved(rawRequestID, _):
            rawRequestID
        }
    }
}

/// Typed handoff from the canonical Network owner to the Console reducer.
package struct CanonicalConsoleNetworkRequestResolution: Equatable, Sendable {
    package let rawAlias: CanonicalNetworkRawRequestAlias
    package let requestID: CanonicalNetworkRequestIDStorage

    package var rawRequestID: Network.Request.ID {
        rawAlias.rawRequestID
    }

    package init(
        rawAlias: CanonicalNetworkRawRequestAlias,
        requestID: CanonicalNetworkRequestIDStorage
    ) {
        self.rawAlias = rawAlias
        self.requestID = requestID
    }
}

package struct CanonicalConsoleMessageQueryProjection: Equatable, Sendable {
    package let id: CanonicalConsoleMessageIDStorage
    package let insertionOrdinal: UInt64
    package let source: Console.Source
    package let level: Console.Level
    package let kind: Console.Kind?
    package let text: String
    package let url: String?
    package let line: Int?
    package let column: Int?
    package let repeatCount: Int
    package let timestamp: Double?
}

package struct CanonicalConsoleMessageRecord: Equatable, Sendable {
    package let id: CanonicalConsoleMessageIDStorage
    package let membership: CanonicalConsoleMessageMembership
    package let source: Console.Source
    package let level: Console.Level
    package let kind: Console.Kind?
    package let text: String
    package let url: String?
    package let line: Int?
    package let column: Int?
    package var repeatCount: Int
    package let parameters: [CanonicalConsoleParameterResourceSeed]
    package let stackTrace: CanonicalConsoleStackTrace?
    package var networkRequestReference: CanonicalConsoleNetworkRequestReference?
    package var timestamp: Double?

    package var queryProjection: CanonicalConsoleMessageQueryProjection {
        CanonicalConsoleMessageQueryProjection(
            id: id,
            insertionOrdinal: id.ordinal,
            source: source,
            level: level,
            kind: kind,
            text: text,
            url: url,
            line: line,
            column: column,
            repeatCount: repeatCount,
            timestamp: timestamp
        )
    }
}

package enum CanonicalConsoleMessagePatch: Equatable, Sendable {
    case repeatCount(count: Int, timestamp: Double?)
    case networkRequestReference(CanonicalConsoleNetworkRequestReference)
}

package extension CanonicalConsoleMessageRecord {
    mutating func apply(_ patch: CanonicalConsoleMessagePatch) {
        switch patch {
        case let .repeatCount(count, timestamp):
            repeatCount = count
            self.timestamp = timestamp
        case let .networkRequestReference(reference):
            networkRequestReference = reference
        }
    }
}

package enum CanonicalRuntimeContextChange: Equatable, Sendable {
    case insert(
        record: CanonicalRuntimeContextRecord,
        query: CanonicalRuntimeContextQueryProjection
    )
    case delete(CanonicalRuntimeContextIDStorage)
}

package enum CanonicalConsoleMessageChange: Equatable, Sendable {
    case insert(
        record: CanonicalConsoleMessageRecord,
        query: CanonicalConsoleMessageQueryProjection
    )
    case update(
        id: CanonicalConsoleMessageIDStorage,
        patch: CanonicalConsoleMessagePatch,
        query: CanonicalConsoleMessageQueryProjection?
    )
    case delete(CanonicalConsoleMessageIDStorage)
}

package enum CanonicalConsoleRuntimeResourceInvalidation: Equatable, Sendable {
    case runtimeBinding(
        agentTargetID: WebInspectorTarget.ID,
        epoch: WebInspectorRuntimeBindingGeneration
    )
    case consoleBinding(
        agentTargetID: WebInspectorTarget.ID,
        epoch: WebInspectorConsoleBindingGeneration
    )
    case semanticNavigation(
        semanticTargetID: WebInspectorTarget.ID,
        navigationEpoch: WebInspectorNavigationEpoch
    )
    case frameDetached(FrameID)
    case targetLost(WebInspectorTarget.ID)
    case attachmentDetached(
        attachmentGeneration: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration
    )
    case attachmentReset(
        previous: WebInspectorAttachmentGeneration?,
        current: WebInspectorAttachmentGeneration,
        pageGeneration: WebInspectorPageGeneration
    )
}

package struct CanonicalConsoleRuntimeTransaction: Equatable, Sendable {
    package var runtimeContextChanges: [CanonicalRuntimeContextChange] = []
    package var consoleMessageChanges: [CanonicalConsoleMessageChange] = []
    package var resourceInvalidations: [CanonicalConsoleRuntimeResourceInvalidation] = []

    package var isEmpty: Bool {
        runtimeContextChanges.isEmpty
            && consoleMessageChanges.isEmpty
            && resourceInvalidations.isEmpty
    }
}

package struct CanonicalRuntimeContextSnapshotEntry: Equatable, Sendable {
    package let record: CanonicalRuntimeContextRecord
    package let query: CanonicalRuntimeContextQueryProjection
}

package struct CanonicalConsoleMessageSnapshotEntry: Equatable, Sendable {
    package let record: CanonicalConsoleMessageRecord
    package let query: CanonicalConsoleMessageQueryProjection
}

/// Complete Console/Runtime state built only for initial or reset publication.
package struct CanonicalConsoleRuntimeSnapshot: Equatable, Sendable {
    package let runtimeContexts: [CanonicalRuntimeContextSnapshotEntry]
    package let consoleMessages: [CanonicalConsoleMessageSnapshotEntry]
}
