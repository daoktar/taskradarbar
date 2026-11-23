// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "taskradarbar",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "taskradarbar", path: "Sources")]
)
