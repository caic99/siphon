// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Siphon",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything testable — network state, proxy dictionaries, privilege
        // escalation, the re-apply policy — with no AppKit dependency.
        .target(name: "SiphonCore", path: "Sources/SiphonCore"),
        // The menu bar shell: status item, menu, and nothing else.
        .executableTarget(name: "Siphon", dependencies: ["SiphonCore"], path: "Sources/Siphon"),
        .testTarget(name: "SiphonTests", dependencies: ["SiphonCore"], path: "Tests/SiphonTests"),
    ]
)
