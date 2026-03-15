import Foundation

package enum NetworkDeferredBodyLocator {
    case networkRequest(id: String, targetIdentifier: String?)
    case pageResource(targetIdentifier: String?, frameID: String, url: String)
    case opaqueHandle(AnyObject)
}
