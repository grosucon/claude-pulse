import AppKit
import SwiftUI
import ClaudePulseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var coord: UsageCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory == agent app — no Dock icon, lives in the menu bar only.
        NSApp.setActivationPolicy(.accessory)

        // Anthropic OAuth usage endpoint — same data Claude Code's `/usage`
        // panel renders. No estimation, no calibration, no fallback. If the
        // token or the endpoint are unavailable, surface the error rather
        // than show wrong numbers.
        let source = AnthropicAPISource()
        // `try?` so a path-resolution failure (rare sandboxing edge) leaves
        // the app running without persistence rather than crashing.
        let store: JSONLSnapshotStore? = (try? JSONLSnapshotStore.defaultLocation())
            .map { JSONLSnapshotStore(url: $0) }
        let coord = UsageCoordinator(source: source, store: store)  // 300s default + 4× 429 backoff
        self.coord = coord
        self.statusController = StatusItemController(coord: coord)
        coord.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coord?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
