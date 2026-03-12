#if DEBUG
import Foundation

@_spi(PreviewSupport)
extension WINetworkRuntime {
    func wiApplyPreviewBatch(_ payload: NSDictionary) {
        guard let batch = NetworkEventBatch.decode(from: payload) else {
            return
        }
        store.applyNetworkBatch(batch)
    }
}
#endif
