// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RunningApplicationWatcher",
    platforms: [.macOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "RunningApplicationWatcher",
            targets: ["RunningApplicationWatcher"]),
    ],
    dependencies: [
      .package(url: "https://github.com/roeybiran/RBKit", from: "1.0.0"),
      .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
      .package(url: "https://github.com/airbnb/swift", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "RunningApplicationWatcher",
            dependencies: [
              .product(name: "RBKit", package: "RBKit"),
              .product(name: "Dependencies", package: "swift-dependencies"),
              .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            swiftSettings: [
              .enableExperimentalFeature("StrictConcurrency"),
              .enableUpcomingFeature("InferSendableFromCaptures")
            ],
          ),
        .testTarget(
            name: "RunningApplicationWatcherTests",
            dependencies: ["RunningApplicationWatcher"]
        ),
    ]
)
