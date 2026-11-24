// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NOTCH",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .executable(name: "NotchApp", targets: ["NotchApp"]),
    ],
    targets: [
        .target(name: "NotchCore", path: "Sources/NotchCore"),
        .executableTarget(name: "NotchApp", dependencies: ["NotchCore"], path: "Sources/NotchApp", resources: [.process("Resources")]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"], path: "Tests/NotchCoreTests"),
    ]
)
