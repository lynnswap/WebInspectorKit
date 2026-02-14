import SwiftUI
import WebInspectorKitCore

private struct NetworkInspectorToolbarModifier: ViewModifier {
    let inspector: WebInspector.NetworkInspector

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: inspector.bindingForAllResourceFilters()) {
                        Text(NetworkResourceFilter.all.localizedTitle)
                    }
                    Divider()
                    ForEach(NetworkResourceFilter.pickerCases) { filter in
                        Toggle(isOn: inspector.bindingForResourceFilter(filter)) {
                            Text(filter.localizedTitle)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(inspector.effectiveResourceFilters.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                        .accessibilityLabel(
                            Text(LocalizedStringResource("network.controls.filter", bundle: .module))
                        )
                }
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst) || os(visionOS)
                .menuActionDismissBehavior(.disabled)
#endif
                .menuOrder(.fixed)
            }
            ToolbarItem(placement: .secondaryAction) {
                Section {
                    Button(role: .destructive) {
                        inspector.clear()
                    } label: {
                        Label {
                            Text(LocalizedStringResource("network.controls.clear", bundle: .module))
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(inspector.store.entries.isEmpty)
                }
            }
        }
    }
}

private extension NetworkResourceFilter {
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .all:
            return LocalizedStringResource("network.filter.all", bundle: .module)
        case .document:
            return LocalizedStringResource("network.filter.document", bundle: .module)
        case .stylesheet:
            return LocalizedStringResource("network.filter.stylesheet", bundle: .module)
        case .image:
            return LocalizedStringResource("network.filter.image", bundle: .module)
        case .font:
            return LocalizedStringResource("network.filter.font", bundle: .module)
        case .script:
            return LocalizedStringResource("network.filter.script", bundle: .module)
        case .xhrFetch:
            return LocalizedStringResource("network.filter.xhr_fetch", bundle: .module)
        case .other:
            return LocalizedStringResource("network.filter.other", bundle: .module)
        }
    }
}

extension View {
    func networkInspectorToolbar(_ inspector: WebInspector.NetworkInspector) -> some View {
        modifier(NetworkInspectorToolbarModifier(inspector: inspector))
    }
}

