#if canImport(UIKit)
@MainActor
struct V2_WIDisplayContentKey: Hashable {
    let definitionID: V2_WITabDefinition.ID
    let contentID: String
}
#endif
