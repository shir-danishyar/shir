// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiffKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RiffKit", targets: ["RiffKit"])
    ],
    targets: [
        .target(name: "RiffKit"),
        .testTarget(name: "RiffKitTests", dependencies: ["RiffKit"]),
    ]
)
