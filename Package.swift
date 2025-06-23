// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BluebirdService",
    platforms: [.macOS(.v10_15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(
            url: "https://github.com/supabase/supabase-swift.git",
            from: "2.0.0"
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "BluebirdService",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(
                    name: "Supabase", // Auth, Realtime, Postgrest, Functions, or Storage
                    package: "supabase-swift"
                ),
            ],
            path: "Sources"
        ),
    ]
)
