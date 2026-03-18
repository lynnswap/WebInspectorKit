import Foundation

package enum NetworkDeferredBodyLocator: Equatable {
    case networkRequest(id: String, targetIdentifier: String?)
    case pageResource(targetIdentifier: String?, frameID: String, url: String)
    case opaqueHandle(AnyObject)

    package static func == (lhs: NetworkDeferredBodyLocator, rhs: NetworkDeferredBodyLocator) -> Bool {
        switch (lhs, rhs) {
        case let (.networkRequest(lhsID, lhsTargetIdentifier), .networkRequest(rhsID, rhsTargetIdentifier)):
            lhsID == rhsID && lhsTargetIdentifier == rhsTargetIdentifier
        case let (
            .pageResource(lhsTargetIdentifier, lhsFrameID, lhsURL),
            .pageResource(rhsTargetIdentifier, rhsFrameID, rhsURL)
        ):
            lhsTargetIdentifier == rhsTargetIdentifier
                && lhsFrameID == rhsFrameID
                && lhsURL == rhsURL
        case let (.opaqueHandle(lhsHandle), .opaqueHandle(rhsHandle)):
            ObjectIdentifier(lhsHandle) == ObjectIdentifier(rhsHandle)
        default:
            false
        }
    }
}

package extension NetworkDeferredBodyLocator {
    var reference: String? {
        switch self {
        case .networkRequest(let id, _):
            id
        case .pageResource, .opaqueHandle:
            nil
        }
    }

    var handle: AnyObject? {
        switch self {
        case .opaqueHandle(let handle):
            handle
        case .networkRequest, .pageResource:
            nil
        }
    }
}
