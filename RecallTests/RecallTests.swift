import Foundation
import Testing
@testable import Recall

@Suite("Content classification")
struct ContentClassificationTests {
    @Test("Links are links")
    func links() {
        #expect(ContentClassifier.classify("https://example.com/path?q=1") == .link)
        #expect(ContentClassifier.classify("mailto:hi@example.com") == .link)
    }

    @Test("Code is code")
    func code() {
        let snippet = """
        func greet(name: String) {
            print("hello \\(name)")
        }
        """
        #expect(ContentClassifier.classify(snippet) == .code)
        #expect(ContentClassifier.classify("SELECT * FROM users WHERE id = 1;") == .code)
    }

    @Test("Prose stays prose")
    func prose() {
        #expect(ContentClassifier.classify("Hello, how are you?") == .text)
        #expect(ContentClassifier.classify("A short note about the weekend.") == .text)
    }

    @Test("Hashes are stable and content-sensitive")
    func hashes() {
        let a = ContentClassifier.hash(kind: .text, text: "hello")
        let b = ContentClassifier.hash(kind: .text, text: "hello")
        let c = ContentClassifier.hash(kind: .text, text: "hello!")
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("Query parsing")
struct QueryParsingTests {
    @Test("Trailing filters are extracted")
    func trailingFilter() {
        let query = SearchQueryParser.parse("postgres query code")
        #expect(query.filter == .code)
        #expect(query.text == "postgres query")
    }

    @Test("Explicit filters work")
    func explicitFilter() {
        let query = SearchQueryParser.parse("type:link docs")
        #expect(query.filter == .link)
        #expect(query.text == "docs")
    }

    @Test("Russian yesterday is a date range")
    func russianYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        let query = SearchQueryParser.parse("ошибка вчера", now: now, calendar: calendar)
        #expect(query.text == "ошибка")
        #expect(query.dateRange?.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 21)))
    }

    @Test("FTS expression quotes and prefixes tokens")
    func ftsExpression() {
        let expression = SearchQueryParser.ftsExpression(for: "sql query")
        #expect(expression == "\"sql\"* AND \"query\"*")
    }

    @Test("Empty text has no FTS expression")
    func emptyExpression() {
        #expect(SearchQueryParser.ftsExpression(for: "   ... ") == nil)
    }
}

@Suite("Storage and ranking")
struct StorageTests {
    @Test("Insert, deduplicate, search, favorite, delete")
    func lifecycle() async throws {
        let store = try makeStore()
        let hash = ContentClassifier.hash(kind: .text, text: "Postgres query with joins")
        let first = try await store.insert(ClipCandidate(
            kind: .text,
            text: "Postgres query with joins",
            sourceApp: "Terminal",
            sourceBundle: "com.apple.Terminal",
            imageData: nil,
            hash: hash
        ))
        #expect(first != nil)

        let duplicate = try await store.insert(ClipCandidate(
            kind: .text,
            text: "Postgres query with joins",
            sourceApp: "Terminal",
            sourceBundle: "com.apple.Terminal",
            imageData: nil,
            hash: hash
        ))
        #expect(duplicate?.id == first?.id)

        let recent = try await store.recent(limit: 10, filter: .all)
        #expect(recent.count == 1)

        let expression = SearchQueryParser.ftsExpression(for: "postgres")
        let matches = try await store.ftsSearch(expression: expression!, filter: .all, dateRange: nil, limit: 10)
        #expect(matches.count == 1)

        try await store.setFavorite(id: first!.id, favorite: true)
        let favorites = try await store.recent(limit: 10, filter: .favorite)
        #expect(favorites.count == 1)

        try await store.delete(id: first!.id)
        let empty = try await store.recent(limit: 10, filter: .all)
        #expect(empty.isEmpty)
    }

    @Test("Vectors round-trip")
    func vectors() async throws {
        let store = try makeStore()
        let hash = ContentClassifier.hash(kind: .text, text: "semantic")
        let item = try await store.insert(ClipCandidate(
            kind: .text,
            text: "semantic",
            sourceApp: nil,
            sourceBundle: nil,
            imageData: nil,
            hash: hash
        ))!
        try await store.setEmbedding(id: item.id, vector: [0.1, 0.2, 0.3], language: "en", provider: "test")
        let records = try await store.vectorRecords(provider: "test")
        #expect(records.count == 1)
        #expect(records[0].language == "en")
        #expect(records[0].vector.count == 3)
    }

    @Test("Poison pill prevention: failed embeddings are not returned by missingEmbeddings")
    func failedEmbeddings() async throws {
        let store = try makeStore()
        let item = try await store.insert(ClipCandidate(
            kind: .text,
            text: "malformed text",
            sourceApp: nil,
            sourceBundle: nil,
            imageData: nil,
            hash: ContentClassifier.hash(kind: .text, text: "malformed text")
        ))!
        let missingBefore = try await store.missingEmbeddings(provider: "gemma", limit: 10)
        #expect(missingBefore.count == 1)

        try await store.markEmbeddingFailed(id: item.id, provider: "gemma")
        let missingAfter = try await store.missingEmbeddings(provider: "gemma", limit: 10)
        #expect(missingAfter.isEmpty)

        // Switching to another provider should allow retrying under the new provider
        let missingOther = try await store.missingEmbeddings(provider: "other", limit: 10)
        #expect(missingOther.count == 1)
    }

    @Test("Maximum item pruning keeps favorites")
    func pruning() async throws {
        let store = try makeStore()
        for index in 0..<4 {
            let text = "item \(index)"
            _ = try await store.insert(ClipCandidate(
                kind: .text,
                text: text,
                sourceApp: nil,
                sourceBundle: nil,
                imageData: nil,
                hash: ContentClassifier.hash(kind: .text, text: text)
            ))
        }
        let all = try await store.recent(limit: 10, filter: .all)
        try await store.setFavorite(id: all[0].id, favorite: true)
        try await store.prune(retentionDays: 0, maxItems: 1)
        let remaining = try await store.recent(limit: 10, filter: .all)
        #expect(remaining.count == 1)
        #expect(remaining[0].isFavorite)
    }

    private func makeStore() throws -> ClipStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try ClipStore(
            databaseURL: root.appendingPathComponent("test.sqlite"),
            imagesDirectory: root.appendingPathComponent("Images", isDirectory: true)
        )
    }
}

@Suite("Rank fusion")
struct RankFusionTests {
    @Test("An item present in both lists wins")
    func fusion() {
        let now = Date()
        let a = ClipItem(id: 1, kind: .text, text: "a", sourceApp: nil, sourceBundle: nil, createdAt: now, isFavorite: false, imagePath: nil, hash: "a")
        let b = ClipItem(id: 2, kind: .text, text: "b", sourceApp: nil, sourceBundle: nil, createdAt: now, isFavorite: false, imagePath: nil, hash: "b")
        let fused = RankFusion.fuse(keyword: [a], semantic: [b, a], limit: 2, now: now)
        #expect(fused.first?.id == a.id)
    }
}
