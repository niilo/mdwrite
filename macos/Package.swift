// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mdwrite",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .executable(name: "mdwriteApp", targets: ["mdwriteApp"])
    ],
    targets: [
        .target(name: "EditorCore", path: "EditorCore"),
        .executableTarget(name: "mdwriteApp", dependencies: ["EditorCore"], path: "NativeApp"),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"], path: "Tests/EditorCoreTests")
    ]
)
