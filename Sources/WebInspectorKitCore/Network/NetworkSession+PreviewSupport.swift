#if DEBUG
import Foundation

@_spi(PreviewSupport)
public extension NetworkSession {
    func wiApplyPreviewBatch(_ payload: [String: Any]) {
        guard let batch = NetworkEventBatch.decode(from: payload) else {
            return
        }
        store.applyNetworkBatch(batch)
    }
}
#endif
