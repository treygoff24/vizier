// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vizier",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VizierEngine", targets: ["VizierEngine"]),
        .executable(name: "Vizier", targets: ["Vizier"]),
    ],
    dependencies: [
        // In-app updates (MIT). build-app.sh embeds Sparkle.framework in the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Adapters, the mode pipeline, config, capture, and later history. The menu bar app is its
        // first consumer; other tools can link it later.
        .target(name: "VizierEngine"),
        .executableTarget(
            name: "Vizier",
            dependencies: [
                "VizierEngine",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // The app bundle keeps frameworks in Contents/Frameworks, one level up from Contents/MacOS.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "VizierEngineTests", dependencies: ["VizierEngine"]),
        // The menu bar app's own logic: preferences, dock rule, login item, onboarding, settings.
        .testTarget(
            name: "VizierTests",
            dependencies: ["Vizier", "VizierEngine"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
