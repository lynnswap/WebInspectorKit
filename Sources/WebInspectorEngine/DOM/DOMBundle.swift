@MainActor
public protocol DOMBundleSink: AnyObject {
    func domDidEmit(bundle: DOMBundle)
}

public typealias DOMDocumentScopeID = UInt64

public struct DOMBundle {
    public enum Payload {
        case jsonString(String)
        case objectEnvelope(Any)
    }

    public let payload: Payload
    public let pageEpoch: Int?
    public let documentScopeID: DOMDocumentScopeID?

    public init(rawJSON: String, pageEpoch: Int? = nil, documentScopeID: DOMDocumentScopeID? = nil) {
        self.pageEpoch = pageEpoch
        self.documentScopeID = documentScopeID
        payload = .jsonString(rawJSON)
    }

    public init(objectEnvelope: Any, pageEpoch: Int? = nil, documentScopeID: DOMDocumentScopeID? = nil) {
        self.pageEpoch = pageEpoch
        self.documentScopeID = documentScopeID
        payload = .objectEnvelope(objectEnvelope)
    }

    public var rawJSON: String? {
        guard case let .jsonString(value) = payload else {
            return nil
        }
        return value
    }

    public var objectEnvelope: Any? {
        guard case let .objectEnvelope(value) = payload else {
            return nil
        }
        return value
    }
}
