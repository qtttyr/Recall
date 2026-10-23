import Foundation

struct SearchResults: Sendable {
    var items: [ClipItem]
    var semanticUsed: Bool
}

/// Hybrid retrieval: BM25 for precision, vectors for meaning, reciprocal rank
/// fusion for a stable blend. Deterministic by construction.
actor SearchEngine {
    private let store: ClipStore
    private let semantic: SemanticEngine
    private let vectorIndex: VectorIndex

    init(store: ClipStore, semantic: SemanticEngine, vectorIndex: VectorIndex) {
        self.store = store
        self.semantic = semantic
        self.vectorIndex = vectorIndex
    }

    func prepare() async {
        do {
            let provider = await semantic.currentProvider()
            try await vectorIndex.rebuild(from: store, provider: provider.id)
        } catch {
            // A cold index is not fatal: keyword search still works.
        }
    }

    func keyword(_ query: SearchQuery) async -> [ClipItem] {
        if query.isEmpty {
            return (try? await store.recent(limit: SearchQuery.recentLimit, filter: query.filter)) ?? []
        }
        guard let expression = SearchQueryParser.ftsExpression(for: query.text) else {
            return (try? await store.recent(limit: query.limit, filter: query.filter)) ?? []
        }
        return (try? await store.ftsSearch(
            expression: expression,
            filter: query.filter,
            dateRange: query.dateRange,
            limit: query.limit
        )) ?? []
    }

    func semantic(_ query: SearchQuery, keyword: [ClipItem]) async -> SearchResults {
        func fallback(_ reason: String) async -> SearchResults {
            var items = Array(keyword.prefix(query.limit))

            // A failed meaning match with no keyword hits is not "nothing
            // found": the user typed something and should see their history.
            // Recents keep the panel useful and the target is usually nearby.
            if items.isEmpty {
                let recents = (try? await store.recent(limit: query.limit, filter: query.filter)) ?? []
                items = Array(recents.prefix(query.limit))
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_LOG"] != nil {
                FileHandle.standardOutput.write("SEARCH fallback \(reason) \(items.count)\n".data(using: .utf8)!)
            }
            #endif
            return SearchResults(items: items, semanticUsed: false)
        }

        guard !query.isEmpty else {
            return await fallback("empty")
        }

        let bounds = await semantic.relevanceBounds()

        // Dual prompt views + optional AI assistant view of the same query.
        // The task view ("search result: …") matches phrased questions; the plain view
        // matches when the user types something that reads like a fragment of the clip itself.
        // The assistant view leverages ultra-lightweight local models (qwen2.5:0.5b) or NLP
        // to guide semantic direction. Taking the maximum per document fuses all worlds.
        async let queryViewTask = semantic.embed(query.text, asQuery: true)
        async let docViewTask = semantic.embed(query.text, asQuery: false)
        async let assistantViewTask: EmbeddedText? = {
            if let expanded = await QueryAssistant.shared.expandQuery(query.text) {
                return await semantic.embed(expanded, asQuery: true)
            }
            return nil
        }()
        let (queryView, docView, assistantView) = await (queryViewTask, docViewTask, assistantViewTask)
        guard queryView != nil || docView != nil || assistantView != nil else {
            return await fallback("no-embedding")
        }

        var best: [Int64: (score: Float, language: String)] = [:]
        let pool = query.limit * 8
        for view in [queryView, docView, assistantView].compactMap({ $0 }) {
            let hits = await vectorIndex.search(
                query: view.vector,
                language: view.language,
                limit: pool,
                minimumScore: bounds.floor
            )
            for hit in hits {
                if best[hit.id].map({ hit.score > $0.score }) ?? true {
                    best[hit.id] = (hit.score, view.language)
                }
            }
        }
        guard !best.isEmpty else {
            return await fallback("no-vectors")
        }
        let matches = best
            .map { (id: $0.key, score: $0.value.score, language: $0.value.language) }
            .sorted { $0.score > $1.score }
        let top = matches[0].score

        // Meaning needs evidence. Calibrated on dual-view scores: nonsense
        // queries peak below ~0.757 and never separate from the plateau, while
        // confident hits either clear ~0.76 or stand apart from the tail by a
        // visible margin. Failing both falls back to keyword / recents.
        let scores = matches.map(\.score)
        // Separation is measured against the tail (3rd place), not the pairs:
        // several documents of the same topic legitimately sit together at the
        // top, while noise is a flat plateau all the way down.
        let separation: Float
        if scores.count >= 3 {
            separation = top - scores[2]
        } else if scores.count == 2 {
            separation = top - scores[1]
        } else {
            separation = top
        }
        let confident = top >= bounds.confidentThreshold || separation >= bounds.separationThreshold
        if !confident {
            #if DEBUG
            if ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_LOG"] != nil {
                let previewIDs = matches.prefix(6).map(\.id)
                let fetched = ((try? await store.items(ids: previewIDs)) ?? [])
                let texts = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.displayText) })
                let preview = matches.prefix(6)
                    .map { "\($0.id):\(String(format: "%.3f", $0.score)) \(String((texts[$0.id] ?? "?").prefix(34)))" }
                    .joined(separator: " | ")
                FileHandle.standardOutput.write("SEARCH noise \(preview)\n".data(using: .utf8)!)
            }
            #endif
            return await fallback("no-gap \(String(format: "%.3f", top)) sep \(String(format: "%.3f", separation))")
        }

        // The model lives on a compressed similarity scale. The keep-band
        // width follows the measured separation: a real edge lets in its whole
        // cluster (a Russian note and its English twin both survive), a flat
        // plateau only keeps its very top. Capped so noise never leaks in.
        let tail = scores.count >= 3 ? scores[2] : (scores.count == 2 ? scores[1] : top)
        let adaptiveMargin = max(Float(0.04), min(bounds.margin * 1.2, max(0, top - tail) * 1.2))
        let cutoff = max(bounds.floor, top - adaptiveMargin)
        let relevant = matches.filter { $0.score >= cutoff }
        guard !relevant.isEmpty else {
            return await fallback("under-margin")
        }

        let ids = relevant.map(\.id)
        let vectorItems = ((try? await store.items(ids: ids)) ?? [])
            .filter { matchesSemanticFilter($0, query: query) }
        guard !vectorItems.isEmpty else {
            return await fallback("filtered-out")
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_LOG"] != nil {
            let scores = matches.prefix(10).map { "\($0.id):\(String(format: "%.3f", $0.score))" }.joined(separator: " ")
            let sem = vectorItems.map { "\($0.id):\(String($0.displayText.prefix(32)))" }.joined(separator: " | ")
            let key = keyword.map { "\($0.id):\(String($0.displayText.prefix(32)))" }.joined(separator: " | ")
            FileHandle.standardOutput.write("SEARCH scores \(scores)\nSEARCH semantic \(sem)\nSEARCH keyword \(key)\n".data(using: .utf8)!)
        }
        #endif
        // The vector set is the authority. Keyword matches may reorder those
        // items, but never add unrelated documents that merely share a stop
        // word. If the model finds nothing, the caller still gets keyword
        // precision above.
        let semanticIDs = Set(vectorItems.map(\.id))
        let overlappingKeyword = keyword.filter { semanticIDs.contains($0.id) }
        let fused = RankFusion.fuse(
            keyword: overlappingKeyword,
            semantic: vectorItems,
            limit: query.limit
        )
        return SearchResults(items: fused, semanticUsed: !vectorItems.isEmpty)
    }

    private func matchesFilter(_ item: ClipItem, query: SearchQuery) -> Bool {
        if query.filter == .favorite, !item.isFavorite { return false }
        if let kind = query.filter.kind, item.kind != kind { return false }
        if let start = query.dateRange?.start, item.createdAt < start { return false }
        if let end = query.dateRange?.end, item.createdAt >= end { return false }
        return true
    }

    /// "вчера" inside the query is part of what the user remembers saying, not
    /// a command to discard the best match. A clip copied today often contains
    /// the word "yesterday" in its text — so the meaning branch keeps the type
    /// filters but treats the parsed date as a hint, not a gate. The keyword
    /// branch above still honors the range strictly.
    private func matchesSemanticFilter(_ item: ClipItem, query: SearchQuery) -> Bool {
        if query.filter == .favorite, !item.isFavorite { return false }
        if let kind = query.filter.kind, item.kind != kind { return false }
        return true
    }
}

