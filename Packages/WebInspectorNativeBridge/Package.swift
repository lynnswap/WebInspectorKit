// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "WebInspectorNativeBridge",
    platforms: [
        .iOS(.v18), .macOS(.v15)
    ],
    products: [
        .library(
            name: "WebInspectorNativeBridge",
            targets: ["WebInspectorNativeBridge"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/p-x9/MachOKit.git",
            exact: "0.51.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorNativeBridge",
            dependencies: [
                "WebInspectorNativeBridgeObjC",
                .product(name: "MachOKit", package: "MachOKit")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridgeObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WebInspectorNativeSymbolFixtures",
            path: "Tests/WebInspectorNativeSymbolFixtures",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "WebInspectorNativeBridgeTests",
            dependencies: [
                "WebInspectorNativeBridge",
                "WebInspectorNativeSymbolFixtures",
            ],
            path: "Tests/WebInspectorNativeBridgeTests",
            swiftSettings: swiftSettings
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
