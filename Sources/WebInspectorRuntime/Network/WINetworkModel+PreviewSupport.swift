#if DEBUG
import Foundation
@_spi(PreviewSupport) import WebInspectorEngine

@_spi(PreviewSupport)
public extension WINetworkModel {
    func wiApplyPreviewBatch(_ payload: NSDictionary) {
        session.wiApplyPreviewBatch(payload)
    }
}
#endif
