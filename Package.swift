// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LineLens",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LineLens", targets: ["LineLens"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "LineLensCore"),
        .executableTarget(
            name: "LineLens",
            dependencies: ["LineLensCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "LineLensCoreTests", dependencies: ["LineLensCore"]),
        .testTarget(name: "LineLensTests", dependencies: ["LineLens"]),
    ],
    swiftLanguageModes: [.v6]
)
