// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Shiftlist",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Shiftlist", path: "Sources/Shiftlist")
    ]
)
