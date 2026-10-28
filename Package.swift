// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CRLMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CRLKit", targets: ["CRLKit"]),
        .executable(name: "crltool", targets: ["crltool"]),
        .executable(name: "CRLApp", targets: ["CRLApp"]),
    ],
    targets: [
        .target(name: "CRLKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "crltool", dependencies: ["CRLKit"]),
        .executableTarget(name: "CRLApp", dependencies: ["CRLKit"]),
    ]
)
