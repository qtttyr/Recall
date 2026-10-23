//
//  Adapted from FluidInference/FluidUse's EmbeddingGemma 2 runtime.
//  Copyright (c) FluidInference contributors. Licensed under Apache 2.0.
//  https://github.com/FluidInference/FluidUse
//  Modifications for Recall, 2026.
//
import Foundation

public enum EmbeddingGemmaError: Error, LocalizedError {
    case invalidAsset(String)
    case unsupported(String)
    case predictionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAsset(let reason): "Invalid EmbeddingGemma 2 asset: \(reason)"
        case .unsupported(let reason): "EmbeddingGemma 2 unsupported: \(reason)"
        case .predictionFailed(let reason): "EmbeddingGemma 2 prediction failed: \(reason)"
        }
    }
}

/// Task prefixes EmbeddingGemma 2 was trained with (`config_sentence_transformers.json`). Text only.
public enum EmbeddingGemmaPrompt: Sendable {
    case document(title: String?)
    case searchQuery
    case questionAnswering
    case factChecking
    case codeRetrieval
    case classification
    case clustering
    case sentenceSimilarity
    case none

    public func apply(to text: String) -> String {
        switch self {
        case .document(let title): "title: \(title ?? "none") | text: \(text)"
        case .searchQuery: "task: search result | query: \(text)"
        case .questionAnswering: "task: question answering | query: \(text)"
        case .factChecking: "task: fact checking | query: \(text)"
        case .codeRetrieval: "task: code retrieval | query: \(text)"
        case .classification: "task: classification | query: \(text)"
        case .clustering: "task: clustering | query: \(text)"
        case .sentenceSimilarity: "task: sentence similarity | query: \(text)"
        case .none: text
        }
    }
}
