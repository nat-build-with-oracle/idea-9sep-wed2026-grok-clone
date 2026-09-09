// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WorkspaceCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "WorkspaceCore", targets: ["WorkspaceCore"])],
  targets: [
    .target(name: "WorkspaceCore"),
    .testTarget(name: "WorkspaceCoreTests", dependencies: ["WorkspaceCore"]),
  ]
)
