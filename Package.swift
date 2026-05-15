// swift-tools-version: 6.2
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
            name: "WebInspectorKit",
            targets: ["WebInspectorKit"]
        ),
        .library(
            name: "WebInspectorUI",
            targets: ["WebInspectorUI"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/ObservationBridge.git",
            exact: "0.8.0"
        ),
        .package(
            url: "https://github.com/lynnswap/UIHostingMenu.git",
            exact: "0.1.4"
        ),
        .package(
            url: "https://github.com/lynnswap/SyntaxEditorUI.git",
            exact: "0.5.1"
        ),
        .package(
            url: "https://github.com/p-x9/MachOKit.git",
            exact: "0.49.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorCore",
            dependencies: [],
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
                "WebInspectorCore",
                "WebInspectorNativeBridge",
                "WebInspectorNativeSymbols"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorRuntime",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUI",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorRuntime",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS])),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
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
                "WebInspectorCore"
            ],
            path: "Tests/WebInspectorCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorTransportTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport"
            ],
            path: "Tests/WebInspectorTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorNativeSymbolsTests",
            dependencies: [
                "WebInspectorNativeSymbols"
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
            name: "WebInspectorRuntimeTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorRuntime"
            ],
            path: "Tests/WebInspectorRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorRuntime",
                "WebInspectorUI"
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        )
    ],
    cxxLanguageStandard: .gnucxx20
)
