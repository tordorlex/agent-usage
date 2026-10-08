// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meter",
    platforms: [
        // Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`)
        // requires the macOS 26 SDK and runtime.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Meter", targets: ["Meter"])
    ],
    targets: [
        .executableTarget(
            name: "Meter",
            path: "Sources/Meter",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
