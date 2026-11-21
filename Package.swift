// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-independent parsing/formatting logic (unit-tested, also builds on Linux).
    .target(name: "UsageCore"),
    .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
]

#if os(macOS)
// The AppKit menu bar app — only buildable on macOS.
targets.append(.executableTarget(name: "ClaudeUsageMonitor", dependencies: ["UsageCore"]))
#endif

let package = Package(
    name: "ClaudeUsageMonitor",
    platforms: [.macOS(.v13)],
    targets: targets
)
