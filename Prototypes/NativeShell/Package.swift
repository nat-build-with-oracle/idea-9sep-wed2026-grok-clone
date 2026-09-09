// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeShell",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "NativeShell", targets: ["NativeShell"])],
  dependencies: [.package(path: "../../Packages/WorkspaceCore")],
  targets: [
    .executableTarget(name: "NativeShell", dependencies: ["WorkspaceCore"]),
    .testTarget(name: "NativeShellTests", dependencies: ["NativeShell"]),
  ]
)
