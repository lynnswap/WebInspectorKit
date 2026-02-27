import Testing
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

struct NetworkBodyPreviewTreeMenuTests {
    @Test
    func propertyPathFormatsDotBracketAndIndexNotation() {
        let components: [NetworkBodyPreviewTreeMenuSupport.PathComponent] = [
            .init(key: "data", isIndex: false),
            .init(key: "threaded-conversation", isIndex: false),
            .init(key: "0", isIndex: true),
            .init(key: "user name", isIndex: false),
            .init(key: "say\"hi", isIndex: false)
        ]

        let path = NetworkBodyPreviewTreeMenuSupport.propertyPathString(from: components)
        #expect(path == #"this.data["threaded-conversation"][0]["user name"]["say\"hi"]"#)
    }

    @Test
    func scalarCopySupportsOnlyScalars() throws {
        let nodes = try makeRootNodes(
            from: """
            {"s":"text","n":42,"b":true,"z":null,"o":{"x":1},"a":[1,2]}
            """
        )

        #expect(NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: try node(forKey: "s", in: nodes)) == "text")
        #expect(NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: try node(forKey: "n", in: nodes)) == "42")
        #expect(NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: try node(forKey: "b", in: nodes)) == "true")
        #expect(NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: try node(forKey: "z", in: nodes)) == "null")
        #expect(NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: try node(forKey: "o", in: nodes)) == nil)
        #expect(NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: try node(forKey: "a", in: nodes)) == nil)
    }

    @Test
    func subtreeCopyFormatsJSONAndScalars() throws {
        let nodes = try makeRootNodes(
            from: """
            {"s":"text","n":42,"b":true,"z":null,"o":{"x":1},"a":[1,2]}
            """
        )

        let objectText = try #require(
            NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: try node(forKey: "o", in: nodes))
        )
        #expect(objectText.contains("\n"))
        #expect(objectText.contains("\"x\" : 1"))

        let arrayText = try #require(
            NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: try node(forKey: "a", in: nodes))
        )
        #expect(arrayText.contains("["))
        #expect(arrayText.contains("1"))
        #expect(arrayText.contains("2"))

        #expect(
            NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: try node(forKey: "s", in: nodes))
            == "\"text\""
        )
        #expect(
            NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: try node(forKey: "n", in: nodes))
            == "42"
        )
        #expect(
            NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: try node(forKey: "b", in: nodes))
            == "true"
        )
        #expect(
            NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: try node(forKey: "z", in: nodes))
            == "null"
        )
    }

    private func makeRootNodes(from json: String) throws -> [NetworkJSONNode] {
        try #require(NetworkJSONNode.nodes(from: json))
    }

    private func node(forKey key: String, in nodes: [NetworkJSONNode]) throws -> NetworkJSONNode {
        try #require(nodes.first(where: { $0.key == key }))
    }
}
