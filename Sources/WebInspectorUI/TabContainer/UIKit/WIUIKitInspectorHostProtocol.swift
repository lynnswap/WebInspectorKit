#if canImport(UIKit)
import UIKit

@MainActor
protocol WIUIKitInspectorHostProtocol: AnyObject {
    var onSelectedTabIDChange: ((WITabDescriptor.ID) -> Void)? { get set }

    func setTabDescriptors(_ descriptors: [WITabDescriptor], context: WITabContext)
    func setSelectedTabID(_ tabID: WITabDescriptor.ID?)
    func prepareForRemoval()
}
#endif
