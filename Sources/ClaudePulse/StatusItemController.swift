import AppKit
import SwiftUI
import ClaudePulseCore
import Observation

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let coord: UsageCoordinator
    /// `popover.behavior = .transient` only catches clicks on the same
    /// display as the popover. On a second monitor that's not enough.
    private var globalClickMonitor: Any?

    init(coord: UsageCoordinator) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.coord = coord
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: PopoverView(coord: coord, onQuit: { NSApp.terminate(nil) })
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        statusItem.isVisible = true
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.image = Self.heartbeatIcon
            button.imagePosition = .imageLeading
            applyMenuBar(snapshot: nil, error: nil)
        }

        observeSnapshot()
    }

    deinit {
        MainActor.assumeIsolated { self.removeGlobalClickMonitor() }
    }

    // MARK: - Snapshot observation

    private func observeSnapshot() {
        withObservationTracking {
            self.applyMenuBar(snapshot: self.coord.snapshot, error: self.coord.lastError)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeSnapshot() }
        }
    }

    private func applyMenuBar(snapshot: UsageSnapshot?, error: UsageError?) {
        guard let button = statusItem.button else { return }
        let (title, used, tooltip) = menuBarPresentation(snapshot, error)
        button.attributedTitle = Self.attributedTitle(title, used: used)
        button.toolTip = tooltip
    }

    private func menuBarPresentation(_ snap: UsageSnapshot?, _ err: UsageError?) -> (title: String, used: Double, tooltip: String) {
        if let snap {
            let title = String(format: " %.0f%%", snap.menuBarUsedPct)
            var lines: [String] = [String(format: "Session: %.0f%% used", snap.session.usedPct)]
            for m in snap.weekly {
                lines.append(String(format: "%@: %.0f%%", m.label, m.usedPct))
            }
            return (title, snap.menuBarUsedPct, lines.joined(separator: "\n"))
        }
        if let err {
            return (" err", 100, "Claude Pulse — \(err)")
        }
        return (" …", 0, "Claude Pulse — loading…")
    }

    // MARK: - Click handling

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown { closePopover(); return }

        // Intentionally NO refresh on open — would spam the rate-limited
        // endpoint every time the user peeks. Data refreshes only on the
        // 5-minute poll and when the user explicitly presses Refresh.
        // Required under `.accessory`: without `activate`, the popover
        // renders inactive until the user clicks into it.
        NSApp.activate(ignoringOtherApps: true)

        let raw = sender.bounds
        let anchor = NSRect(x: raw.origin.x, y: raw.origin.y - 6,
                            width: raw.width, height: raw.height)
        popover.show(relativeTo: anchor, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        installGlobalClickMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeGlobalClickMonitor()
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func removeGlobalClickMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeGlobalClickMonitor()
    }

    // MARK: - Static presentation helpers

    private static let heartbeatIcon: NSImage = {
        let img = NSImage(systemSymbolName: "waveform.path.ecg",
                          accessibilityDescription: "Claude Pulse")
            ?? NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
                return true
            }
        img.isTemplate = true
        return img
    }()

    private static func attributedTitle(_ text: String, used: Double) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: used >= 80 ? NSColor.systemRed : NSColor.labelColor,
        ])
    }
}
