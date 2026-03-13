// swift-tools-version: 6.2

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
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/ObservationBridge.git",
            exact: "0.6.0"
        ),
        .package(
            url: "https://github.com/p-x9/MachOKit",
            exact: "0.46.1"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorCore",
            dependencies: [
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Sources/WebInspectorCore",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorResources",
            path: "Sources/WebInspectorResources",
            resources: [
                .process("Resources")
            ],
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "WebInspectorKitObfuscatePlugin")
            ]
        ),
        .target(
            name: "WebInspectorTransport",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorResources",
                "WebInspectorTransportObjCShim",
                "WebInspectorSPIObjCShim",
                .product(name: "MachOKit", package: "MachOKit")
            ],
            path: "Sources/WebInspectorTransport",
            swiftSettings: strictSwiftSettings
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
            name: "WebInspectorSPIObjCShim",
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
                "WebInspectorCore",
                "WebInspectorResources",
                "WebInspectorSPIObjCShim",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Sources/WebInspectorUI",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorUI",
                "WebInspectorTransport",
                "WebInspectorResources"
            ],
            path: "Sources/WebInspectorKit",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTestSupport",
            dependencies: [
                "WebInspectorCore",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorTestSupport",
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
        .testTarget(
            name: "WebInspectorCoreTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorDOMTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorResources",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorDOMTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorNetworkTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorNetworkTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorShellTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorShellTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorIntegrationTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorIntegrationTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorIntegrationLongTests",
            dependencies: [
                "WebInspectorKit",
                "WebInspectorCore",
                "WebInspectorTransport",
                "WebInspectorUI",
                "WebInspectorTestSupport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Tests/WebInspectorIntegrationLongTests",
            swiftSettings: strictSwiftSettings
        ),
        .plugin(
            name: "WebInspectorKitObfuscatePlugin",
            capability: .buildTool()
        )
    ],
    cxxLanguageStandard: .gnucxx20
)
