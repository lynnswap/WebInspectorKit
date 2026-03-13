#if DEBUG
import Foundation

@_spi(PreviewSupport)
extension WINetworkStore {
    package func wiApplyPreviewBatch(_ payload: NSDictionary) {
        session.wiApplyPreviewBatch(payload)
    }
}
#endif
