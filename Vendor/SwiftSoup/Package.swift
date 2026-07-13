// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftSoup",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "SwiftSoup", targets: ["SwiftSoup"]),
    ],
    targets: [
        .target(
            name: "SwiftSoup",
            path: "Sources/SwiftSoup"),
    ]
)