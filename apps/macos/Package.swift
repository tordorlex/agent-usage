// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JusageMac",
    platforms: [
        // Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`)
        // requires the macOS 26 SDK and runtime.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "JusageMac", targets: ["JusageMac"])
    ],
    targets: [
        .executableTarget(
            name: "JusageMac",
            path: "Sources/JusageMac",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
