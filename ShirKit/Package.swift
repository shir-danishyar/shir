// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShirKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShirKit", targets: ["ShirKit"])
    ],
    targets: [
        .target(name: "ShirKit"),
        .testTarget(name: "ShirKitTests", dependencies: ["ShirKit"]),
    ]
)
