// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let webInspectorCoreExcludes: [String] = [
    "WebInspectorBridge",
    "WebInspectorEngine/DOM/DOMLegacyBundleNormalizer.swift",
    "WebInspectorEngine/DOM/DOMLegacyPageDriver.swift",
    "WebInspectorEngine/DOM/DOMPageDriving.swift",
    "WebInspectorEngine/DOM/DOMProtocolEventSink.swift",
    "WebInspectorEngine/DOM/DOMSelectionBridge.swift",
    "WebInspectorEngine/DOM/DOMSession.swift",
    "WebInspectorEngine/DOM/DOMTransportDriver.swift",
    "WebInspectorEngine/Network/NetworkLegacyPageDriver.swift",
    "WebInspectorEngine/Network/NetworkLegacyResourceLoadObserver.swift",
    "WebInspectorEngine/Network/NetworkPageDriving.swift",
    "WebInspectorEngine/Network/NetworkSession+PreviewSupport.swift",
    "WebInspectorEngine/Network/NetworkSession.swift",
    "WebInspectorEngine/Network/NetworkTransportDriver.swift",
    "WebInspectorKit",
    "WebInspectorRuntime/DOM",
    "WebInspectorRuntime/Network",
    "WebInspectorRuntime/Session/WIInspectorConfiguration.swift",
    "WebInspectorRuntime/Session/WIInspectorController.swift",
    "WebInspectorRuntime/Session/WIInspectorPanel.swift",
    "WebInspectorRuntime/Support",
    "WebInspectorScripts",
    "WebInspectorTransport",
    "WebInspectorTransportObjCShim",
    "WebInspectorUI",
]

let webInspectorDOMExcludes: [String] = [
    "WebInspectorBridge",
    "WebInspectorEngine/Common",
    "WebInspectorEngine/DOM/DOMConfiguration.swift",
    "WebInspectorEngine/DOM/DOMEntry.swift",
    "WebInspectorEngine/DOM/DOMGraphStore.swift",
    "WebInspectorEngine/DOM/DOMMatchedStyles.swift",
    "WebInspectorEngine/DOM/DOMSelectionCopyKind.swift",
    "WebInspectorEngine/DOM/DOMSelectionModeResult.swift",
    "WebInspectorEngine/Network",
    "WebInspectorEngine/Transport",
    "WebInspectorKit",
    "WebInspectorRuntime/Network",
    "WebInspectorRuntime/Session",
    "WebInspectorScripts",
    "WebInspectorTransport",
    "WebInspectorTransportObjCShim",
    "WebInspectorUI",
]

