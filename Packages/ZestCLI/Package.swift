// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ZestCLI",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "zest", targets: ["zest"])],
  dependencies: [
    .package(path: "../ZestCore"),
    .package(path: "../ZestBackends"),
  ],
  targets: [
    .executableTarget(
      name: "zest",
      dependencies: ["ZestCore", "ZestBackends"]
    )
  ]
)
