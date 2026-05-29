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
        // Fixed slot width — composed image is rendered at exactly
        // this size below, so the menubar item never reflows.
        statusItem.length = 84
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
            // Everything (icon + 2-line speed) is composed into a single
            // NSImage and shown as imageOnly. Lets us hand-place each
            // glyph in the 22pt menubar slot — NSButton's automatic
            // multi-line layout was pushing the title above the icon's
            // vertical centre.
            button.imagePosition = .imageOnly
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
        button.image = Self.composeImage(
            up: rate(traffic?.upBps ?? 0),
            down: rate(traffic?.downBps ?? 0),
            kernelUp: kernelUp
        )
    }

    /// Compose icon + two-line right-aligned speed text into a single
    /// NSImage so we can pixel-place everything in the 22pt menubar
    /// slot. Width matches `statusItem.length` so the slot doesn't
    /// reflow as the rate text shrinks/grows.
    private static func composeImage(up: String, down: String, kernelUp: Bool) -> NSImage {
        let slotW: CGFloat = 84
        let slotH: CGFloat = 22
        let iconSize: CGFloat = 16
        let iconY = (slotH - iconSize) / 2
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        // Each line gets its own draw — manual y-coords let us centre
        // the 2-line block (≈ 20pt total) inside the 22pt slot.
        let lineH: CGFloat = 10
        let textBlockH = lineH * 2
        // y in NSImage coordinates is bottom-up: top line is at the
        // top of the centred block, bottom line is below it.
        let topLineY = (slotH - textBlockH) / 2 + lineH
        let bottomLineY = (slotH - textBlockH) / 2

        return NSImage(size: NSSize(width: slotW, height: slotH), flipped: false) { _ in
            // icon
            if let icon = NSImage(named: "MenubarIcon") {
                icon.size = NSSize(width: iconSize, height: iconSize)
                icon.draw(
                    in: NSRect(x: 0, y: iconY, width: iconSize, height: iconSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: kernelUp ? 1.0 : 0.45
                )
            }
            guard kernelUp else { return true }
            // text right-aligned to slot edge
            let textRect = NSRect(
                x: iconSize + 4,
                y: 0,
                width: slotW - iconSize - 6,
                height: slotH
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            let lineAttrs = attrs.merging([.paragraphStyle: paragraph]) { $1 }
            (("↑" + up) as NSString).draw(
                in: NSRect(x: textRect.minX, y: topLineY,
                           width: textRect.width, height: lineH),
                withAttributes: lineAttrs
            )
            (("↓" + down) as NSString).draw(
                in: NSRect(x: textRect.minX, y: bottomLineY,
                           width: textRect.width, height: lineH),
                withAttributes: lineAttrs
            )
            return true
        }
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
