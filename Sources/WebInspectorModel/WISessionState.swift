import Foundation

public struct WISessionState: Sendable, Equatable {
    public var selectedTabID: String?

    public init(
        selectedTabID: String? = nil
    ) {
        self.selectedTabID = selectedTabID
    }
}
