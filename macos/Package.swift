// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mdwrite",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditorCore", targets: ["EditorCore"])
    ],
    targets: [
        .target(name: "EditorCore", path: "EditorCore"),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"], path: "Tests/EditorCoreTests")
    ]
)
