import Foundation

package struct WebInspectorLifecycleTarget: Sendable {
    package let id: WebInspectorTarget.ID
    package let kind: WebInspectorTarget.Kind
    package let frameID: FrameID?
    package let isProvisional: Bool

    package init(
        id: WebInspectorTarget.ID,
        kind: WebInspectorTarget.Kind,
        frameID: FrameID?,
        isProvisional: Bool
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.isProvisional = isProvisional
    }

    init?(semanticID: WebInspectorTarget.ID, record: ProtocolTarget.Record) {
        guard let kind = WebInspectorTarget.Kind(protocolKind: record.kind) else {
            return nil
        }
        self.init(
            id: semanticID,
            kind: kind,
            frameID: record.frameID.map { FrameID($0.rawValue) },
            isProvisional: record.isProvisional
        )
    }
}

package struct WebInspectorTargetCommitLifecycle: Sendable {
    package let oldTargetID: WebInspectorTarget.ID?
    package let newTarget: WebInspectorLifecycleTarget

    package init(oldTargetID: WebInspectorTarget.ID?, newTarget: WebInspectorLifecycleTarget) {
        self.oldTargetID = oldTargetID
        self.newTarget = newTarget
    }
}

package struct WebInspectorPageFrameLifecycle: Sendable {
    package let id: FrameID
    package let parentID: FrameID?
    package let loaderID: String?
    package let name: String?
    package let url: String
    package let securityOrigin: String?
    package let mimeType: String?

    package init(
        id: FrameID,
        parentID: FrameID?,
        loaderID: String?,
        name: String?,
        url: String,
        securityOrigin: String?,
        mimeType: String?
    ) {
        self.id = id
        self.parentID = parentID
        self.loaderID = loaderID
        self.name = name
        self.url = url
        self.securityOrigin = securityOrigin
        self.mimeType = mimeType
    }
}

package enum WebInspectorTargetLifecycleEvent: Sendable {
    case didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle)
    case targetDestroyed(targetID: WebInspectorTarget.ID)
    case frameNavigated(WebInspectorPageFrameLifecycle)
    case frameDetached(frameID: FrameID)
    case unknown(RawEvent)
}

extension WebInspectorTarget.Kind {
    init?(protocolKind: ProtocolTarget.Kind) {
        switch protocolKind {
        case .page:
            self = .page
        case .frame:
            self = .frame
        case .worker:
            self = .worker
        case .serviceWorker:
            self = .serviceWorker
        case .other:
            return nil
        }
    }
}
