// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
  name: "StowawayCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "StowawayCore", targets: ["StowawayCore"])
  ],
  targets: [
    .target(name: "StowawayCore", swiftSettings: strict),
    .testTarget(name: "StowawayCoreTests", dependencies: ["StowawayCore"], swiftSettings: strict),
  ]
)
