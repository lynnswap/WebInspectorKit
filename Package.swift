// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WebInspectorKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),.macOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "WebInspectorKit",
            targets: ["WebInspectorKit"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "WebInspectorKit",
            path: "Sources/WebInspectorKit",
            resources: [
                .process("Localizable.xcstrings"),
                .process("WebInspector/Views/DOMTreeView"),
                .process("WebInspector/Support/DOMAgent.js"),
                .process("WebInspector/Support/NetworkAgent.js"),
                .process("WebInspector/Support/DOMAgent"),
                .process("WebInspector/Support/NetworkAgent")
            ]
        ),
        .testTarget(
            name: "WebInspectorKitTests",
            dependencies: ["WebInspectorKit"]
        ),

    ]
)
