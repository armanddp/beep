// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "beep",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "beep",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
