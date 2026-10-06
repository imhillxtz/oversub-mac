// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OverSub",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "OverSub", path: "Sources/PhuDe")
    ]
)
