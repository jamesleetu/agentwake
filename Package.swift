// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agentwake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "agentwake", path: "Sources/agentwake")
    ]
)
