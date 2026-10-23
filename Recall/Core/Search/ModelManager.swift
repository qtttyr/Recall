import Foundation

/// The user-facing lifecycle of the optional embedding model. Downloading and
/// preparing are network/CPU work owned by a background task; the UI observes
/// this small state machine and nothing else.
@MainActor
@Observable
final class ModelManager {
    enum Phase: Equatable {
        case unknown
        case absent
        case partial
        case checking
        case downloading(progress: Double, detail: String)
        case verifying(progress: Double, detail: String)
        case compiling
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .unknown
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = EmbeddingGemmaModelStore.totalBytes
    private(set) var installedBytes: Int64 = 0

    var onReady: (() -> Void)?
    var onFallback: (() -> Void)?

    private let semantic: SemanticEngine
    private var task: Task<Void, Never>?
    private var lastProgressAt = Date.distantPast

    init(semantic: SemanticEngine) {
        self.semantic = semantic
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .compiling, .loading: true
        default: false
        }
    }

    var progress: Double? {
        switch phase {
        case .downloading(let progress, _), .verifying(let progress, _): progress
        case .ready: 1
        default: nil
        }
    }

    var statusTitle: String {
        switch phase {
        case .unknown, .checking: "Checking…"
        case .absent: "Not installed"
        case .partial: "Download incomplete"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .compiling: "Preparing"
        case .loading: "Loading"
        case .ready: "Ready"
        case .failed: "Unavailable"
        }
    }

    var statusDetail: String {
        switch phase {
        case .unknown: "Checking the local model…"
        case .checking: "Checking the local model…"
        case .absent: "Add multilingual meaning search. One download, then offline forever."
        case .partial: "The last download was interrupted. It can resume where it stopped."
        case .downloading(_, let detail):
            "\(detail) · \(percent(downloadedBytes))% · \(bytes(downloadedBytes)) of \(bytes(totalBytes))"
        case .verifying(_, let detail):
            "SHA-256 \(detail) · \(percent(downloadedBytes))%"
        case .compiling: "Compiling for the Apple Neural Engine. This can take a few minutes."
        case .loading: "Warming up the 768-dimensional multilingual space."
        case .ready: "768 dimensions · 100+ languages · on-device"
        case .failed(let message): message
        }
    }

    var compactStatus: String {
        switch phase {
        case .ready: "Ready · \(bytes(installedBytes))"
        case .absent: "Not installed · \(bytes(totalBytes))"
        case .partial: "Incomplete · \(bytes(installedBytes)) of \(bytes(totalBytes))"
        case .downloading: "Downloading · \(percent(downloadedBytes))%"
        case .verifying: "Verifying · \(percent(downloadedBytes))%"
        case .compiling: "Preparing for Neural Engine…"
        case .loading: "Loading…"
        case .checking, .unknown: "Checking…"
        case .failed: "Unavailable · using basic search"
        }
    }

    var actionTitle: String {
        switch phase {
        case .ready: "Verify model"
        case .absent: "Download model"
        case .partial, .failed: "Resume download"
        case .downloading, .verifying, .compiling, .loading, .checking: "Working…"
        case .unknown: "Check model"
        }
    }

    var totalSizeLabel: String { bytes(totalBytes) }

    func checkAtLaunch() async {
        guard task == nil, !isWorking else { return }
        installedBytes = EmbeddingGemmaModelStore.installedBytes()
        guard let directory = RecallModelPaths.cacheDirectory() else {
            phase = .failed("Application Support is unavailable.")
            return
        }

        if EmbeddingGemmaModelStore.isComplete(cacheDirectory: directory) {
            phase = .loading
            if await semantic.activateGemmaFromCache() {
                phase = .ready
                onReady?()
            } else {
                phase = .failed("The model is installed but could not be loaded. Verify it in Settings.")
            }
        } else if EmbeddingGemmaModelStore.hasModelFiles(cacheDirectory: directory) {
            phase = .partial
        } else {
            phase = .absent
        }
    }

    /// Starts or resumes the one-time download. The task deliberately belongs
    /// to the app, not to an onboarding view: closing onboarding does not stop
    /// it, and the menu bar keeps preparing the model in the background.
    func download() {
        guard task == nil, !isWorking else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            self.phase = .checking
            do {
                let directory = try RecallModelPaths.modelDirectory()
                let resolved = try await EmbeddingGemmaModelStore.ensure(
                    cacheDirectory: directory,
                    progress: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.apply(event)
                        }
                    }
                )
                self.installedBytes = EmbeddingGemmaModelStore.installedBytes(cacheDirectory: resolved)
                self.phase = .loading
                do {
                    try await self.semantic.activateGemma(from: resolved)
                    self.phase = .ready
                    self.onReady?()
                } catch {
                    self.phase = .failed(
                        "The download finished, but the model could not load. Try verifying it in Settings."
                    )
                }
            } catch is CancellationError {
                self.phase = .partial
            } catch {
                self.phase = .failed(LocalizedErrorText.describe(error))
            }
            self.installedBytes = EmbeddingGemmaModelStore.installedBytes()
        }
    }

    func verify() async {
        guard !isWorking else { return }
        phase = .verifying(progress: 0, detail: "Checking model files…")
        let directory = RecallModelPaths.cacheDirectory()
        let valid = await EmbeddingGemmaModelStore.verify(cacheDirectory: directory) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.apply(event)
            }
        }
        installedBytes = EmbeddingGemmaModelStore.installedBytes()
        if valid {
            phase = .ready
            onReady?()
        } else {
            phase = .failed("The model files are incomplete. Download it again.")
        }
    }

    func remove() async {
        guard !isWorking else { return }
        await semantic.deactivateGemma()
        try? EmbeddingGemmaModelStore.remove()
        installedBytes = 0
        phase = .absent
        onFallback?()
    }

    func retryOrVerify() {
        switch phase {
        case .ready:
            Task { await verify() }
        case .failed, .absent, .partial:
            download()
        case .unknown:
            Task { await checkAtLaunch() }
        default:
            break
        }
    }

    // MARK: - Progress

    private func apply(_ event: EmbeddingGemmaModelStore.Phase) {
        switch event {
        case .downloading(let asset, let completed, let total):
            totalBytes = max(total, 1)
            downloadedBytes = max(0, min(completed, totalBytes))
            let progress = Double(downloadedBytes) / Double(totalBytes)
            phase = .downloading(progress: progress, detail: assetLabel(asset))
        case .verifying(let asset, let completed, let total):
            totalBytes = max(total, 1)
            downloadedBytes = max(0, min(completed, totalBytes))
            phase = .verifying(
                progress: Double(downloadedBytes) / Double(totalBytes),
                detail: assetLabel(asset)
            )
        case .compiling:
            downloadedBytes = totalBytes
            phase = .compiling
        case .ready:
            downloadedBytes = totalBytes
        }
    }

    private func assetLabel(_ path: String) -> String {
        if path.contains("weights") { return "Text weights" }
        if path.contains("embeddings.bf16") { return "Token table" }
        if path.contains("tokenizer.json") { return "Tokenizer" }
        if path.contains("model.mlmodel") { return "Text model" }
        if path.contains("Manifest") { return "Model manifest" }
        if path.contains("config.json") { return "Configuration" }
        return "Model"
    }

    private func percent(_ bytes: Int64) -> Int {
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, Int((Double(bytes) / Double(totalBytes)) * 100)))
    }

    private func bytes(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.0f MB", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0f KB", Double(count) / 1_000)
        }
        return "\(count) B"
    }
}

private enum LocalizedErrorText {
    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
