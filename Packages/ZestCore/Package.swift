// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ZestCore",
  platforms: [.macOS(.v13)],
  products: [.library(name: "ZestCore", targets: ["ZestCore"])],
  targets: [
    .target(name: "ZestCore"),
    .testTarget(name: "ZestCoreTests", dependencies: ["ZestCore"]),
  ]
)
