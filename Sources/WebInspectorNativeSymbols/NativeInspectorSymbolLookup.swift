#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func resolvedAddress(from candidates: Set<UInt64>, outsideTextAddress: UInt64?) -> ResolvedNativeInspectorAddress {
        if candidates.count == 1, let address = candidates.first {
            return .found(address)
        }
        if candidates.count > 1 {
            return .ambiguous
        }
        if let outsideTextAddress {
            return .outsideText(outsideTextAddress)
        }
        return .missing
    }
}
#endif
