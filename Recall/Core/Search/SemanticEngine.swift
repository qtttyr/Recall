import CoreML
import Foundation
import NaturalLanguage

struct EmbeddedText: Sendable {
    let vector: [Float]
    let language: String
}

struct SemanticProvider: Sendable, Equatable {
    let id: String
    let dimensions: Int
    let isMultilingual: Bool
    let displayName: String
}

struct RelevanceBounds: Sendable {
    let floor: Float
    let margin: Float
    let confidentThreshold: Float
    let separationThreshold: Float
}

/// The semantic backend. EmbeddingGemma 2 is the production provider: one
/// shared 768-dimensional multilingual space. Apple's contextual embeddings
/// remain a zero-download fallback so search works before the model is
/// installed, with per-script vector buckets.
actor SemanticEngine {
    nonisolated static let systemProviderID = "nl-contextual-v1"
    nonisolated static let gemmaProviderID = "embeddinggemma-2"

    private var gemma: EmbeddingGemmaManager?
    private var models: [String: NLContextualEmbedding] = [:]
    private var lastUse = Date()
    private var unloadTask: Task<Void, Never>?

    var isReady: Bool { gemma != nil || !models.isEmpty }
    var isGemmaActive: Bool { gemma != nil }

    func currentProvider() -> SemanticProvider {
        if gemma != nil {
            return SemanticProvider(
                id: Self.gemmaProviderID,
                dimensions: EmbeddingGemmaManager.dimension,
                isMultilingual: true,
                displayName: "EmbeddingGemma 2"
            )
        }
        return SemanticProvider(
            id: Self.systemProviderID,
            dimensions: 512,
            isMultilingual: false,
            displayName: "macOS contextual"
        )
    }

    func relevanceBounds() -> RelevanceBounds {
        if gemma != nil {
            return RelevanceBounds(
                floor: 0.58,
                margin: 0.10,
                confidentThreshold: 0.76,
                separationThreshold: 0.05
            )
        } else {
            return RelevanceBounds(
                floor: 0.50,
                margin: 0.10,
                confidentThreshold: 0.58,
                separationThreshold: 0.035
            )
        }
    }

    // MARK: - EmbeddingGemma

    func activateGemma(from directory: URL) async throws {
        let manager = try await EmbeddingGemmaManager.load(
            from: directory,
            computeUnits: .cpuAndNeuralEngine
        )
        gemma = manager
        unloadSystemModels()
    }

    func activateGemmaFromCache() async -> Bool {
        guard let directory = RecallModelPaths.cacheDirectory(),
              EmbeddingGemmaModelStore.isComplete(cacheDirectory: directory)
        else { return false }
        do {
            try await activateGemma(from: directory)
            return true
        } catch {
            return false
        }
    }

    func deactivateGemma() {
        gemma = nil
    }

    // MARK: - Embedding

    func embed(_ text: String, asQuery: Bool = false) async -> EmbeddedText? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let gemma {
            do {
                let input = String(trimmed.prefix(2_000))
                let vector = try await gemma.embed(
                    input,
                    prompt: asQuery ? .searchQuery : .document(title: nil)
                )
                return EmbeddedText(vector: vector, language: "multi")
            } catch {
                return nil
            }
        }

        let language = Self.language(for: trimmed)
        guard let model = await model(for: language) else { return nil }

        do {
            let input = String(trimmed.prefix(1_800))
            let result = try model.embeddingResult(
                for: input,
                language: language == "ru" ? .russian : .english
            )
            var sum = [Float](repeating: 0, count: model.dimension)
            var tokenCount = 0

            result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
                guard vector.count == model.dimension else { return true }
                for (index, number) in vector.enumerated() {
                    sum[index] += Float(number)
                }
                tokenCount += 1
                return true
            }

            guard tokenCount > 0 else { return nil }
            var mean = sum.map { $0 / Float(tokenCount) }
            Self.normalize(&mean)
            touch()
            return EmbeddedText(vector: mean, language: language)
        } catch {
            return nil
        }
    }

    func preload() async {
        guard gemma == nil else { return }
        _ = await model(for: "en")
        _ = await model(for: "ru")
    }

    func unload() {
        gemma = nil
        unloadSystemModels()
    }

    // MARK: - System fallback

    private func unloadSystemModels() {
        for model in models.values {
            model.unload()
        }
        models.removeAll()
        unloadTask?.cancel()
        unloadTask = nil
    }

    private func model(for language: String) async -> NLContextualEmbedding? {
        if let existing = models[language] {
            touch()
            return existing
        }

        guard let model = NLContextualEmbedding(language: language == "ru" ? .russian : .english) else {
            return nil
        }

        do {
            if !model.hasAvailableAssets {
                let result = try await model.requestAssets()
                guard result == .available else { return nil }
            }
            try model.load()
            models[language] = model
            touch()
            return model
        } catch {
            return nil
        }
    }

    private func touch() {
        lastUse = Date()
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard gemma == nil, Date().timeIntervalSince(lastUse) >= 300 else { return }
        unloadSystemModels()
    }

    static func language(for text: String) -> String {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF:
                cyrillic += 1
            case 0x0041...0x007A:
                latin += 1
            default:
                continue
            }
        }
        return cyrillic > 0 && cyrillic >= latin ? "ru" : "en"
    }

    private static func normalize(_ vector: inout [Float]) {
        var norm: Float = 0
        for value in vector {
            norm += value * value
        }
        norm = sqrt(norm)
        guard norm > 0 else { return }
        for index in vector.indices {
            vector[index] /= norm
        }
    }
}
