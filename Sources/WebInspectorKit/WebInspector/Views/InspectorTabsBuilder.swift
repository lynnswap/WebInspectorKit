@resultBuilder
public enum InspectorTabsBuilder {
    public static func buildBlock(_ components: InspectorTab...) -> [InspectorTab] {
        components
    }

    public static func buildOptional(_ component: [InspectorTab]?) -> [InspectorTab] {
        component ?? []
    }

    public static func buildEither(first: [InspectorTab]) -> [InspectorTab] { first }
    public static func buildEither(second: [InspectorTab]) -> [InspectorTab] { second }

    public static func buildArray(_ components: [[InspectorTab]]) -> [InspectorTab] {
        components.flatMap { $0 }
    }
}
