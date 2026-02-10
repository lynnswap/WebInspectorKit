extension WebInspector {
    @resultBuilder
    public enum TabBuilder {
        public static func buildBlock(_ components: [Tab]...) -> [Tab] {
            components.flatMap { $0 }
        }

        public static func buildExpression(_ expression: Tab) -> [Tab] {
            [expression]
        }

        public static func buildExpression(_ expression: [Tab]) -> [Tab] {
            expression
        }

        public static func buildOptional(_ component: [Tab]?) -> [Tab] {
            component ?? []
        }

        public static func buildEither(first component: [Tab]) -> [Tab] {
            component
        }

        public static func buildEither(second component: [Tab]) -> [Tab] {
            component
        }

        public static func buildArray(_ components: [[Tab]]) -> [Tab] {
            components.flatMap { $0 }
        }
    }
}

