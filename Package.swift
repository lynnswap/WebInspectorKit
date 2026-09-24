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
        .iOS("18.4"), .macOS("15.4")
    ],
    products: [
        .library(name: "WebKitRuntime", targets: ["WebKitRuntime", "WebKitRuntimeObjC"]),
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
            name: "WebInspectorDataKitTesting",
            targets: ["WebInspectorDataKitTesting"]
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
            url: "https://github.com/lynnswap/ScrollableTabBar.git",
            exact: "0.1.3"
        ),
        .package(
            url: "https://github.com/lynnswap/UIHostingMenu.git",
            exact: "0.3.0"
        ),
        .package(
            url: "https://github.com/lynnswap/SyntaxEditorUI.git",
            exact: "0.16.5"
        ),
        .package(
            url: "https://github.com/lynnswap/ABIBridge.git",
            exact: "0.1.1"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "WebKitRuntime",
            dependencies: ["WebKitRuntimeObjC", .product(name: "ABIBridge", package: "ABIBridge")],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebKitRuntimeObjC",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("WebKit")]
        ),
        .target(
            name: "WebInspectorProxyKit",
            dependencies: [
                "WebInspectorNativeBridge"
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
            name: "WebInspectorDataKitTesting",
            dependencies: [
                "WebInspectorDataKit"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridge",
            dependencies: [
                "WebInspectorNativeBridgeObjC",
                "WebKitRuntime"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridgeObjC",
            dependencies: ["WebKitRuntimeObjC", .product(name: "ABIBridge", package: "ABIBridge")],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
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
                "WebInspectorProxyKit",
                "WebInspectorUIBase",
                .product(
                    name: "ScrollableTabBar",
                    package: "ScrollableTabBar",
                    condition: .when(platforms: [.iOS])
                ),
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS])),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorUIBase",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            exclude: [
                "README.md"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTestSupport",
            dependencies: [
                "WebInspectorProxyKit"
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
            name: "WebInspectorNativeBridgeTests",
            dependencies: ["WebInspectorNativeBridge", "WebInspectorNativeSymbolFixtures", "WebKitRuntime"],
            path: "Tests/WebInspectorNativeBridgeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorProxyKitTests",
            dependencies: [
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
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
                "WebInspectorProxyKit",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorDataKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
                "WebInspectorUIBase",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
                "WebInspectorKit",
                "WebInspectorTestSupport",
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        )
    ],
    cxxLanguageStandard: .gnucxx20
)
