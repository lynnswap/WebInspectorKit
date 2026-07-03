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
            name: "WebInspectorConsumerContractTests",
            dependencies: [
                .product(name: "WebViewDataKit", package: "WebInspectorKit"),
                .product(name: "WebViewProxyKit", package: "WebInspectorKit"),
                .product(name: "WebViewProxyKitTesting", package: "WebInspectorKit"),
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
