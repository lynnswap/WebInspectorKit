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
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .testTarget(
            name: "WebInspectorDataKitImportOnlyContractTests",
            dependencies: [
                .product(name: "WebInspectorDataKit", package: "WebInspectorKit"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorConsumerContractTests",
            dependencies: [
                .product(name: "WebInspectorDataKit", package: "WebInspectorKit"),
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
