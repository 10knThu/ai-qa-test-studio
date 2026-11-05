// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIQATestStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIQATestStudio",
            path: "Sources/AIQATestStudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AIQATestStudioTests",
            dependencies: ["AIQATestStudio"],
            path: "Tests/AIQATestStudioTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
