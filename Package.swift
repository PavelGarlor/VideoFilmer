// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoFilmer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VideoFilmer", path: "Sources/VideoFilmer")
    ]
)
