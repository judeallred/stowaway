// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
  name: "SandboxProbe",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SandboxProbe", targets: ["SandboxProbe"]),
    .executable(name: "ProbeAgent", targets: ["ProbeAgent"]),
  ],
  targets: [
    .executableTarget(name: "SandboxProbe", swiftSettings: strict),
    .executableTarget(
      name: "ProbeAgent",
      exclude: ["Info.plist"],
      swiftSettings: strict,
      // A sandboxed tool without a bundle needs an embedded Info.plist, or it traps at launch.
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "\(Context.packageDirectory)/Sources/ProbeAgent/Info.plist",
        ])
      ]
    ),
  ]
)
