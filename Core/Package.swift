// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ClamshellCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ClamshellCore", targets: ["ClamshellCore"])],
  targets: [
    .target(name: "ClamshellCore"),
    .testTarget(name: "ClamshellCoreTests", dependencies: ["ClamshellCore"]),
  ]
)
