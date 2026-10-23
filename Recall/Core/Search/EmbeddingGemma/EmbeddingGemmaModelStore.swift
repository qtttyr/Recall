//
//  EmbeddingGemmaModelStore.swift
//  Recall
//
//  Adapted from FluidInference/FluidUse's EmbeddingGemma 2 model store.
//  Copyright (c) FluidInference contributors. Licensed under Apache 2.0.
//  https://github.com/FluidInference/FluidUse
//  Modifications for Recall, 2026.
//

@preconcurrency import CoreML
import CryptoKit
import Foundation

/// Where Recall keeps downloaded model assets. The directory is deliberately
/// separate from the database so a model can be removed without touching a
/// single clipboard item.
enum RecallModelPaths {
    static let modelFolderName = "embeddinggemma-2-coreml"
    static let assistantFolderName = "qwen2.5-0.5b-coreml"
    static let storeFolderName = "Models"

    static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Recall", isDirectory: true)
    }

    static func modelsDirectory() throws -> URL {
        let directory = try applicationSupportDirectory().appendingPathComponent(storeFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func modelDirectory() throws -> URL {
        try modelsDirectory().appendingPathComponent(modelFolderName, isDirectory: true)
    }

    static func cacheDirectory() -> URL? {
        try? modelDirectory()
    }

    static func assistantDirectory() throws -> URL {
        try modelsDirectory().appendingPathComponent(assistantFolderName, isDirectory: true)
    }

    static func assistantCacheDirectory() -> URL? {
        try? assistantDirectory()
    }

    /// Moves a fully verified download into place without ever exposing a
    /// half-written file at the destination.
    static func install(_ temporary: URL, at destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        do {
            try manager.moveItem(at: temporary, to: staged)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: staged, to: destination)
        } catch {
            try? manager.removeItem(at: staged)
            // A downloaded temp file and Application Support can live on
            // different volumes in rare setups. Fall back to a copy.
            if !manager.fileExists(atPath: staged.path) {
                try? manager.removeItem(at: destination)
                try manager.copyItem(at: temporary, to: destination)
            } else {
                throw error
            }
        }
    }
}

/// Downloads the pinned EmbeddingGemma 2 text package, token table, and
/// tokenizer from Hugging Face, verifies every byte with SHA-256, and compiles
/// the Core ML package once. Progress is reported as global bytes so the UI can
/// show a single honest bar.
enum EmbeddingGemmaModelStore {
    enum Phase: Sendable, Equatable {
        case downloading(asset: String, completedBytes: Int64, totalBytes: Int64)
        case verifying(asset: String, completedBytes: Int64, totalBytes: Int64)
        case compiling
        case ready
    }

    typealias Progress = @Sendable (Phase) -> Void

    static let repository = "FluidInference/embeddinggemma-2-coreml"
    static let revision = "70fcf18f32c8cffc173fea982d5652d0bd1de8ea"
    static let approximateBytes: Int64 = 584_748_275

    struct Asset: Sendable {
        let path: String
        let sha256: String
        let size: Int64
    }

    static let assets: [Asset] = [
        Asset(
            path: "config.json",
            sha256: "4ff891a28a5d55562b55ff3aa4ef362968d378629f9453f337cb70a9e1b45f61",
            size: 2_845),
        Asset(
            path: "tokenizer.json",
            sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4",
            size: 32_170_510),
        Asset(
            path: "embeddings.bf16",
            sha256: "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877",
            size: 268_435_456),
        Asset(
            path: "EmbeddingGemma2Text.mlpackage/Manifest.json",
            sha256: "83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19",
            size: 617),
        Asset(
            path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            sha256: "0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677",
            size: 7_323_423),
        Asset(
            path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            sha256: "75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f",
            size: 276_815_424),
    ]

    static var totalBytes: Int64 { assets.reduce(0) { $0 + $1.size } }

    /// Fast, non-hashing check used at launch. A file that was verified when it
    /// was written is trusted; `verify` recomputes the digests on demand.
    static func isComplete(cacheDirectory: URL? = nil) -> Bool {
        guard let directory = cacheDirectory ?? RecallModelPaths.cacheDirectory() else { return false }
        let manager = FileManager.default
        let verified = directory.appendingPathComponent(".verified-\(revision)")
        let compiled = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
        let stamp = compiled.appendingPathComponent("recall-revision")
        guard manager.fileExists(atPath: verified.path),
              manager.fileExists(atPath: compiled.path),
              (try? String(contentsOf: stamp, encoding: .utf8)) == revision
        else { return false }
        return assets.allSatisfy { manager.fileExists(atPath: directory.appendingPathComponent($0.path).path) }
    }

