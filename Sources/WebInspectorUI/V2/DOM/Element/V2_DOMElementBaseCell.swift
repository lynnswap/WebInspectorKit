#if canImport(UIKit)
import ObservationBridge
import UIKit

class V2_DOMElementBaseCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []

    override func prepareForReuse() {
        super.prepareForReuse()
        resetObservationHandles()
    }

    func resetObservationHandles() {
        observationHandles.removeAll()
    }

    func store(_ observationHandle: ObservationHandle) {
        observationHandle.store(in: &observationHandles)
    }

    static var monospacedFootnoteFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
    }
}
#endif
