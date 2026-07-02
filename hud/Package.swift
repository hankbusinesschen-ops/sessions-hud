// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionsHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SessionsHUD",
            path: "Sources/SessionsHUD"
        ),
    ]
)
