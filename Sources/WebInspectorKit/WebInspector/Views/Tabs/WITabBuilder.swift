@resultBuilder
public enum WITabBuilder {
    public static func buildBlock(_ components: WITab...) -> [WITab] {
        components
    }

    public static func buildOptional(_ component: [WITab]?) -> [WITab] {
        component ?? []
    }

    public static func buildEither(first: [WITab]) -> [WITab] { first }
    public static func buildEither(second: [WITab]) -> [WITab] { second }

    public static func buildArray(_ components: [[WITab]]) -> [WITab] {
        components.flatMap { $0 }
    }
}
