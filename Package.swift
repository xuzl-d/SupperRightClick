// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SuperRightClick",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SuperRightClick",
            path: "Sources/SuperRightClick",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