enum RankFusion {
    /// Reciprocal rank fusion with a very small recency/favorite prior. The
    /// priors are deliberately tiny: relevance should win, not novelty.
    static func fuse(keyword: [ClipItem], semantic: [ClipItem], limit: Int, now: Date = .now) -> [ClipItem] {
        var byID: [Int64: ClipItem] = [:]
        var scores: [Int64: Double] = [:]

        for (index, item) in keyword.enumerated() {
            byID[item.id] = item
            scores[item.id, default: 0] += 1.0 / (60.0 + Double(index + 1))
        }
        for (index, item) in semantic.enumerated() {
            byID[item.id] = item
            scores[item.id, default: 0] += 1.0 / (60.0 + Double(index + 1))
        }

        for (id, item) in byID {
            let ageDays = max(0, now.timeIntervalSince(item.createdAt) / 86_400)
            scores[id, default: 0] += 0.002 * exp(-ageDays / 30.0)
            if item.isFavorite { scores[id, default: 0] += 0.003 }
        }

        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    let left = byID[lhs.key]
                    let right = byID[rhs.key]
                    if left?.createdAt == right?.createdAt { return lhs.key > rhs.key }
                    return (left?.createdAt ?? .distantPast) > (right?.createdAt ?? .distantPast)
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .compactMap { byID[$0.key] }
    }
}
