// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShirKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShirKit", targets: ["ShirKit"])
    ],
    targets: [
        // The injected player scripts live here rather than in the app target
        // so they can be unit-tested with JavaScriptCore on macOS, without a
        // simulator. They are the most fragile code in the project — YouTube
        // changes its response shape every few months — so a fast test that
        // names the breakage is worth more than any other test here.
        .target(
            name: "ShirKit",
            resources: [.copy("Resources/Scripts")]
        ),
        .testTarget(
            name: "ShirKitTests",
            dependencies: ["ShirKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
