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
            name: "WebInspectorCore",
            targets: ["WebInspectorCore"]
        ),
        .library(
            name: "WebInspectorNativeBridge",
            targets: ["WebInspectorNativeBridge"]
        ),
        .library(
            name: "WebInspectorNativeSymbols",
            targets: ["WebInspectorNativeSymbols"]
        ),
        .library(
            name: "WebInspectorTransport",
            targets: ["WebInspectorTransport"]
        ),
        .library(
            name: "WebInspectorUI",
            targets: ["WebInspectorUI"]
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
            exact: "0.16.1"
        ),
        .package(
            url: "https://github.com/p-x9/MachOKit.git",
            exact: "0.50.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorCore",
            dependencies: [
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            exclude: ["README.md", "Docs"],
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
            dependencies: [
                "WebInspectorNativeBridge",
                "WebInspectorNativeSymbols"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUI",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS])),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            exclude: [
                "Docs"
            ],
            resources: [
                .process("Localizable.xcstrings")
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
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        )
    ],
    cxxLanguageStandard: .gnucxx20
)
