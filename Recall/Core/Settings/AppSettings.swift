import Foundation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let retentionDays = "recall.retentionDays"
        static let maxItems = "recall.maxItems"
        static let semanticEnabled = "recall.semanticEnabled"
        static let assistantEnabled = "recall.assistantEnabled"
        static let isPaused = "recall.isPaused"
        static let pauseUntil = "recall.pauseUntil"
        static let excludedBundleIDs = "recall.excludedBundleIDs"
        static let hasCompletedOnboarding = "recall.hasCompletedOnboarding"
        static let onboardingVersion = "recall.onboardingVersion"
    }

    private let defaults: UserDefaults
    var onSemanticChanged: (() -> Void)?

    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    var maxItems: Int {
        didSet { defaults.set(maxItems, forKey: Key.maxItems) }
    }

    var semanticEnabled: Bool {
        didSet {
            defaults.set(semanticEnabled, forKey: Key.semanticEnabled)
            onSemanticChanged?()
        }
    }

    var assistantEnabled: Bool {
        didSet { defaults.set(assistantEnabled, forKey: Key.assistantEnabled) }
    }

    var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Key.isPaused)
            if isPaused {
                pauseUntil = Date().addingTimeInterval(60 * 60)
            } else {
                pauseUntil = nil
            }
        }
    }

    var pauseUntil: Date? {
        didSet { defaults.set(pauseUntil?.timeIntervalSince1970 ?? 0, forKey: Key.pauseUntil) }
    }

    var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.retentionDays = defaults.object(forKey: Key.retentionDays) as? Int ?? 90
        self.maxItems = defaults.object(forKey: Key.maxItems) as? Int ?? 20_000
        self.semanticEnabled = defaults.object(forKey: Key.semanticEnabled) as? Bool ?? true
        self.assistantEnabled = defaults.object(forKey: Key.assistantEnabled) as? Bool ?? true
        self.isPaused = defaults.object(forKey: Key.isPaused) as? Bool ?? false
        let pause = defaults.object(forKey: Key.pauseUntil) as? Double ?? 0
        self.pauseUntil = pause > 0 ? Date(timeIntervalSince1970: pause) : nil
        self.excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []
        self.hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var isCapturePaused: Bool {
        guard isPaused else { return false }
        if let pauseUntil, pauseUntil <= Date() {
            return false
        }
        return true
    }

    func clearPauseIfNeeded() {
        if isPaused, let pauseUntil, pauseUntil <= Date() {
            isPaused = false
        }
    }

    func pauseForOneHour() {
        isPaused = true
    }

    func exclude(bundleID: String) {
        guard !bundleID.isEmpty, !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
    }

    func include(bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The toggle is best effort. A failed registration is surfaced by
            // the settings screen rather than blocking the app.
        }
    }
}