    static func hasModelFiles(cacheDirectory: URL? = nil) -> Bool {
        guard let directory = cacheDirectory ?? RecallModelPaths.cacheDirectory() else { return false }
        return assets.contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path)
        }
    }

    static func installedBytes(cacheDirectory: URL? = nil) -> Int64 {
        guard let directory = cacheDirectory ?? RecallModelPaths.cacheDirectory() else { return 0 }
        return assets.reduce(0) { partial, asset in
            let path = directory.appendingPathComponent(asset.path).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return partial + (size ?? 0)
        }
    }

    /// Ensures the text model, token table and tokenizer exist, match their
    /// checksums, and are compiled; returns the directory.
    static func ensure(cacheDirectory: URL? = nil, progress: Progress? = nil) async throws -> URL {
        let root = try cacheDirectory ?? RecallModelPaths.modelDirectory()
        let directory = root.lastPathComponent == RecallModelPaths.modelFolderName
            ? root
            : root.appendingPathComponent(RecallModelPaths.modelFolderName)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let verified = directory.appendingPathComponent(".verified-\(revision)")
        let compiled = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
        let stamp = compiled.appendingPathComponent("recall-revision")
        let allPresent = assets.allSatisfy {
            manager.fileExists(atPath: directory.appendingPathComponent($0.path).path)
        }
        if allPresent, manager.fileExists(atPath: verified.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == revision {
            progress?(.ready)
            return directory
        }

        try? manager.removeItem(at: verified)
        let total = totalBytes
        var completed: Int64 = 0

        for asset in assets {
            let destination = directory.appendingPathComponent(asset.path)
            if manager.fileExists(atPath: destination.path),
               try await checksum(of: destination) == asset.sha256 {
                completed += asset.size
                continue
            }

            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress?(.downloading(asset: asset.path, completedBytes: completed, totalBytes: total))
            let escaped = asset.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? asset.path
            guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(escaped)") else {
                throw EmbeddingGemmaError.invalidAsset("Invalid Hugging Face asset URL")
            }

            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
            let base = completed
            try await AssetDownloader(destination: staging) { written, expected in
                let expected = expected > 0 ? expected : asset.size
                let bounded = min(max(written, 0), expected)
                let bytes = base + Int64(Double(asset.size) * (Double(bounded) / Double(max(expected, 1))))
                progress?(.downloading(asset: asset.path, completedBytes: bytes, totalBytes: total))
            }.download(url: url)
            defer { try? manager.removeItem(at: staging) }

            progress?(.verifying(asset: asset.path, completedBytes: completed, totalBytes: total))
            let actual = try await checksum(of: staging)
            guard actual == asset.sha256 else {
                throw EmbeddingGemmaError.invalidAsset(
                    "Checksum mismatch for \(asset.path): expected \(asset.sha256), got \(actual)")
            }
            try RecallModelPaths.install(staging, at: destination)
            completed += asset.size
        }

        // Recompile unless the compiled model carries this revision's stamp.
        // Staged rename so a reader never sees a half-written bundle.
        if (try? String(contentsOf: stamp, encoding: .utf8)) != revision {
            progress?(.compiling)
            let package = directory.appendingPathComponent("EmbeddingGemma2Text.mlpackage")
            let temporary = try await MLModel.compileModel(at: package)
            try revision.write(
                to: temporary.appendingPathComponent("recall-revision"), atomically: true, encoding: .utf8)
            let staged = directory.appendingPathComponent("EmbeddingGemma2Text.\(UUID().uuidString).mlmodelc")
            try manager.moveItem(at: temporary, to: staged)
            let retired = directory.appendingPathComponent("EmbeddingGemma2Text.\(UUID().uuidString).old")
            if manager.fileExists(atPath: compiled.path) {
                try manager.moveItem(at: compiled, to: retired)
            }
            try manager.moveItem(at: staged, to: compiled)
            try? manager.removeItem(at: retired)
        }
        manager.createFile(atPath: verified.path, contents: Data())
        progress?(.ready)
        return directory
    }

    /// Recomputes every SHA-256 digest. This is intentionally explicit: it can
    /// take a few seconds for a 585 MB model, so it only runs when asked.
    static func verify(cacheDirectory: URL? = nil, progress: Progress? = nil) async -> Bool {
        guard let directory = cacheDirectory ?? RecallModelPaths.cacheDirectory() else { return false }
        let total = totalBytes
        var completed: Int64 = 0
        for asset in assets {
            let path = directory.appendingPathComponent(asset.path)
            progress?(.verifying(asset: asset.path, completedBytes: completed, totalBytes: total))
            guard let actual = try? await checksum(of: path), actual == asset.sha256 else { return false }
            completed += asset.size
        }
        let compiled = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
        guard FileManager.default.fileExists(atPath: compiled.path) else { return false }
        let verified = directory.appendingPathComponent(".verified-\(revision)")
        FileManager.default.createFile(atPath: verified.path, contents: Data())
        progress?(.ready)
        return true
    }

    static func remove(cacheDirectory: URL? = nil) throws {
        guard let directory = cacheDirectory ?? RecallModelPaths.cacheDirectory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func checksum(of file: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                digest.update(data: chunk)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// A one-shot download with byte-level progress. URLSession's convenience
/// download does not expose progress; this delegate wrapper does, and stages
/// the result so the caller can verify it before installing it.
private final class AssetDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var failure: Error?
    private var finished = false

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
    }

    func download(url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 30
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = EmbeddingGemmaError.invalidAsset(
                "Download failed with HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)")
            return
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        let result = error ?? failure
        if let result {
            continuation?.resume(throwing: result)
        } else {
            continuation?.resume()
        }
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
