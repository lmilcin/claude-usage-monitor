import AppKit

@main
enum ClaudeUsageMonitorApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        // NSApplication.delegate is weak; keep ours alive for the whole run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
