// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SoNovelMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SoNovel", targets: ["SoNovelApp"])],
    targets: [
        .target(name: "SoNovelCore"),
        .executableTarget(name: "SoNovelApp", dependencies: ["SoNovelCore"]),
        .testTarget(name: "SoNovelCoreTests", dependencies: ["SoNovelCore"])
    ]
)
