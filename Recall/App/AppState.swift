import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let store: ClipStore
    let search: SearchEngine
    let semantic: SemanticEngine
    let models: ModelManager
    let assistantModels: AssistantModelManager
    let vectorIndex: VectorIndex
    let monitor: ClipboardMonitor
    let panelController: PanelController

    private(set) var menuBar: MenuBarController?
    private(set) var hotKey: GlobalHotKey?
    private(set) var hotKeyLabel = "⌥Space"

    var settingsWindow: SettingsWindowController?
    var onboardingWindow: OnboardingWindowController?

    var permission: PasteboardAccess
    var semanticReady = false
    var lastError: String?

    private var indexTask: Task<Void, Never>?

    init() throws {
        let settings = AppSettings()
        let store: ClipStore
        #if DEBUG
        if ProcessInfo.processInfo.environment["RECALL_DEBUG_DATA"] == "1" {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RecallPreview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try ClipStore(
                databaseURL: root.appendingPathComponent("recall.sqlite"),
                imagesDirectory: root.appendingPathComponent("Images", isDirectory: true)
            )
        } else {
            store = try ClipStore()
        }
        #else
        store = try ClipStore()
        #endif
        let semantic = SemanticEngine()
        let models = ModelManager(semantic: semantic)
        let assistantModels = AssistantModelManager()
        let vectorIndex = VectorIndex()
        let search = SearchEngine(store: store, semantic: semantic, vectorIndex: vectorIndex)
        let monitor = ClipboardMonitor(store: store, settings: settings)
        let panelController = PanelController(store: store, search: search, settings: settings)

        self.settings = settings
        self.store = store
        self.semantic = semantic
        self.models = models
        self.assistantModels = assistantModels
        self.vectorIndex = vectorIndex
        self.search = search
        self.monitor = monitor
        self.panelController = panelController
        self.permission = Permissions.pasteboardState()

        panelController.model.permission = permission
        panelController.onOpenSettings = { [weak self] in self?.openSettings() }

        monitor.canRead = { [weak self] in
            guard let self else { return false }
            let state = Permissions.pasteboardState()
            if self.permission != state {
                self.permission = state
                self.panelController.updatePermission(state)
            }
            return state.canRead
        }
        monitor.onCapture = { [weak self] in
            self?.panelController.refreshIfVisible()
        }

        settings.onSemanticChanged = { [weak self] in
            self?.semanticSettingChanged()
        }

        models.onReady = { [weak self] in
            self?.searchProviderChanged()
        }
        models.onFallback = { [weak self] in
            self?.searchProviderChanged()
        }
    }

    func start() {
        installMenuBar()
        installHotKey()
        monitor.start()
        startSemanticIndex()
        Task { [weak self] in
            await self?.models.checkAtLaunch()
            await self?.assistantModels.checkAtLaunch()
        }
        showOnboardingIfNeeded()
    }

    func stop() {
        monitor.stop()
        hotKey?.unregister()
        menuBar?.remove()
        panelController.stop()
        indexTask?.cancel()
        Task { await semantic.unload() }
    }

    func togglePanel() {
        refreshPermissions()
        panelController.toggle()
    }

    func openPanel() {
        refreshPermissions()
        panelController.show()
    }

    func closePanel() {
        panelController.hide()
    }

    func togglePause() {
        settings.isPaused.toggle()
        menuBar?.update(paused: settings.isCapturePaused)
        if settings.isCapturePaused {
            panelController.hide()
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(appState: self)
        }
        settingsWindow?.show()
    }

    func showOnboardingIfNeeded() {
        guard !settings.hasCompletedOnboarding else { return }
        showOnboarding()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(appState: self)
        }
        onboardingWindow?.show()
    }

    func resetToOnboarding() async {
        try? await store.deleteAll()
        settings.hasCompletedOnboarding = false
        settingsWindow?.close()
        settingsWindow = nil
        onboardingWindow?.close()
        onboardingWindow = nil
        showOnboarding()
    }

    func refreshPermissions() {
        let state = Permissions.pasteboardState()
        permission = state
        panelController.model.permission = state
    }

    func semanticSettingChanged() {
        if settings.semanticEnabled {
            startSemanticIndex()
        } else {
            indexTask?.cancel()
            indexTask = nil
            semanticReady = false
        }
    }

    func indexNow() {
        startSemanticIndex()
    }

    private func searchProviderChanged() {
        semanticReady = false
        startSemanticIndex()
    }

    private func installMenuBar() {
        let menuBar = MenuBarController()
        menuBar.onOpenPanel = { [weak self] in self?.togglePanel() }
        menuBar.onTogglePause = { [weak self] in self?.togglePause() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
        menuBar.update(paused: settings.isCapturePaused)
        self.menuBar = menuBar
    }

    private func installHotKey() {
        let hotKey = GlobalHotKey()
        let action: () -> Void = { [weak self] in self?.togglePanel() }

        if hotKey.register(action: action) {
            hotKeyLabel = "⌥Space"
        } else if hotKey.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey | controlKey),
            action: action
        ) {
            hotKeyLabel = "⌃⌥Space"
        } else {
            hotKeyLabel = ""
            lastError = "⌥Space is already in use. Open Settings to choose another shortcut later."
        }
        self.hotKey = hotKey
    }

    private func startSemanticIndex() {
        indexTask?.cancel()
        guard settings.semanticEnabled else {
            semanticReady = false
            return
        }

        indexTask = Task { [weak self] in
            guard let self else { return }
            await self.search.prepare()
            await self.semantic.preload()

            while !Task.isCancelled {
                if !self.settings.semanticEnabled {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                if ProcessInfo.processInfo.isLowPowerModeEnabled ||
                    ProcessInfo.processInfo.thermalState == .serious ||
                    ProcessInfo.processInfo.thermalState == .critical {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }

                let provider = await self.semantic.currentProvider()
                let items = (try? await self.store.missingEmbeddings(
                    provider: provider.id,
                    limit: 4
                )) ?? []

                if items.isEmpty {
                    self.semanticReady = true
                    try? await Task.sleep(for: .milliseconds(1_200))
                    continue
                }

                for item in items {
                    guard !Task.isCancelled else { return }
                    let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        try? await self.store.markEmbeddingFailed(id: item.id, provider: provider.id)
                        continue
                    }
                    guard let embedded = await self.semantic.embed(trimmed) else {
                        try? await self.store.markEmbeddingFailed(id: item.id, provider: provider.id)
                        continue
                    }

                    // A model can finish loading mid-batch. Never write a
                    // vector from the old space under the new provider's name.
                    let active = await self.semantic.currentProvider()
                    guard active.id == provider.id else { return }

                    try? await self.store.setEmbedding(
                        id: item.id,
                        vector: embedded.vector,
                        language: embedded.language,
                        provider: provider.id
                    )
                    await self.vectorIndex.upsert(
                        id: item.id,
                        language: embedded.language,
                        vector: embedded.vector
                    )
                    try? await Task.sleep(for: .milliseconds(15))
                }
                self.semanticReady = true
            }
        }
    }
}
