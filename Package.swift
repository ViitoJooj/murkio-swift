// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MurkioIdentity",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "MurkioIdentity", targets: ["MurkioIdentity"]),
    ],
    targets: [
        .target(name: "MurkioIdentity", path: "Sources/MurkioIdentity"),
        .testTarget(
            name: "MurkioIdentityTests",
            dependencies: ["MurkioIdentity"],
            path: "Tests/MurkioIdentityTests"
        ),
    ]
)
