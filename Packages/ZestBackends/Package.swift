// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ZestBackends",
  platforms: [.macOS(.v13)],
  products: [.library(name: "ZestBackends", targets: ["ZestBackends"])],
  dependencies: [.package(path: "../ZestCore")],
  targets: [
    .target(name: "ZestBackends", dependencies: ["ZestCore"]),
    .testTarget(name: "ZestBackendsTests", dependencies: ["ZestBackends"]),
  ]
)
