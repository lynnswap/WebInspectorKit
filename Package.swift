// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "WebInspectorKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18), .macOS(.v15)
    ],
    products: [
        .library(
            name: "WebInspectorProxyKit",
            targets: ["WebInspectorProxyKit"]
        ),
        .library(
            name: "WebInspectorProxyKitTesting",
            targets: ["WebInspectorProxyKitTesting"]
        ),
        .library(
            name: "WebInspectorDataKit",
            targets: ["WebInspectorDataKit"]
        ),
        .library(
            name: "WebInspectorKit",
            targets: ["WebInspectorKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/ObservationBridge.git",
            exact: "0.13.0"
        ),
        .package(
            url: "https://github.com/lynnswap/UIHostingMenu.git",
            exact: "0.2.0"
        ),
        .package(
            url: "https://github.com/lynnswap/SyntaxEditorUI.git",
            exact: "0.16.3"
        ),
        .package(
            url: "https://github.com/p-x9/MachOKit.git",
            exact: "0.51.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorProxyKit",
            dependencies: [
                "WebInspectorNativeTransport",
                "WebInspectorTransport"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorProxyKitTesting",
            dependencies: [
                "WebInspectorProxyKit"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorDataKit",
            dependencies: [
                "WebInspectorProxyKit"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorCore",
            dependencies: [
                "WebInspectorCoreSupport",
                "WebInspectorCoreRuntime",
                "WebInspectorCoreDOMCSS",
                "WebInspectorCoreConsoleNetwork",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            exclude: ["README.md", "Docs"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorCoreSupport",
            dependencies: [
                "WebInspectorTransport"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorCoreRuntime",
            dependencies: [
                "WebInspectorCoreSupport",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorCoreDOMCSS",
            dependencies: [
                "WebInspectorCoreSupport",
                "WebInspectorCoreRuntime",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorCoreConsoleNetwork",
            dependencies: [
                "WebInspectorCoreSupport",
                "WebInspectorCoreRuntime",
                "WebInspectorCoreDOMCSS",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WebInspectorNativeSymbols",
            dependencies: [
                .product(name: "MachOKit", package: "MachOKit")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTransport",
            dependencies: [],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeTransport",
            dependencies: [
                "WebInspectorTransport",
                "WebInspectorNativeBridge",
                "WebInspectorNativeSymbols"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUIBase",
            dependencies: [],
            resources: [
                .process("Localizable.xcstrings")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUIDOM",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorProxyKit",
                "WebInspectorUIBase",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUINetwork",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorTransport",
                "WebInspectorUIBase",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUISyntaxBody",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorProxyKit",
                "WebInspectorUIBase",
                "WebInspectorUINetwork",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUI",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorUIBase",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
                "WebInspectorUISyntaxBody",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            exclude: [
                "Docs"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorUI"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorCoreTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorCoreSupport",
                "WebInspectorCoreRuntime",
                "WebInspectorCoreDOMCSS",
                "WebInspectorCoreConsoleNetwork",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorTransportTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorCoreSupport",
                "WebInspectorCoreRuntime",
                "WebInspectorCoreDOMCSS",
                "WebInspectorCoreConsoleNetwork",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTestSupport",
            dependencies: [
                "WebInspectorTransport"
            ],
            path: "Tests/WebInspectorTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeSymbolFixtures",
            path: "Tests/WebInspectorNativeSymbolFixtures",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "WebInspectorNativeSymbolsTests",
            dependencies: [
                "WebInspectorNativeSymbols",
                "WebInspectorNativeSymbolFixtures"
            ],
            path: "Tests/WebInspectorNativeSymbolsTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorNativeBridgeTests",
            dependencies: [
                "WebInspectorNativeBridge"
            ],
            path: "Tests/WebInspectorNativeBridgeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorNativeTransportTests",
            dependencies: [
                "WebInspectorNativeTransport"
            ],
            path: "Tests/WebInspectorNativeTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorProxyKitTests",
            dependencies: [
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorProxyKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorDataKitTests",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorProxyKitTesting",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorDataKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorDataKit",
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
                "WebInspectorTransport",
                "WebInspectorUIBase",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
                "WebInspectorUISyntaxBody",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        )
    ],
    cxxLanguageStandard: .gnucxx20
)
