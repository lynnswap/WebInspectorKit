import SwiftUI

public struct WITab: Identifiable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let makeContent: () -> AnyView

    public init(
        _ title: LocalizedStringResource,
        systemImage: String,
        value: String? = nil,
        @ViewBuilder content: @escaping () -> some View
    ) {
        if let value{
            self.id = value
        }else{
            self.id = title.key
        }
        self.title = title
        self.systemImage = systemImage
        self.makeContent = { AnyView(content()) }
    }
}
