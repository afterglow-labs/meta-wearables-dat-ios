// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MetaWearablesDAT",
  platforms: [
    .iOS("16.5"),
  ],
  products: [
    .library(
      name: "MWDATCamera",
      targets: ["MWDATCamera"]
    ),
    .library(
      name: "MWDATCore",
      targets: ["MWDATCore"]
    ),
    .library(
      name: "MWDATDisplay",
      targets: ["MWDATDisplay"]
    ),
    .library(
      name: "MWDATDisplayLive",
      targets: ["MWDATDisplayLive"]
    ),
    .library(
      name: "MWDATMockDevice",
      targets: ["MWDATMockDevice"]
    ),
    .library(
      name: "MWDATMockDeviceTestClient",
      targets: ["MWDATMockDeviceTestClient"]
    ),
  ],
  targets: [
    .binaryTarget(
      name: "MWDATCamera",
      path: "MWDATCamera.xcframework"
    ),
    .binaryTarget(
      name: "MWDATCore",
      path: "MWDATCore.xcframework"
    ),
    .binaryTarget(
      name: "MWDATDisplay",
      path: "MWDATDisplay.xcframework"
    ),
    .target(
      name: "MWDATDisplayLive",
      dependencies: ["MWDATCore", "MWDATDisplay"]
    ),
    .binaryTarget(
      name: "MWDATMockDevice",
      path: "MWDATMockDevice.xcframework"
    ),
    .binaryTarget(
      name: "MWDATMockDeviceTestClient",
      path: "MWDATMockDeviceTestClient.xcframework"
    ),
    .testTarget(
      name: "MWDATDisplayLiveTests",
      dependencies: ["MWDATDisplayLive"]
    ),
  ]
)
