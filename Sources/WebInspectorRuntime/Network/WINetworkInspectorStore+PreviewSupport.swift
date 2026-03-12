#if DEBUG
import Foundation
@_spi(PreviewSupport) import WebInspectorCore

@_spi(PreviewSupport)
public extension WINetworkInspectorStore {
    func wiApplyPreviewBatch(_ payload: NSDictionary) {
        session.wiApplyPreviewBatch(payload)
    }
}
#endif
