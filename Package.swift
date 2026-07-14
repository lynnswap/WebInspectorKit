// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "WebInspectorKit",
    defaultLocalization: "en",
    platforms: [
        .iOS("18.4"), .macOS("15.4")
    ],
    products: [
        .library(
            name: "WebInspectorProxyKit",
            targets: ["WebInspectorProxyKit"]
        ),
        .library(
            name: "WebInspectorProxyKitTesting",
            targets: ["WebInspectorProxyKitTesting"]
        ),
        .library(
            name: "WebInspectorDataKit",
            targets: ["WebInspectorDataKit"]
        ),
        .library(
            name: "WebInspectorDataKitTesting",
            targets: ["WebInspectorDataKitTesting"]
        ),
        .library(
            name: "WebInspectorSwiftUI",
            targets: ["WebInspectorSwiftUI"]
        ),
        .library(
            name: "WebInspectorKit",
            targets: ["WebInspectorKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/ObservationBridge.git",
            exact: "0.13.0"
        ),
        .package(
            url: "https://github.com/lynnswap/UIHostingMenu.git",
            exact: "0.2.0"
        ),
        .package(
            url: "https://github.com/lynnswap/SyntaxEditorUI.git",
            exact: "0.16.5"
        ),
        .package(
            url: "https://github.com/p-x9/MachOKit.git",
            exact: "0.51.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "603.0.2"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "WebInspectorProxyKit",
            dependencies: [
                "WebInspectorNativeBridge"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorProxyKitTesting",
            dependencies: [
                "WebInspectorProxyKit"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorDataKit",
            dependencies: [
                "WebInspectorProxyKit",
                "WebInspectorDataKitMacros",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .macro(
            name: "WebInspectorDataKitMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorDataKitTesting",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridge",
            dependencies: [
                "WebInspectorNativeBridgeObjC",
                .product(name: "MachOKit", package: "MachOKit")
            ],
            path: "Packages/WebInspectorNativeBridge/Sources/WebInspectorNativeBridge",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorNativeBridgeObjC",
            path: "Packages/WebInspectorNativeBridge/Sources/WebInspectorNativeBridgeObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WebInspectorUIBase",
            dependencies: [],
            resources: [
                .process("Localizable.xcstrings")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUIDOM",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorUIBase",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUINetwork",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorUIBase",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                .product(name: "UIHostingMenu", package: "UIHostingMenu", condition: .when(platforms: [.iOS])),
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorSwiftUI",
            dependencies: [
                "WebInspectorDataKit",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorUIPreviews",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorDataKitTesting",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorKit",
            dependencies: [
                "WebInspectorProxyKit",
                "WebInspectorDataKit",
                "WebInspectorUIBase",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "WebInspectorTestSupport",
            dependencies: [
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
            ],
            path: "Tests/WebInspectorTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorProxyKitTests",
            dependencies: [
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorProxyKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorDataKitTests",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorDataKitTesting",
                "WebInspectorProxyKitTesting",
                "WebInspectorProxyKit",
                "WebInspectorTestSupport"
            ],
            path: "Tests/WebInspectorDataKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorDataKitMacroTests",
            dependencies: [
                "WebInspectorDataKitMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/WebInspectorDataKitMacroTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorSwiftUITests",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorDataKitTesting",
                "WebInspectorSwiftUI",
            ],
            path: "Tests/WebInspectorSwiftUITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "WebInspectorUITests",
            dependencies: [
                "WebInspectorDataKit",
                "WebInspectorDataKitTesting",
                "WebInspectorProxyKit",
                "WebInspectorProxyKitTesting",
                "WebInspectorUIBase",
                "WebInspectorUIDOM",
                "WebInspectorUINetwork",
                "WebInspectorKit",
                "WebInspectorUIPreviews",
                "WebInspectorTestSupport",
                .product(name: "SyntaxEditorUI", package: "SyntaxEditorUI", condition: .when(platforms: [.iOS]))
            ],
            path: "Tests/WebInspectorUITests",
            swiftSettings: strictSwiftSettings
        )
    ],
    cxxLanguageStandard: .gnucxx20
)
