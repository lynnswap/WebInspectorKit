import SwiftUI

extension View {
    func networkListRowStyle() -> some View {
        padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(networkListRowBackground)
            .scenePadding(.horizontal)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(.init())
    }

    @ViewBuilder
    var networkListRowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.15))
        }
    }
}

