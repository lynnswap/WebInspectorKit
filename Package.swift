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
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/ObservationsCompat.git",
            exact: "0.1.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorKitCore",
            dependencies: [
                "WebInspectorKitSPIObjC",
            ],
            path: "WebInspectorKit/Sources/WebInspectorKitCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
                .treatAllWarnings(as: .error),
            ],
            plugins: [
                .plugin(name: "WebInspectorKitObfuscatePlugin")
            ]
        ),
        .target(
            name: "WebInspectorKitSPIObjC",
            path: "WebInspectorKit/Sources/WebInspectorKitSPIObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorKitCore",
                "WebInspectorKitSPIObjC",
                .product(name: "ObservationsCompat", package: "ObservationsCompat")
            ],
            path: "WebInspectorKit/Sources/WebInspectorKit",
            resources: [
                .process("Localizable.xcstrings"),
                .process("WebInspector/Views/DOMTreeView/dom-tree-view.html"),
                .process("WebInspector/Views/DOMTreeView/dom-tree-view.css"),
                .process("WebInspector/Views/DOMTreeView/DisclosureTriangles.svg")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "WebInspectorKitTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorKitCore"
            ],
            path: "WebInspectorKit/Tests",
            sources: [
                "WebInspectorKitCoreTests",
                "WebInspectorKitFeatureTests"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
                .treatAllWarnings(as: .error),
            ]
        ),
        .plugin(
            name: "WebInspectorKitObfuscatePlugin",
            capability: .buildTool(),
            path: "WebInspectorKit/Plugins/WebInspectorKitObfuscatePlugin"
        )

    ]
)
