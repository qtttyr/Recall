import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum PasteboardAccess: String, Sendable {
    case unknown
    case needsPermission
    case allowed
    case denied
    case unavailable

    var canRead: Bool { self == .allowed || self == .unavailable }

    var title: String {
        switch self {
        case .unknown, .needsPermission: "Clipboard access needed"
        case .allowed: "Clipboard access allowed"
        case .denied: "Clipboard access denied"
        case .unavailable: "Clipboard access unavailable"
        }
    }
}

@MainActor
enum Permissions {
    static func pasteboardState() -> PasteboardAccess {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow:
                return .allowed
            case .alwaysDeny:
                return .denied
            case .ask, .default:
                // `.default` means the app has never triggered the system
                // prompt. We treat it as "needs permission" and ask only after
                // an explicit user action, never in a polling loop.
                return .needsPermission
            @unknown default:
                return .needsPermission
            }
        }
        return .unavailable
    }

    /// Triggers the one system prompt. The user should choose "Allow", not
    /// "Allow Once"; the onboarding explains the difference.
    @discardableResult
    static func requestPasteboardAccess() -> PasteboardAccess {
        _ = NSPasteboard.general.string(forType: .string)
        return pasteboardState()
    }

    static func openPasteboardSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}

@MainActor
enum Paster {
    /// Posts ⌘V to the frontmost app. Requires Accessibility; the caller should
    /// request it contextually, never at launch.
    @discardableResult
    static func paste() -> Bool {
        guard Permissions.isAccessibilityTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        return true
    }
}

private let recallPasteboardMarker = NSPasteboard.PasteboardType("app.recall.internal")

enum PasteboardWriter {
    @MainActor
    @discardableResult
    static func copy(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let wrote: Bool
        if item.kind == .image, let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
            wrote = pasteboard.writeObjects([image])
        } else {
            wrote = pasteboard.setString(item.text, forType: .string)
        }

        if wrote {
            pasteboard.setData(Data(), forType: recallPasteboardMarker)
        }
        return wrote
    }

    static func isRecallCopy(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(recallPasteboardMarker) == true
    }
}
