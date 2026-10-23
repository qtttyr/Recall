import Foundation
import NaturalLanguage

/// A lightweight AI query assistant designed to guide and enrich semantic retrieval.
/// Supports ultra-fast, local quantized models (e.g. qwen2.5:0.5b or smollm2 via Ollama)
/// and falls back to macOS NaturalLanguage lemma/keyword normalization with 0 ms overhead.
/// Runs strictly on demand, only when semantic search needs direction, and consumes minimal memory.
actor QueryAssistant {
    static let shared = QueryAssistant()

    private let session: URLSession
    private var isOllamaAvailable: Bool?
    private var lastOllamaCheck = Date.distantPast
    private let defaultModel = "qwen2.5:0.5b"
    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.6
        config.timeoutIntervalForResource = 0.8
        self.session = URLSession(configuration: config)
    }

    /// Determines if a query should be expanded by the assistant.
    /// Short keywords, URLs, and code snippets are passed as-is.
    func shouldExpand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        // Only run for natural phrases (3 or more words), not exact identifiers
        guard words.count >= 3 else { return false }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return false }
        return true
    }

    /// Expands and directs the query for optimal embedding retrieval.
    /// Runs with strict sub-second timeouts to keep search instant.
    func expandQuery(_ query: String) async -> String? {
        guard shouldExpand(query) else { return nil }

        // If on-device Core ML model is downloaded or local Ollama is active
        let localReady = isLocalModelReady()
        let ollamaReady = localReady ? false : await checkOllama()
        if localReady || ollamaReady {
            if let llmKeywords = await requestOllamaExpansion(query) {
                return llmKeywords
            }
        }

        // Fast on-device linguistic normalization fallback (Apple NaturalLanguage)
        return fastLinguisticExpansion(query)
    }

    private func isLocalModelReady() -> Bool {
        guard let directory = RecallModelPaths.assistantCacheDirectory() else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(".ready").path)
    }

    // MARK: - Local LLM (Ollama / qwen2.5:0.5b)

    private func checkOllama() async -> Bool {
        if let cached = isOllamaAvailable, Date().timeIntervalSince(lastOllamaCheck) < 60 {
            return cached
        }

        guard let tagsURL = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        do {
            var request = URLRequest(url: tagsURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 0.3
            let (_, response) = try await session.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            isOllamaAvailable = ok
            lastOllamaCheck = Date()
            return ok
        } catch {
            isOllamaAvailable = false
            lastOllamaCheck = Date()
            return false
        }
    }

    private func requestOllamaExpansion(_ text: String) async -> String? {
        guard let endpoint else { return nil }

        let prompt = """
        User query for clipboard search: "\(text)"
        Output 3 to 6 essential search keywords and synonyms in English and Russian, separated by spaces. Output ONLY the keywords:
        """

        let payload: [String: Any] = [
            "model": defaultModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "num_predict": 24,
                "temperature": 0.1
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 0.55

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String
            else { return nil }

            let clean = responseText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return clean.isEmpty ? nil : clean
        } catch {
            return nil
        }
    }

    // MARK: - On-Device NLP Fallback

    private func fastLinguisticExpansion(_ text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text

        var keywords: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: options) { tag, range in
            let word = String(text[range]).lowercased()
            if let lemma = tag?.rawValue, lemma.count > 1 {
                keywords.append(lemma.lowercased())
            } else if word.count > 2 {
                keywords.append(word)
            }
            return true
        }

        let unique = Array(NSOrderedSet(array: keywords)).compactMap { $0 as? String }
        return unique.isEmpty ? nil : unique.joined(separator: " ")
    }
}
