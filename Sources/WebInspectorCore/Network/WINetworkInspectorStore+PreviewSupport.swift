#if DEBUG
import Foundation

@_spi(PreviewSupport)
extension WINetworkInspectorStore {
    package func wiApplyPreviewBatch(_ payload: NSDictionary) {
        session.wiApplyPreviewBatch(payload)
    }
}
#endif
