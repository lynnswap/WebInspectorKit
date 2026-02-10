// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WebInspectorKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18), .macOS(.v15)
    ],
    products: [
        .library(
            name: "WebInspectorKitCore",
            targets: ["WebInspectorKitCore"]
        ),
        .library(
            name: "WebInspectorKit",
            targets: ["WebInspectorKit"]
        )
    ],
    targets: [
        .target(
            name: "WebInspectorKitCore",
            path: "Sources/WebInspectorKitCore",
            plugins: [
                .plugin(name: "WebInspectorKitObfuscatePlugin")
            ]
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorKitCore"
            ],
            path: "Sources/WebInspectorKit",
            resources: [
                .process("Localizable.xcstrings"),
                .process("WebInspector/Views/DOMTreeView/dom-tree-view.html"),
                .process("WebInspector/Views/DOMTreeView/dom-tree-view.css"),
                .process("WebInspector/Views/DOMTreeView/DisclosureTriangles.svg")
            ]
        ),
        .testTarget(
            name: "WebInspectorKitCoreTests",
            dependencies: ["WebInspectorKitCore"],
            path: "Tests/WebInspectorKitCoreTests"
        ),
        .testTarget(
            name: "WebInspectorKitUITests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorKitCore"
            ],
            path: "Tests/WebInspectorKitUITests"
        ),
        .plugin(
            name: "WebInspectorKitObfuscatePlugin",
            capability: .buildTool()
        )

    ]
)
