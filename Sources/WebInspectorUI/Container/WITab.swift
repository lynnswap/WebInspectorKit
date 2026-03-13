import Foundation
import WebInspectorCore
import WebInspectorResources

#if canImport(UIKit)
import UIKit
import WebInspectorResources
public typealias WIPlatformImage = UIImage
public typealias WIPlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
import WebInspectorResources
public typealias WIPlatformImage = NSImage
public typealias WIPlatformViewController = NSViewController
#endif

@MainActor
public final class WITab: NSObject {
    public static let domTabID = "wi_dom"
    public static let elementTabID = "wi_element"
    public static let networkTabID = "wi_network"

    public typealias Role = WIPanelConfiguration.Role

    public typealias ViewControllerProvider = @MainActor (WITab) -> WIPlatformViewController

    public let configuration: WIPanelConfiguration
    public let identifier: String
    public let title: String
    public let image: WIPlatformImage?
    public let role: Role
    public let viewControllerProvider: ViewControllerProvider?
    public var userInfo: Any?

    public var id: String { identifier }
    public var panelKind: WIPanelKind { configuration.kind }

    public init(
        title: String,
        image: WIPlatformImage?,
        panelConfiguration: WIPanelConfiguration,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        configuration = panelConfiguration
        identifier = panelConfiguration.identifier
        self.title = title
        self.image = image
        role = panelConfiguration.role
        self.viewControllerProvider = viewControllerProvider
        self.userInfo = userInfo
        super.init()
    }

    public convenience init(
        panelKind: WIPanelKind,
        title: String,
        image: WIPlatformImage?,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            title: title,
            image: image,
            panelConfiguration: WIPanelConfiguration(kind: panelKind, role: role),
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    public convenience init(
        panelKind: WIPanelKind,
        title: String,
        systemImage: String,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            panelKind: panelKind,
            title: title,
            image: Self.systemImage(named: systemImage, accessibilityDescription: title),
            role: role,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    public convenience init(
        id: String,
        title: String,
        image: WIPlatformImage?,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            panelKind: Self.panelKind(for: id),
            title: title,
            image: image,
            role: role,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    public convenience init(
        id: String,
        title: String,
        systemImage: String,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            id: id,
            title: title,
            image: Self.systemImage(named: systemImage, accessibilityDescription: title),
            role: role,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    private static func systemImage(named name: String, accessibilityDescription: String?) -> WIPlatformImage? {
#if canImport(UIKit)
        UIImage(systemName: name)
#elseif canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
#else
        nil
#endif
    }

    private static func panelKind(for identifier: String) -> WIPanelKind {
        switch identifier {
        case domTabID:
            .domTree
        case elementTabID:
            .domDetail
        case networkTabID:
            .network
        default:
            .custom(identifier)
        }
    }

    static func projectedTabs(
        from panelConfigurations: [WIPanelConfiguration],
        reusing existingTabs: [WITab]
    ) -> [WITab] {
        var remainingTabs = existingTabs
        var projectedTabs: [WITab] = []
        projectedTabs.reserveCapacity(panelConfigurations.count)

        for panelConfiguration in panelConfigurations {
            if let exactIndex = remainingTabs.firstIndex(where: { $0.configuration == panelConfiguration }) {
                projectedTabs.append(remainingTabs.remove(at: exactIndex))
                continue
            }

            let reusableIndexes = remainingTabs.indices.filter { index in
                let tab = remainingTabs[index]
                return tab.configuration.identifier == panelConfiguration.identifier
                    && tab.panelKind == panelConfiguration.kind
            }
            if let reusableIndex = reusableIndexes.first {
                let reusableTab = remainingTabs.remove(at: reusableIndex)
                projectedTabs.append(
                    WITab(
                        title: reusableTab.title,
                        image: reusableTab.image,
                        panelConfiguration: panelConfiguration,
                        viewControllerProvider: reusableTab.viewControllerProvider,
                        userInfo: reusableTab.userInfo
                    )
                )
                continue
            }

            if let fallbackTab = fallbackTab(for: panelConfiguration) {
                projectedTabs.append(fallbackTab)
            }
        }

        return projectedTabs
    }

    private static func fallbackTab(for panelConfiguration: WIPanelConfiguration) -> WITab? {
        let fallbackTitle: String
        let fallbackSystemImage: String

        switch panelConfiguration.kind {
        case .domTree:
            fallbackTitle = wiLocalized("inspector.tab.dom")
            fallbackSystemImage = "chevron.left.forwardslash.chevron.right"
        case .domDetail:
            fallbackTitle = wiLocalized("inspector.tab.element")
            fallbackSystemImage = "info.circle"
        case .network:
            fallbackTitle = wiLocalized("inspector.tab.network")
            fallbackSystemImage = "waveform.path.ecg.rectangle"
        case .custom:
            return nil
        }

        return WITab(
            title: fallbackTitle,
            image: systemImage(named: fallbackSystemImage, accessibilityDescription: fallbackTitle),
            panelConfiguration: panelConfiguration
        )
    }
}
