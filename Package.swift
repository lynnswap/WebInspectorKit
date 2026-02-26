// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "WebInspectorKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18), .macOS(.v15)
    ],
    products: [
        .library(
            name: "WebInspectorEngine",
            targets: ["WebInspectorEngine"]
        ),
        .library(
            name: "WebInspectorModel",
            targets: ["WebInspectorModel"]
        ),
        .library(
            name: "WebInspectorRuntime",
            targets: ["WebInspectorRuntime"]
        ),
        .library(
            name: "WebInspectorBridge",
            targets: ["WebInspectorBridge"]
        ),
        .library(
            name: "WebInspectorScripts",
            targets: ["WebInspectorScripts"]
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
            url: "https://github.com/lynnswap/ObservationsCompat.git",
            exact: "0.3.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorEngine",
            dependencies: [
                "WebInspectorBridge",
                "WebInspectorScripts",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorModel",
            dependencies: [
                "WebInspectorEngine"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorRuntime",
            dependencies: [
                "WebInspectorModel",
                "WebInspectorEngine",
                "WebInspectorBridge",
                "WebInspectorScripts",
                .product(name: "ObservationsCompat", package: "ObservationsCompat")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorBridge",
            dependencies: [
                "WebInspectorBridgeObjCShim"
            ],
            exclude: ["ObjCShim"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorScripts",
            resources: [
                .process("Resources/DOMTreeView")
            ],
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "WebInspectorKitObfuscatePlugin")
            ],
        ),
        .target(
            name: "WebInspectorBridgeObjCShim",
            path: "Sources/WebInspectorBridge/ObjCShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WebInspectorUI",
            dependencies: [
                "WebInspectorModel",
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorBridge",
                .product(name: "ObservationsCompat", package: "ObservationsCompat")
            ],
            resources: [
                .process("Localizable.xcstrings")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorUI",
                "WebInspectorEngine",
                "WebInspectorModel",
                "WebInspectorRuntime",
                "WebInspectorBridge",
                "WebInspectorScripts"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorKitTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorUI",
                "WebInspectorEngine",
                "WebInspectorModel",
                "WebInspectorRuntime",
                "WebInspectorBridge",
                "WebInspectorScripts"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .plugin(
            name: "WebInspectorKitObfuscatePlugin",
            capability: .buildTool()
        )

    ]
)
