import SwiftUI

public struct InspectorTab: Identifiable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let makeContent: (WIViewModel) -> AnyView

    public init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        @ViewBuilder content: @escaping (WIViewModel) -> some View
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.makeContent = { model in AnyView(content(model)) }
    }
}
