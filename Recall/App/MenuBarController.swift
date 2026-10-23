import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let pauseItem = NSMenuItem()
    private let openItem = NSMenuItem()

    var onOpenPanel: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure()
    }

    func install() {
        statusItem.button?.image = Self.makeIcon()
        statusItem.button?.toolTip = "Recall — ⌥Space"
        statusItem.menu = menu
        statusItem.isVisible = true
    }

    func remove() {
        statusItem.isVisible = false
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func update(paused: Bool) {
        pauseItem.title = paused ? "Resume Capture" : "Pause Capture"
        pauseItem.state = paused ? .on : .off
        statusItem.button?.alphaValue = paused ? 0.42 : 1.0
        statusItem.button?.toolTip = paused ? "Recall — capture paused" : "Recall — ⌥Space"
    }

    private func configure() {
        menu.autoenablesItems = false

        openItem.title = "Open Recall"
        openItem.keyEquivalent = " "
        openItem.keyEquivalentModifierMask = [.option]
        openItem.target = self
        openItem.action = #selector(openPanel)
        menu.addItem(openItem)

        menu.addItem(.separator())

        pauseItem.title = "Pause Capture"
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Recall", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Recall", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    @objc private func openPanel() { onOpenPanel?() }
    @objc private func togglePause() { onTogglePause?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }

    @objc private func openAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Recall",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            .credits: NSAttributedString(
                string: "Find anything you've copied.\n\nLocal-first. No accounts. No telemetry.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A single open loop: a memory that never quite closes. Template image so
    /// macOS handles light/dark menu bars for us.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 5.1

            let loop = NSBezierPath()
            loop.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 38,
                endAngle: 322,
                clockwise: false
            )
            loop.lineWidth = 1.35
            loop.lineCapStyle = .round
            NSColor.black.setStroke()
            loop.stroke()

            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 0.95, y: center.y - 0.95, width: 1.9, height: 1.9))
            NSColor.black.setFill()
            dot.fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}
