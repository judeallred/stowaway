// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "StowawayApp",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Stowaway", targets: ["StowawayApp"]),
    .library(name: "StowawayKit", targets: ["StowawayKit"]),
  ],
  targets: [
    .target(name: "StowawayKit", swiftSettings: strict),
    .executableTarget(
      name: "StowawayApp",
      dependencies: ["StowawayKit"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "StowawayKitTests",
      dependencies: ["StowawayKit"],
      resources: [.copy("Fixtures")],
      swiftSettings: strict
    ),
  ]
)
