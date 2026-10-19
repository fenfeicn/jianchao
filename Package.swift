// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jianchao",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Jianchao", targets: ["Jianchao"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Jianchao", dependencies: ["ClipCore"], resources: [.process("Resources")])
    ]
)
