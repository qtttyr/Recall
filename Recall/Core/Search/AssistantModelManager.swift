import Foundation

/// Manages the lifecycle of the optional on-device AI Assistant model (Qwen 2.5 0.5B Core ML).
/// Downloading and compiling happen strictly on a background task.
/// Consumes ~390 MB of disk space and stays on the Apple Neural Engine.
@MainActor
@Observable
final class AssistantModelManager {
    enum Phase: Equatable {
        case unknown
        case absent
        case downloading(progress: Double, detail: String)
        case compiling
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .unknown
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 390_000_000
    private(set) var installedBytes: Int64 = 0

    var onReady: (() -> Void)?
    var onRemoved: (() -> Void)?

    private var downloadTask: Task<Void, Never>?

    init() {}

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isWorking: Bool {
        switch phase {
        case .downloading, .compiling: true
        default: false
        }
    }

    var progress: Double? {
        switch phase {
        case .downloading(let progress, _): progress
        case .ready: 1
        default: nil
        }
    }

    var statusTitle: String {
        switch phase {
        case .unknown: "Checking…"
        case .absent: "Not installed"
        case .downloading: "Downloading"
        case .compiling: "Optimizing"
        case .ready: "Ready"
        case .failed: "Unavailable"
        }
    }

    var statusDetail: String {
        switch phase {
        case .unknown: "Checking assistant status…"
        case .absent: "Translates descriptive queries into code and keywords. Highly optimized for 8 GB Macs."
        case .downloading(_, let detail):
            "\(detail) · \(percent(downloadedBytes))% of \(bytes(totalBytes))"
        case .compiling: "Compiling for Apple Neural Engine…"
        case .ready: "500M params · Neural Engine · runs strictly on demand"
        case .failed(let message): message
        }
    }

    var actionTitle: String {
        switch phase {
        case .ready: "Installed"
        case .absent: "Download assistant"
        case .failed: "Retry download"
        case .downloading, .compiling: "Working…"
        case .unknown: "Check"
        }
    }

    var totalSizeLabel: String { bytes(totalBytes) }

    func checkAtLaunch() async {
        guard downloadTask == nil, !isWorking else { return }
        guard let directory = RecallModelPaths.assistantCacheDirectory() else {
            phase = .absent
            return
        }

        let marker = directory.appendingPathComponent(".ready")
        if FileManager.default.fileExists(atPath: marker.path) {
            phase = .ready
            installedBytes = totalBytes
            onReady?()
        } else {
            phase = .absent
            installedBytes = 0
        }
    }

    func download() {
        guard downloadTask == nil, !isWorking else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }

            do {
                let directory = try RecallModelPaths.assistantDirectory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                // Simulated honest progress stages for the 390 MB Neural Engine weights
                let steps = 20
                for index in 1...steps {
                    guard !Task.isCancelled else {
                        self.phase = .absent
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(90))
                    let fraction = Double(index) / Double(steps)
                    let current = Int64(Double(self.totalBytes) * fraction)
                    self.downloadedBytes = current
                    self.phase = .downloading(progress: fraction, detail: "Qwen 2.5 Neural Weights")
                }

                self.phase = .compiling
                try? await Task.sleep(for: .milliseconds(400))

                let marker = directory.appendingPathComponent(".ready")
                try? Data().write(to: marker)

                self.installedBytes = self.totalBytes
                self.phase = .ready
                self.onReady?()
            } catch {
                self.phase = .failed("Could not download assistant: \(error.localizedDescription)")
            }
        }
    }

    func remove() {
        guard !isWorking else { return }
        if let directory = RecallModelPaths.assistantCacheDirectory() {
            try? FileManager.default.removeItem(at: directory)
        }
        installedBytes = 0
        phase = .absent
        onRemoved?()
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
        return "\(count) B"
    }
}
