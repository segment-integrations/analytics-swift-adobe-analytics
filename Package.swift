// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SegmentAdobe",
    platforms: [
        .macOS("10.15"),
        .iOS("13.0"),
        .tvOS("11.0"),
        .watchOS("7.1")
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SegmentAdobe",
            targets: ["SegmentAdobe"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(
            name: "Segment",
            url: "https://github.com/segmentio/analytics-swift.git",
            from: "1.1.2"
        ),
        .package(
            name: "AEPMedia",
            url: "https://github.com/adobe/aepsdk-media-ios.git",
            from: "3.0.0"
        ),
        .package(
            name: "AEPAnalytics",
            url: "https://github.com/adobe/aepsdk-analytics-ios.git",
            from: "3.0.0"
        ),
        .package(
            name: "AEPCore",
            url: "https://github.com/adobe/aepsdk-core-ios.git",
            from: "3.0.0"
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
            .target(
                name: "SegmentAdobe",
                dependencies: ["Segment", .product(
                    name: "AEPAnalytics",
                    package: "AEPAnalytics"), .product(
                        name: "AEPMedia",
                        package: "AEPMedia"), .product(
                            name: "AEPIdentity",
                            package: "AEPCore")]),
        
        // TESTS ARE HANDLED VIA THE EXAMPLE APP.
    ]
)
