// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hourfox",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/EmergeTools/Pow.git", from: "1.0.6"),
        .package(path: "Vendor/Vortex"),
    ],
    targets: [
        .executableTarget(
            name: "Hourfox",
            dependencies: [
                .product(name: "Pow", package: "Pow"),
                .product(name: "Vortex", package: "Vortex"),
            ],
            path: "Sources/Hourfox"
        )
    ]
)