let webInspectorNetworkExcludes: [String] = [
    "WebInspectorBridge",
    "WebInspectorEngine/Common",
    "WebInspectorEngine/DOM",
    "WebInspectorEngine/Network/NetworkBody.swift",
    "WebInspectorEngine/Network/NetworkBodyPreviewData.swift",
    "WebInspectorEngine/Network/NetworkConfiguration.swift",
    "WebInspectorEngine/Network/NetworkEntry.swift",
    "WebInspectorEngine/Network/NetworkEventBatch.swift",
    "WebInspectorEngine/Network/NetworkHeaders.swift",
    "WebInspectorEngine/Network/NetworkJSONNode.swift",
    "WebInspectorEngine/Network/NetworkLoggingMode.swift",
    "WebInspectorEngine/Network/NetworkResourceFilter.swift",
    "WebInspectorEngine/Network/NetworkStore.swift",
    "WebInspectorEngine/Transport",
    "WebInspectorKit",
    "WebInspectorRuntime/DOM",
    "WebInspectorRuntime/Session",
    "WebInspectorRuntime/Support",
    "WebInspectorScripts",
    "WebInspectorTransport",
    "WebInspectorTransportObjCShim",
    "WebInspectorUI",
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
            name: "WebInspectorTransport",
            dependencies: [
                "WebInspectorTransportObjCShim",
                .product(name: "MachOKit", package: "MachOKit")
            ],
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
            name: "WebInspectorSPI",
            dependencies: [
                "WebInspectorSPIObjCShim"
            ],
            path: "Sources/WebInspectorBridge",
            exclude: ["ObjCShim"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorCore",
            dependencies: [
                "WebInspectorTransport"
            ],
            path: "Sources",
            exclude: webInspectorCoreExcludes,
            sources: [
                "WebInspectorEngine/Common",
                "WebInspectorEngine/Transport",
                "WebInspectorEngine/DOM/DOMConfiguration.swift",
                "WebInspectorEngine/DOM/DOMEntry.swift",
                "WebInspectorEngine/DOM/DOMGraphStore.swift",
                "WebInspectorEngine/DOM/DOMMatchedStyles.swift",
                "WebInspectorEngine/DOM/DOMSelectionCopyKind.swift",
                "WebInspectorEngine/DOM/DOMSelectionModeResult.swift",
                "WebInspectorEngine/Network/NetworkBody.swift",
                "WebInspectorEngine/Network/NetworkBodyPreviewData.swift",
                "WebInspectorEngine/Network/NetworkConfiguration.swift",
                "WebInspectorEngine/Network/NetworkEntry.swift",
                "WebInspectorEngine/Network/NetworkEventBatch.swift",
                "WebInspectorEngine/Network/NetworkHeaders.swift",
                "WebInspectorEngine/Network/NetworkJSONNode.swift",
                "WebInspectorEngine/Network/NetworkLoggingMode.swift",
                "WebInspectorEngine/Network/NetworkResourceFilter.swift",
                "WebInspectorEngine/Network/NetworkStore.swift",
                "WebInspectorRuntime/Session/WISessionLifecycle.swift",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorDOM",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorSPI",
                "WebInspectorScripts",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Sources",
            exclude: webInspectorDOMExcludes,
            sources: [
                "WebInspectorEngine/DOM/DOMLegacyBundleNormalizer.swift",
                "WebInspectorEngine/DOM/DOMLegacyPageDriver.swift",
                "WebInspectorEngine/DOM/DOMPageDriving.swift",
                "WebInspectorEngine/DOM/DOMProtocolEventSink.swift",
                "WebInspectorEngine/DOM/DOMSelectionBridge.swift",
                "WebInspectorEngine/DOM/DOMSession.swift",
                "WebInspectorEngine/DOM/DOMTransportDriver.swift",
                "WebInspectorRuntime/DOM",
                "WebInspectorRuntime/Support/WIAssets.swift",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorScripts",
            exclude: [
                "TypeScript/Tests"
            ],
            resources: [
                .process("Resources/DOMTreeView")
            ],
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "WebInspectorKitObfuscatePlugin")
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
            name: "WebInspectorNetwork",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorSPI",
                "WebInspectorScripts",
                "WebInspectorTransport",
                .product(name: "ObservationBridge", package: "ObservationBridge")
            ],
            path: "Sources",
            exclude: webInspectorNetworkExcludes,
            sources: [
                "WebInspectorEngine/Network/NetworkLegacyPageDriver.swift",
                "WebInspectorEngine/Network/NetworkLegacyResourceLoadObserver.swift",
                "WebInspectorEngine/Network/NetworkPageDriving.swift",
                "WebInspectorEngine/Network/NetworkSession.swift",
                "WebInspectorEngine/Network/NetworkSession+PreviewSupport.swift",
                "WebInspectorEngine/Network/NetworkTransportDriver.swift",
                "WebInspectorRuntime/Network",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorShell",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorTransport"
            ],
            path: "Sources/WebInspectorRuntime/Session",
            exclude: [
                "WISessionLifecycle.swift"
            ],
            sources: [
                "WIInspectorPanel.swift",
                "WIInspectorConfiguration.swift",
                "WIInspectorController.swift",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUI",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorShell",
                "WebInspectorSPI",
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
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorShell",
                "WebInspectorSPI",
                "WebInspectorScripts",
                "WebInspectorTransport"
            ],
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
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorDOMTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorTransport",
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
                "WebInspectorNetwork",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorNetworkTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorShellTests",
            dependencies: [
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorShell",
                "WebInspectorUI",
                "WebInspectorTransport",
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
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorShell",
                "WebInspectorUI",
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
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorShell",
                "WebInspectorTransport",
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
                "WebInspectorUI",
                "WebInspectorCore",
                "WebInspectorDOM",
                "WebInspectorNetwork",
                "WebInspectorShell",
                "WebInspectorTransport",
                "WebInspectorTestSupport"
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
