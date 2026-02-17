#if canImport(UIKit)
@inline(__always)
func wiSecondaryActionSymbolName() -> String {
    if #available(iOS 26.0, *) {
        return "ellipsis"
    }
    return "ellipsis.circle"
}
#endif
