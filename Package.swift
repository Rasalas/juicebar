// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Self-built and future store packages never include the direct-download updater.
let directDownload = ProcessInfo.processInfo.environment["JUICEBAR_DISTRIBUTION"] == "direct"

let package = Package(
    name: "Juicebar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Juicebar", targets: ["Juicebar"]), .library(name: "JuicebarCore", targets: ["JuicebarCore"])],
    dependencies: directDownload ? [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")] : [],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "JuicebarCore", dependencies: ["CSQLite"], resources: [.copy("Resources/ssh-usage.py"), .copy("Resources/model-catalog.json"), .copy("Resources/catalog-public-key.txt"), .copy("Resources/en.json")]),
        .executableTarget(name: "Juicebar", dependencies: [.target(name: "JuicebarCore")] + (directDownload ? [.product(name: "Sparkle", package: "Sparkle")] : []), resources: [.process("Resources")],
                          swiftSettings: directDownload ? [.define("JUICEBAR_DIRECT")] : [],
                          linkerSettings: directDownload ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
        .executableTarget(name: "SandboxProbe", dependencies: ["JuicebarCore"], path: "scripts/sandbox"),
        .testTarget(name: "JuicebarCoreTests", dependencies: ["JuicebarCore"])
    ],
    swiftLanguageModes: [.v5]
)
