import AppKit
import QuartzCore
import SwiftUI

final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: SpotlightPanel
    let model: PanelModel

    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var hideTask: Task<Void, Never>?
    private var keyMonitor: Any?

    init(store: ClipStore, search: SearchEngine, settings: AppSettings) {
        let model = PanelModel(store: store, search: search, settings: settings)
        let inset = Theme.windowInset
        let panel = SpotlightPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Theme.panelWidth + inset * 2,
                height: Theme.searchHeight + inset * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.model = model
        self.panel = panel

        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        let rootView = PanelSurface(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        panel.contentView = hostingView

        model.onClose = { [weak self] in self?.hide() }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        model.onHeightChange = { [weak self] height in self?.resize(to: height) }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKeyEvent(event)
        }
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        hideTask?.cancel()
        model.refreshPermission()
        model.isVisible = false
        model.prepareForPresentation()
        position()

        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.isVisible = true
            self.model.focusToken += 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        hideTask?.cancel()
        model.isVisible = false
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(230))
            guard let self, !Task.isCancelled, !self.model.isVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    func refreshIfVisible() {
        guard panel.isVisible, model.query.isEmpty else { return }
        model.refresh()
    }

    func updatePermission(_ access: PasteboardAccess) {
        model.permission = access
    }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard model.isVisible else { return }
        hide()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let inset = Theme.windowInset
        let size = NSSize(
            width: Theme.panelWidth + inset * 2,
            height: model.panelHeight + inset * 2
        )

        // The search line is the visual anchor. It keeps the same screen-space
        // top edge while the panel opens downward.
        let surfaceTop = min(
            visible.maxY - inset - 8,
            visible.maxY - visible.height * 0.16
        )
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: surfaceTop + inset - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Called by the SwiftUI layout when the content earns more space. The
    /// window grows downward and keeps its top edge pinned to the screen.
    private func resize(to contentHeight: CGFloat) {
        let inset = Theme.windowInset
        let target = NSSize(
            width: Theme.panelWidth + inset * 2,
            height: contentHeight + inset * 2
        )
        var frame = panel.frame
        guard abs(frame.height - target.height) > 0.5 else { return }

        let top = frame.maxY
        frame.size = target
        frame.origin.y = top - target.height
        frame.origin.x = panel.frame.midX - target.width / 2

        guard panel.isVisible, model.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            // A relaxed ease-out: the glass grows like it has mass, instead of
            // snapping to size between keystrokes.
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.24, 1.0)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            switch event.keyCode {
            case 36, 76:
                model.copySelected(andPaste: true)
                return nil
            case 51:
                model.deleteSelected()
                return nil
            case 35:
                model.toggleFavorite()
                return nil
            case 43:
                onOpenSettings?()
                return nil
            default:
                return event
            }
        }

        if flags.contains(.option), event.keyCode == 36 || event.keyCode == 76 {
            model.copySelected(keepOpen: true)
            return nil
        }

        switch event.keyCode {
        case 125:
            model.moveSelection(1)
            return nil
        case 126:
            model.moveSelection(-1)
            return nil
        case 48:
            if flags.contains(.shift) {
                model.cycleFilterBackward()
            } else {
                model.cycleFilter()
            }
            return nil
        case 53:
            if model.hasQuery {
                model.clearQuery()
            } else {
                model.close()
            }
            return nil
        case 36, 76:
            model.copySelected()
            return nil
        default:
            return event
        }
    }
}
