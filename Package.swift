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
            name: "WebInspectorEngine",
            targets: ["WebInspectorEngine"]
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
            name: "WebInspectorUI",
            targets: ["WebInspectorUI"]
        ),
        .library(
            name: "WebInspectorKit",
            targets: ["WebInspectorKit"]
        ),
        .library(
            name: "WebInspectorKitSPI",
            targets: ["WebInspectorKitSPI"]
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
            name: "WebInspectorEngine",
            dependencies: [
                "WebInspectorBridge",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorRuntime",
            dependencies: [
                "WebInspectorEngine",
                "WebInspectorTransport",
                "WebInspectorBridge",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorBridge",
            dependencies: [
                "WebInspectorBridgeObjCShim",
                .product(name: "MachOKit", package: "MachOKit")
            ],
            exclude: ["ObjCShim"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTransport",
            dependencies: [
                "WebInspectorEngine",
                "WebInspectorTransportObjCShim",
                .product(name: "MachOKit", package: "MachOKit")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "V2_WebInspectorCore",
            dependencies: [],
            exclude: ["README.md", "Docs"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "V2_WebInspectorTransport",
            dependencies: [
                "V2_WebInspectorCore",
                "V2_WebInspectorNativeBridge",
                "V2_WebInspectorNativeSymbols"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "V2_WebInspectorNativeSymbols",
            dependencies: [
                .product(name: "MachOKit", package: "MachOKit")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "V2_WebInspectorRuntime",
            dependencies: [
                "V2_WebInspectorCore",
                "V2_WebInspectorTransport"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "V2_WebInspectorUI",
            dependencies: [
                "V2_WebInspectorCore",
                "V2_WebInspectorRuntime",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS])),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "V2_WebInspectorNativeBridge",
            path: "Sources/V2_WebInspectorNativeBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
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
            name: "WebInspectorTransportObjCShim",
            path: "Sources/WebInspectorTransportObjCShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WebInspectorUI",
            dependencies: [
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorBridge",
                "WebInspectorBridgeObjCShim",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS])),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            exclude: [
                "Docs"
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .process("Resources/Preview")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorUI",
                "WebInspectorEngine",
                "WebInspectorRuntime",
                "WebInspectorBridge"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKitSPI",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorBridge",
                "WebInspectorBridgeObjCShim"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTestSupport",
            dependencies: [
                "WebInspectorEngine",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorEngineTests",
            dependencies: [
                "WebInspectorEngine",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorEngineTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorTransportTests",
            dependencies: [
                "WebInspectorTransport",
                "WebInspectorEngine",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "V2_WebInspectorCoreTests",
            dependencies: [
                "V2_WebInspectorCore"
            ],
            path: "Tests/V2_WebInspectorCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "V2_WebInspectorTransportTests",
            dependencies: [
                "V2_WebInspectorCore",
                "V2_WebInspectorTransport"
            ],
            path: "Tests/V2_WebInspectorTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "V2_WebInspectorNativeSymbolsTests",
            dependencies: [
                "V2_WebInspectorNativeSymbols"
            ],
            path: "Tests/V2_WebInspectorNativeSymbolsTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "V2_WebInspectorNativeBridgeTests",
            dependencies: [
                "V2_WebInspectorNativeBridge"
            ],
            path: "Tests/V2_WebInspectorNativeBridgeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "V2_WebInspectorRuntimeTests",
            dependencies: [
                "V2_WebInspectorCore",
                "V2_WebInspectorTransport",
                "V2_WebInspectorRuntime"
            ],
            path: "Tests/V2_WebInspectorRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorRuntimeTests",
            dependencies: [
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorUI",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorUI",
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorBridge",
                "WebInspectorTestSupport",
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorIntegrationTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorUI",
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorIntegrationTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorIntegrationLongTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorUI",
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorIntegrationLongTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorSPITests",
            dependencies: [
                "WebInspectorKitSPI",
                "WebInspectorBridge",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorSPITests",
            swiftSettings: strictSwiftSettings
        )

    ],
    cxxLanguageStandard: .gnucxx20
)
