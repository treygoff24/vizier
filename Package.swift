// swift-tools-version: 6.2
import PackageDescription

// The manifest branches on the host OS. macOS keeps Sparkle, the
// menu bar app and its tests; Linux gets a system-library target for SQLite and builds the engine.
var products: [Product] = [
    .library(name: "VizierEngine", targets: ["VizierEngine"]),
]
// In-app updates (MIT). build-app.sh embeds Sparkle.framework in the bundle. Declared on Linux too,
// where no target uses it, so a Linux resolve keeps its pin in Package.resolved.
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
]
var engineDependencies: [Target.Dependency] = []
var targets: [Target] = []
var engineTestDependencies: [Target.Dependency] = ["VizierEngine"]
var testTargets: [Target] = []

#if os(macOS)
products.append(.executable(name: "Vizier", targets: ["Vizier"]))
targets.append(
    .executableTarget(
        name: "Vizier",
        dependencies: [
            "VizierEngine",
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        // The app bundle keeps frameworks in Contents/Frameworks, one level up from Contents/MacOS.
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )
)
// The menu bar app's own logic: preferences, dock rule, login item, onboarding, settings.
testTargets.append(
    .testTarget(
        name: "VizierTests",
        dependencies: ["Vizier", "VizierEngine"],
        swiftSettings: [.defaultIsolation(MainActor.self)]
    )
)
#else
// Apple ships SQLite3 as a module; on Linux the system library is wrapped here.
engineDependencies.append("CSQLite")
engineTestDependencies.append("CSQLite")  // HistoryStoreTests open the database directly
// PipeCapture creates its pipes with pipe2(O_CLOEXEC), which Glibc does not expose to Swift.
engineDependencies.append("CPipe2")
targets.append(.systemLibrary(name: "CPipe2", path: "Sources/CPipe2"))
targets.append(
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    )
)
// Linux: the `vizier` executable (daemon and CLI) is added here by the package that owns it.
products.append(.executable(name: "vizier", targets: ["vizier"]))
targets.append(.target(name: "CCosmicFocus", exclude: ["README.md", "LICENSE"], linkerSettings: [.linkedLibrary("wayland-client")]))
targets.append(.target(name: "VizierCLI", dependencies: ["VizierEngine"]))
// Its sources live in Sources/vizier-linux: a Sources/vizier folder is the same folder as the app's
// Sources/Vizier on the Mac's case-insensitive disk, so the app would compile the CLI's main.swift.
targets.append(.executableTarget(name: "vizier", dependencies: ["VizierCLI", "CCosmicFocus"], path: "Sources/vizier-linux"))
testTargets.append(.testTarget(name: "VizierCLITests", dependencies: ["VizierCLI", "VizierEngine"]))
#endif

testTargets.insert(.testTarget(name: "VizierEngineTests", dependencies: engineTestDependencies), at: 0)

let package = Package(
    name: "Vizier",
    platforms: [.macOS("27.0")],
    products: products,
    dependencies: dependencies,
    targets: [
        // Adapters, the mode pipeline, config, capture, and later history. The menu bar app is its
        // first consumer; other tools can link it later.
        .target(name: "VizierEngine", dependencies: engineDependencies),
    ] + targets + testTargets
)
