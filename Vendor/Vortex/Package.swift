// swift-tools-version: 5.9
// Локальная копия twostraws/Vortex 1.0.4 (MIT, см. LICENSE) без каталога ассетов.
import PackageDescription

let package = Package(
    name: "Vortex",
    platforms: [.macOS(.v12)],
    products: [.library(name: "Vortex", targets: ["Vortex"])],
    targets: [.target(name: "Vortex")]
)
