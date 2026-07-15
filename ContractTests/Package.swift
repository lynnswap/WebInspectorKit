// swift-tools-version: 6.3

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "WebInspectorKitContractTests",
    platforms: [
        .iOS("18.4"),
        .macOS("15.4"),
    ],
    dependencies: [
        .package(name: "WebInspectorKit", path: "..")
    ],
    targets: [
        .testTarget(
            name: "WebInspectorDataKitImportOnlyContractTests",
            dependencies: [
                .product(name: "WebInspectorDataKit", package: "WebInspectorKit")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorConsumerContractTests",
            dependencies: [
                .product(name: "WebInspectorDataKit", package: "WebInspectorKit"),
                .product(name: "WebInspectorDataKitTesting", package: "WebInspectorKit"),
                .product(name: "WebInspectorProxyKit", package: "WebInspectorKit"),
                .product(name: "WebInspectorProxyKitTesting", package: "WebInspectorKit"),
                .product(
                    name: "WebInspectorKit",
                    package: "WebInspectorKit",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            swiftSettings: strictSwiftSettings
        ),
    ]
)
