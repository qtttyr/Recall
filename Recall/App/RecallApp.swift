import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let state = try AppState()
            appState = state

            #if DEBUG
            let mode = ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_MODE"]
            if mode == "panel" || mode == "settings" {
                state.settings.hasCompletedOnboarding = true
            } else if mode == "onboarding" {
                state.settings.hasCompletedOnboarding = false
            }
            if ProcessInfo.processInfo.environment["RECALL_MODEL_SELFTEST"] == "1" {
                state.settings.hasCompletedOnboarding = true
            }
            #endif

            state.start()

            #if DEBUG
            if ProcessInfo.processInfo.environment["RECALL_MODEL_SELFTEST"] == "1" {
                runModelSelfTest(state)
            } else if let mode = ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_MODE"] {
                scheduleSnapshot(mode: mode)
            }
            #endif
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Recall could not start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshPermissions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appState?.openPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stop()
    }

    #if DEBUG
    private func runModelSelfTest(_ state: AppState) {
        setbuf(stdout, nil)
        let log: (String) -> Void = { message in
            print(message)
            fflush(stdout)
        }
        Task { @MainActor in
            log("MODEL SELFTEST: starting")
            try? await Task.sleep(for: .seconds(2))
            if !state.models.isReady, !state.models.isWorking {
                state.models.download()
            }
            let deadline = Date().addingTimeInterval(60 * 25)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
                log("MODEL SELFTEST: \(state.models.statusTitle) — \(state.models.statusDetail)")
                if state.models.isReady { break }
                if case .failed(let message) = state.models.phase {
                    log("MODEL SELFTEST: FAILED — \(message)")
                    NSApp.terminate(nil)
                    return
                }
            }
            guard state.models.isReady else {
                log("MODEL SELFTEST: timed out")
                NSApp.terminate(nil)
                return
            }
            let provider = await state.semantic.currentProvider()
            log("MODEL SELFTEST: provider=\(provider.displayName) dims=\(provider.dimensions) multilingual=\(provider.isMultilingual)")

            let documents = [
                "SELECT id, name FROM users WHERE created_at > now() - interval '7 days';",
                "Заметки со встречи: вторник, 14:00. Обсудили бенчмарк семантического индекса.",
                "The best interface is the one you forget you're using.",
                "https://arxiv.org/abs/2408.12345",
                "Лучший интерфейс — тот, о котором забываешь.",
                "Купить молоко и хлеб по дороге домой.",
                "brew install --cask raycast",
                "Вчера писал запрос к таблице пользователей: выбрать всех, кто зарегистрировался за последние семь дней.",
                "func greet(_ name: String) { print(\"Hello, \\(name)\" ) }",
                "https://github.com/ml-explore/mlx-swift"
            ]
            let queries = [
                "тот SQL запрос к базе данных про пользователей за последнюю неделю",
                "sql",
                "best interface quote",
                "интерфейс который забываешь",
                "meeting notes benchmark",
                "заметки со встречи",
                "install raycast",
                "arxiv paper",
                "hello world function",
                "grocery list",
                "milk and bread",
                "qqzxvbnm plorbix quux",
                "asdfghjkl",
                "random unrelated nonsense",
                "the"
            ]
            var docVectors: [(String, EmbeddedText)] = []
            for document in documents {
                if let vector = await state.semantic.embed(document, asQuery: false) {
                    docVectors.append((document, vector))
                }
            }
            for query in queries {
                async let qTask = state.semantic.embed(query, asQuery: true)
                async let dTask = state.semantic.embed(query, asQuery: false)
                let (queryVector, docVector) = await (qTask, dTask)
                guard queryVector != nil || docVector != nil else {
                    log("MODEL CAL: query embedding failed: \(query)")
                    continue
                }

                // Merged score: max of both prompt views per document, exactly
                // what SearchEngine.semantic computes.
                var scores: [(Float, String)] = []
                for (document, vector) in docVectors {
                    var score = Float(-1)
                    if let queryVector { score = max(score, zip(queryVector.vector, vector.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
                    if let docVector { score = max(score, zip(docVector.vector, vector.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
                    scores.append((score, document))
                }
                scores.sort { $0.0 > $1.0 }
                let second = scores.count > 1 ? scores[1].0 : 0
                let gap = scores.first!.0 - second
                let line = scores.prefix(5).map { String(format: "%.3f %@", $0.0, String($0.1.prefix(36))) }.joined(separator: " | ")
                log("MODEL CAL [\(query)] top=\(String(format: "%.3f", scores.first!.0)) gap=\(String(format: "%.3f", gap)) \(line)")
            }
            log("MODEL SELFTEST: done")
            NSApp.terminate(nil)
        }
    }

    private func scheduleSnapshot(mode: String) {
        if mode == "panel", let state = appState {
            preparePanelSnapshot(state)
            return
        }

        if mode == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.appState?.openSettings()
            }
        }

        let delay: TimeInterval = mode == "settings" ? 12.0 : (mode == "onboarding" ? 12.0 : 2.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.writeSnapshot()
        }
    }

    private func preparePanelSnapshot(_ state: AppState) {
        state.monitor.stop()
        Task { @MainActor in
            let samples = self.snapshotSamples()
            for sample in samples {
                _ = try? await state.store.insert(sample)
            }
            state.panelController.model.permission = .allowed
            state.openPanel()

            let query = ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_QUERY"] ?? ""

            // The empty state is the whole feature: do not wait for a model it
            // will not use. Query captures still wait for the production model
            // and its own vector pass so cross-lingual ranking is real.
            if !query.isEmpty {
                let deadline = Date().addingTimeInterval(35)
                while Date() < deadline, !state.models.isReady {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if state.models.isReady {
                    while Date() < deadline {
                        let provider = await state.semantic.currentProvider()
                        let missing = (try? await state.store.missingEmbeddings(
                            provider: provider.id,
                            limit: 1
                        )) ?? []
                        if missing.isEmpty { break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }

                state.panelController.model.setFilter(.all)
                state.panelController.model.query = query
                try? await Task.sleep(for: .milliseconds(1_800))
            }

            state.panelController.model.setFilter(.all)
            state.panelController.model.permission = .allowed
            try? await Task.sleep(for: .milliseconds(450))
            debugLog("SNAPSHOT query=\(state.panelController.model.query) filter=\(state.panelController.model.filter) results=\(state.panelController.model.results.count) semantic=\(state.panelController.model.semanticUsed) height=\(state.panelController.model.panelHeight) layout=\(state.panelController.model.layout)")
            self.writeSnapshot()
        }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_LOG"] != nil else { return }
        FileHandle.standardOutput.write((message + "\n").data(using: .utf8)!)
    }

    private func writeSnapshot() {
        // The compact panel is intentionally shorter than 200pt, so prefer the
        // key window instead of guessing by area.
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        guard let window = NSApp.keyWindow ?? windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView
        else {
            debugLog("SNAPSHOT no window")
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            debugLog("SNAPSHOT no rep")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            debugLog("SNAPSHOT no data")
            return
        }
        let path = ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_PATH"] ?? "/tmp/recall-snapshot.png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            debugLog("SNAPSHOT wrote \(data.count) bytes to \(path)")
        } catch {
            debugLog("SNAPSHOT write failed: \(error)")
        }
    }

    private func snapshotSamples() -> [ClipCandidate] {
        func text(_ text: String, app: String, bundle: String) -> ClipCandidate {
            let kind = ContentClassifier.classify(text)
            return ClipCandidate(
                kind: kind,
                text: text,
                sourceApp: app,
                sourceBundle: bundle,
                imageData: nil,
                hash: ContentClassifier.hash(kind: kind, text: text)
            )
        }

        var samples: [ClipCandidate] = [
            text("Ship the smallest thing that feels inevitable.", app: "Notes", bundle: "com.apple.Notes"),
            text("brew install --cask raycast", app: "Terminal", bundle: "com.apple.Terminal"),
            text("Meeting notes: Tuesday, 14:00. Bring the semantic index benchmark.", app: "Notes", bundle: "com.apple.Notes"),
            text("SELECT id, name FROM users WHERE created_at > now() - interval '7 days';", app: "Terminal", bundle: "com.apple.Terminal"),
            text("https://arxiv.org/abs/2408.12345", app: "Safari", bundle: "com.apple.Safari"),
            text("func greet(_ name: String) {\n    print(\"Hello, \\(name)\")\n}", app: "Xcode", bundle: "com.apple.dt.Xcode"),
            text("The best interface is the one you forget you're using.", app: "Notes", bundle: "com.apple.Notes"),
            text("Вчера писал запрос к таблице пользователей: выбрать всех, кто зарегистрировался за последние семь дней.", app: "Notes", bundle: "com.apple.Notes"),
            text("Заметки со встречи: вторник, 14:00. Обсудили бенчмарк семантического индекса.", app: "Notes", bundle: "com.apple.Notes"),
            text("Лучший интерфейс — тот, о котором забываешь.", app: "Notes", bundle: "com.apple.Notes"),
            text("Купить молоко и хлеб по дороге домой.", app: "Notes", bundle: "com.apple.Notes")
        ]

        if let imageData = snapshotImage() {
            samples.append(ClipCandidate(
                kind: .image,
                text: "",
                sourceApp: "Safari",
                sourceBundle: "com.apple.Safari",
                imageData: imageData,
                hash: ContentClassifier.hash(kind: .image, text: "", imageData: imageData)
            ))
        }

        samples.append(text("https://github.com/ml-explore/mlx-swift", app: "Safari", bundle: "com.apple.Safari"))
        return samples
    }

    private func snapshotImage() -> Data? {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.55, alpha: 1)
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -35)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        "RECALL".draw(
            in: NSRect(x: 0, y: size.height / 2 - 12, width: size.width, height: 24),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .kern: 6,
                .paragraphStyle: paragraph
            ]
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}

@main
struct RecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The product is the panel and the menu bar item. This scene exists only
        // to satisfy SwiftUI's app lifecycle; Settings is an AppKit window.
        Settings {
            EmptyView()
        }
    }
}
