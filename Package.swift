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
        ),
        .library(
            name: "WebInspectorKitSPI",
            targets: ["WebInspectorKitSPI"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/ObservationBridge.git",
            exact: "0.6.1"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOKit.git",
            revision: "f5d856c6b7c04d43a8a023e5eb8e4dabd0ef65e1"
        ),
        .package(
            url: "https://github.com/lynnswap/WKViewportCoordinator.git",
            exact: "0.1.3"
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
            name: "WebInspectorRuntime",
            dependencies: [
                "WebInspectorEngine",
                "WebInspectorTransport",
                "WebInspectorBridge",
                "WebInspectorScripts",
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
            name: "WebInspectorScriptsGenerated",
            path: "Generated/WebInspectorScriptsGenerated",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorScripts",
            dependencies: [
                "WebInspectorScriptsGenerated"
            ],
            exclude: [
                "TypeScript"
            ],
            resources: [
                .process("Resources/DOMTreeView")
            ],
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
                .product(name: "ObservationBridge", package: "ObservationBridge")
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
                "WebInspectorRuntime",
                "WebInspectorBridge",
                "WebInspectorScripts"
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
                .product(name: "WKViewportCoordinator", package: "WKViewportCoordinator"),
                "WebInspectorUI",
                "WebInspectorRuntime",
                "WebInspectorEngine",
                "WebInspectorBridge",
                "WebInspectorTestSupport"
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
            name: "WebInspectorScriptsTests",
            dependencies: [
                "WebInspectorScripts"
            ],
            path: "Tests/WebInspectorScriptsTests",
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
