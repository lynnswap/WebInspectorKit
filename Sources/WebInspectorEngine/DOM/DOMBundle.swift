@MainActor
public protocol DOMBundleSink: AnyObject {
    func domDidEmit(bundle: DOMBundle)
}

public struct DOMBundle {
    public enum Payload {
        case jsonString(String)
        case objectEnvelope(Any)
    }

    public let payload: Payload

    public init(rawJSON: String) {
        payload = .jsonString(rawJSON)
    }

    public init(objectEnvelope: Any) {
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
