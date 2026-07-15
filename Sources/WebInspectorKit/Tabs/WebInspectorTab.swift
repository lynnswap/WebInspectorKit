#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUIBase

/// A tab shown by the built-in WebInspectorKit interface.
///
/// Built-in and app-provided tabs use the same registry entry. The factory is
/// invoked at most once at a time for a presentation resource. App-provided
/// factory failures remain visible until the user explicitly retries them.
@MainActor
public struct WebInspectorTab: Equatable, Hashable, Identifiable {
    /// Stable identity for an inspector tab.
    public struct ID: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public nonisolated init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// The stable resources made available to a tab factory.
    @MainActor
    public struct Context {
        public let session: WebInspectorSession
        public let modelContainer: WebInspectorModelContainer
        public let modelContext: WebInspectorModelContext

        package init(session: WebInspectorSession) {
            self.session = session
            self.modelContainer = session.modelContainer
            self.modelContext = session.modelContext
        }
    }

    public let id: ID
    public let title: String
    public let image: UIImage?
    public let requiredFeatures: Set<WebInspectorFeatureID>

    package let presentation: Presentation

    @MainActor
    package struct Presentation {
        package let displayItems: (HostLayout) -> [DisplayItem]
        package let descriptor: (DisplayItem) -> DisplayDescriptor?
        package let makeViewController: (
            DisplayItem,
            Context,
            PresentationContentStore,
            HostLayout
        ) -> UIViewController
    }

    public static nonisolated func == (
        lhs: WebInspectorTab,
        rhs: WebInspectorTab
    ) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Creates an app-provided inspector tab.
    public init(
        id: ID,
        title: String,
        image: UIImage? = nil,
        requiredFeatures: Set<WebInspectorFeatureID> = [],
        makeViewController: @escaping @MainActor (Context) async throws
            -> UIViewController
    ) {
        let descriptor = DisplayDescriptor(title: title, image: image)
        let displayItem = DisplayItem.tab(id)
        self.id = id
        self.title = title
        self.image = image
        self.requiredFeatures = requiredFeatures
        self.presentation = Presentation(
            displayItems: { _ in [displayItem] },
            descriptor: { item in item == displayItem ? descriptor : nil },
            makeViewController: { _, context, contentStore, layout in
                let viewController = contentStore.customViewController(
                    for: ContentKey(tabID: id, contentID: "root"),
                    context: context,
                    requiredFeatures: requiredFeatures,
                    makeViewController: makeViewController
                )
                switch layout {
                case .compact:
                    return viewController
                case .regular:
                    return RegularSplitRootViewController(
                        contentViewController: viewController
                    )
                }
            }
        )
    }

    /// Creates an app-provided inspector tab using an SF Symbols image.
    public init(
        id: ID,
        title: String,
        systemImage: String,
        requiredFeatures: Set<WebInspectorFeatureID> = [],
        makeViewController: @escaping @MainActor (Context) async throws
            -> UIViewController
    ) {
        self.init(
            id: id,
            title: title,
            image: UIImage(systemName: systemImage),
            requiredFeatures: requiredFeatures,
            makeViewController: makeViewController
        )
    }

    package init(
        id: ID,
        title: String,
        image: UIImage?,
        requiredFeatures: Set<WebInspectorFeatureID>,
        presentation: Presentation
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.requiredFeatures = requiredFeatures
        self.presentation = presentation
    }

    /// Built-in DOM and CSS inspector tab.
    public static let dom: WebInspectorTab = {
        let id = ID(rawValue: "webinspector_dom")
        let title = "DOM"
        let image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
        return WebInspectorTab(
            id: id,
            title: title,
            image: image,
            requiredFeatures: [.dom],
            presentation: Presentation(
                displayItems: { DOMTabController().displayItems(for: $0) },
                descriptor: { DOMTabController().descriptor(for: $0) },
                makeViewController: { item, context, store, layout in
                    DOMTabController().makeViewController(
                        for: item,
                        context: context,
                        contentStore: store,
                        layout: layout
                    )
                }
            )
        )
    }()

    /// Built-in Network inspector tab.
    public static let network: WebInspectorTab = {
        let id = ID(rawValue: "webinspector_network")
        let title = "Network"
        let image = UIImage(systemName: "waveform.path.ecg.rectangle")
        return WebInspectorTab(
            id: id,
            title: title,
            image: image,
            requiredFeatures: [.network],
            presentation: Presentation(
                displayItems: { NetworkTabController().displayItems(for: $0) },
                descriptor: { NetworkTabController().descriptor(for: $0) },
                makeViewController: { item, context, store, layout in
                    NetworkTabController().makeViewController(
                        for: item,
                        context: context,
                        contentStore: store,
                        layout: layout
                    )
                }
            )
        )
    }()
}

/// A validated registry of inspector tabs.
@MainActor
public struct WebInspectorTabCatalog {
    package let tabs: [WebInspectorTab]
    package let tabByID: [WebInspectorTab.ID: WebInspectorTab]

    public static let standard = WebInspectorTabCatalog(
        validatedTabs: [.dom, .network]
    )

    public init(_ tabs: [WebInspectorTab]) throws {
        guard tabs.isEmpty == false else {
            throw WebInspectorTabCatalogError.empty
        }

        var tabByID: [WebInspectorTab.ID: WebInspectorTab] = [:]
        for tab in tabs {
            guard tabByID.updateValue(tab, forKey: tab.id) == nil else {
                throw WebInspectorTabCatalogError.duplicateID(tab.id)
            }
        }
        self.tabs = tabs
        self.tabByID = tabByID
    }

    private init(validatedTabs tabs: [WebInspectorTab]) {
        self.tabs = tabs
        self.tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    }
}

public enum WebInspectorTabCatalogError: Error, Equatable, Sendable {
    case empty
    case duplicateID(WebInspectorTab.ID)
}
#endif
