import AppKit
import SwiftUI

/// Replaces SwiftUI's `MenuBarExtra`. That wrapper hosts its label in an
/// NSStatusItem button whose height is clamped to one menubar row, so any
/// multi-line SwiftUI content (VStack, Text with \n, Image of a 22pt
/// NSAttributedString render) collapses to invisible.
///
/// MenubarController takes the lower road: own the `NSStatusItem`
/// directly, set `button.attributedTitle` to a real multi-line
/// NSAttributedString (NSButtonCell DOES wrap on `\n` once we flip the
/// cell's `usesSingleLineMode` off), and present `MenubarContent` inside
/// an `NSPopover.transient` for click-to-open + click-outside-to-close
/// behaviour that mirrors what `.menuBarExtraStyle(.window)` used to
/// give us.
@MainActor
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private unowned let app: AppDelegate
    private var timer: Timer?

    init(appDelegate: AppDelegate) {
        self.app = appDelegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 260, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenubarContent()
                .environment(appDelegate.kernel)
                .environment(appDelegate.systemProxy)
                .environment(appDelegate.configStore)
                .environment(appDelegate.profileStore)
                .environment(appDelegate.proxyStore)
                .environment(appDelegate.trafficStore)
                .environment(appDelegate.historyStore)
                .environment(appDelegate.connectionsStore)
                .environment(appDelegate.anonymousMode)
                .environment(appDelegate.resolver)
                .environment(appDelegate.notificationCenterStore)
        )

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            // NSButtonCell defaults to single-line truncation; allow wraps
            // on \n so two-line attributedTitle actually renders.
            if let cell = button.cell as? NSButtonCell {
                cell.lineBreakMode = .byClipping
                cell.wraps = true
                cell.usesSingleLineMode = false
            }
        }

        refresh()
        // 1Hz redraw keeps the speed numbers fresh; @Observable on
        // TrafficStore can't drive an NSStatusItem button directly, so
        // a poll is the simplest bridge.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Programmatic close — used by buttons inside the popover view
    /// (e.g. "设置" hands off to the main window then asks us to dismiss).
    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let kernelUp = app.kernel.apiClient != nil
        let traffic = app.trafficStore.current

        let icon = NSImage(named: "MenubarIcon")
        icon?.size = NSSize(width: 16, height: 16)
        button.image = icon
        button.alphaValue = kernelUp ? 1.0 : 0.45

        if kernelUp {
            button.imagePosition = .imageLeading
            button.attributedTitle = Self.makeTitle(
                up: rate(traffic?.upBps ?? 0),
                down: rate(traffic?.downBps ?? 0)
            )
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString()
        }
    }

    private static func makeTitle(up: String, down: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineSpacing = 0
        paragraph.maximumLineHeight = 10
        paragraph.minimumLineHeight = 10
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        return NSAttributedString(string: "↑\(up)\n↓\(down)", attributes: attrs)
    }

    private func rate(_ bps: Int) -> String {
        switch bps {
        case ..<1024:           return "\(bps) B/s"
        case ..<1_048_576:      return String(format: "%.0f KB/s", Double(bps) / 1024)
        case ..<1_073_741_824:  return String(format: "%.1f MB/s", Double(bps) / 1_048_576)
        default:                return String(format: "%.1f GB/s", Double(bps) / 1_073_741_824)
        }
    }
}
