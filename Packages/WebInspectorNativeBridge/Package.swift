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
        .iOS("18.4"), .macOS("15.4")
    ],
    products: [
        .library(name: "WebKitRuntime", targets: ["WebKitRuntime", "WebKitRuntimeObjC"]),
        .library(
            name: "WebInspectorNativeBridge",
            targets: ["WebInspectorNativeBridge"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/p-x9/MachOKit.git",
            exact: "0.52.2"
        )
    ],
    targets: [
        .target(
            name: "WebKitRuntime",
            dependencies: ["WebKitRuntimeObjC", .product(name: "MachOKit", package: "MachOKit")],
            path: "Sources/WebKitRuntime",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WebKitRuntimeObjC",
            path: "Sources/WebKitRuntimeObjC",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("WebKit")]
        ),
        .target(
            name: "WebInspectorNativeBridge",
            dependencies: [
                "WebInspectorNativeBridgeObjC",
                "WebKitRuntime"
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridgeObjC",
            dependencies: ["WebKitRuntimeObjC"],
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
                "WebKitRuntime",
            ],
            path: "Tests/WebInspectorNativeBridgeTests",
            swiftSettings: swiftSettings
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
