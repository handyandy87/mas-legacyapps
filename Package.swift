// swift-tools-version:5.7.1

import PackageDescription

let package = Package(
    name: "mas-legacyapps",
    platforms: [
        .macOS(.v10_13)
    ],
    products: [
        .executable(
            name: "mas-legacyapps",
            targets: ["mas-legacyapps"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/mxcl/PromiseKit.git", from: "8.1.2"),
    ],
    targets: [
        .executableTarget(
            name: "mas-legacyapps",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "PromiseKit",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-I", "Sources/PrivateFrameworks/CommerceKit",
                    "-I", "Sources/PrivateFrameworks/StoreFoundation",
                ])
            ],
            linkerSettings: [
                .linkedFramework("CommerceKit"),
                .linkedFramework("StoreFoundation"),
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
