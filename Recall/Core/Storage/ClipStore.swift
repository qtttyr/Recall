import Foundation

struct StoreStats: Sendable, Equatable {
    var itemCount: Int
    var favoriteCount: Int
    var indexedCount: Int
    var databaseBytes: Int64
    var oldestItem: Date?
}

struct VectorRecord: Sendable {
    let id: Int64
    let language: String
    let vector: [Float]
}

/// The single owner of the SQLite connection. Everything that touches disk or
/// FTS5 goes through this actor, so the UI never blocks on I/O.
actor ClipStore {
    nonisolated let databaseURL: URL
    nonisolated let imagesDirectory: URL
    private let database: SQLiteDatabase

    init(databaseURL: URL? = nil, imagesDirectory: URL? = nil) throws {
        let fileManager = FileManager.default
        let defaultRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Recall", isDirectory: true)

        let resolvedDatabaseURL = databaseURL ?? defaultRoot.appendingPathComponent("recall.sqlite")
        let resolvedImagesDirectory = imagesDirectory ?? defaultRoot.appendingPathComponent("Images", isDirectory: true)

        try fileManager.createDirectory(
            at: resolvedDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: resolvedImagesDirectory, withIntermediateDirectories: true)

        self.databaseURL = resolvedDatabaseURL
        self.imagesDirectory = resolvedImagesDirectory
        self.database = try SQLiteDatabase(path: resolvedDatabaseURL.path)
        try Self.migrate(database)
        try Self.rebuildFTSIfNeeded(database)
    }

    // MARK: - Schema

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                source_app TEXT,
                source_bundle TEXT,
                created_at REAL NOT NULL,
                favorite INTEGER NOT NULL DEFAULT 0,
                content_hash TEXT NOT NULL UNIQUE,
                image_path TEXT,
                embedding BLOB,
                embedding_language TEXT,
                embedding_provider TEXT
            );
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS items_created_idx ON items(created_at DESC);")
        try database.execute("CREATE INDEX IF NOT EXISTS items_kind_idx ON items(kind);")
        try database.execute("CREATE INDEX IF NOT EXISTS items_favorite_idx ON items(favorite);")
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                text,
                content='items',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, text) VALUES (new.id, new.text);
            END;
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF text ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO items_fts(rowid, text) VALUES (new.id, new.text);
            END;
            """)
        try database.execute("PRAGMA user_version = 1;")
    }

    private static func rebuildFTSIfNeeded(_ database: SQLiteDatabase) throws {
        let items = try database.prepare("SELECT count(*) FROM items;")
        _ = try items.step()
        let itemCount = items.int(at: 0)

        let fts = try database.prepare("SELECT count(*) FROM items_fts;")
        _ = try fts.step()
        let ftsCount = fts.int(at: 0)

        if itemCount != ftsCount {
            try database.execute("INSERT INTO items_fts(items_fts) VALUES('rebuild');")
        }
    }

    // MARK: - Writing

    /// Returns the stored item, or nil when the write was ignored. Re-copying
    /// existing content refreshes its timestamp instead of creating a duplicate.
    @discardableResult
    func insert(_ candidate: ClipCandidate) throws -> ClipItem? {
        let trimmedText = String(candidate.text.prefix(1_000_000))
        let now = Date()

        let existing = try database.prepare("SELECT id FROM items WHERE content_hash = ? LIMIT 1;")
        existing.bind(candidate.hash, at: 1)
        if try existing.step() {
            let id = existing.int64(at: 0)
            let update = try database.prepare("""
                UPDATE items
                SET created_at = ?, source_app = ?, source_bundle = ?
                WHERE id = ?;
                """)
            update.bind(now.timeIntervalSince1970, at: 1)
            update.bind(candidate.sourceApp, at: 2)
            update.bind(candidate.sourceBundle, at: 3)
            update.bind(id, at: 4)
            try update.step()
            return try item(id: id)
        }

        var imagePath: String?
        if let data = candidate.imageData {
            let url = imagesDirectory.appendingPathComponent("\(candidate.hash).png")
            try data.write(to: url, options: .atomic)
            imagePath = url.path
        }

        let statement = try database.prepare("""
            INSERT INTO items (kind, text, source_app, source_bundle, created_at, content_hash, image_path)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
        statement.bind(candidate.kind.rawValue, at: 1)
        statement.bind(trimmedText, at: 2)
        statement.bind(candidate.sourceApp, at: 3)
        statement.bind(candidate.sourceBundle, at: 4)
        statement.bind(now.timeIntervalSince1970, at: 5)
        statement.bind(candidate.hash, at: 6)
        statement.bind(imagePath, at: 7)
        try statement.step()

        return try item(id: database.lastInsertedRowID())
    }

    func touch(id: Int64) throws {
        let statement = try database.prepare("UPDATE items SET created_at = ? WHERE id = ?;")
        statement.bind(Date().timeIntervalSince1970, at: 1)
        statement.bind(id, at: 2)
        try statement.step()
    }

    func setFavorite(id: Int64, favorite: Bool) throws {
        let statement = try database.prepare("UPDATE items SET favorite = ? WHERE id = ?;")
        statement.bind(favorite, at: 1)
        statement.bind(id, at: 2)
        try statement.step()
    }

    func delete(id: Int64) throws {
        if let path = try imagePath(id: id) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let statement = try database.prepare("DELETE FROM items WHERE id = ?;")
        statement.bind(id, at: 1)
        try statement.step()
    }

    func deleteAll() throws {
        let paths = try database.prepare("SELECT image_path FROM items WHERE image_path IS NOT NULL;")
        while try paths.step() {
            if let path = paths.optionalText(at: 0) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try database.execute("DELETE FROM items;")
        try database.execute("INSERT INTO items_fts(items_fts) VALUES('rebuild');")
        try database.execute("VACUUM;")
    }

    func prune(retentionDays: Int, maxItems: Int) throws {
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
            let expired = try database.prepare("""
                SELECT image_path FROM items
                WHERE favorite = 0 AND created_at < ? AND image_path IS NOT NULL;
                """)
            expired.bind(cutoff, at: 1)
            while try expired.step() {
                if let path = expired.optionalText(at: 0) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }

            let deleteExpired = try database.prepare("DELETE FROM items WHERE favorite = 0 AND created_at < ?;")
            deleteExpired.bind(cutoff, at: 1)
            try deleteExpired.step()
        }

        let overflow = try database.prepare("""
            SELECT image_path FROM items
            WHERE favorite = 0 AND id NOT IN (
                SELECT id FROM items ORDER BY created_at DESC LIMIT ?
            ) AND image_path IS NOT NULL;
            """)
        overflow.bind(maxItems, at: 1)
        while try overflow.step() {
            if let path = overflow.optionalText(at: 0) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let deleteOverflow = try database.prepare("""
            DELETE FROM items
            WHERE favorite = 0 AND id NOT IN (
                SELECT id FROM items ORDER BY created_at DESC LIMIT ?
            );
            """)
        deleteOverflow.bind(maxItems, at: 1)
        try deleteOverflow.step()
    }

    func setEmbedding(id: Int64, vector: [Float], language: String, provider: String) throws {
        let data = vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let statement = try database.prepare("""
            UPDATE items
            SET embedding = ?, embedding_language = ?, embedding_provider = ?
            WHERE id = ?;
            """)
        statement.bind(data, at: 1)
        statement.bind(language, at: 2)
        statement.bind(provider, at: 3)
        statement.bind(id, at: 4)
        try statement.step()
    }

    /// Marks an item as permanently failed for the active provider so that
    /// the background indexing loop doesn't get stuck on it in an infinite retry loop.
    func markEmbeddingFailed(id: Int64, provider: String) throws {
        let statement = try database.prepare("""
            UPDATE items
            SET embedding = X'', embedding_language = 'failed', embedding_provider = ?
            WHERE id = ?;
            """)
        statement.bind(provider, at: 1)
        statement.bind(id, at: 2)
        try statement.step()
    }

    // MARK: - Reading

    func recent(limit: Int, filter: ItemFilter) throws -> [ClipItem] {
        var sql = "SELECT * FROM items"
        var clauses: [String] = []
        if filter.kind != nil {
            clauses.append("kind = ?")
        }
        if filter == .favorite {
            clauses.append("favorite = 1")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY favorite DESC, created_at DESC LIMIT ?;"

        let statement = try database.prepare(sql)
        var index: Int32 = 1
        if let kind = filter.kind {
            statement.bind(kind.rawValue, at: index)
            index += 1
        }
        statement.bind(limit, at: index)

        var items: [ClipItem] = []
        while try statement.step() {
            items.append(decode(statement))
        }
        return items
    }

    func ftsSearch(expression: String, filter: ItemFilter, dateRange: DateRange?, limit: Int) throws -> [ClipItem] {
        var sql = """
            SELECT items.* FROM items_fts
            JOIN items ON items.id = items_fts.rowid
            WHERE items_fts MATCH ?
            """
        var bindings: [SQLiteBinding] = [.text(expression)]

        if let kind = filter.kind {
            sql += " AND items.kind = ?"
            bindings.append(.text(kind.rawValue))
        }
        if filter == .favorite {
            sql += " AND items.favorite = 1"
        }
        if let start = dateRange?.start {
            sql += " AND items.created_at >= ?"
            bindings.append(.double(start.timeIntervalSince1970))
        }
        if let end = dateRange?.end {
            sql += " AND items.created_at < ?"
            bindings.append(.double(end.timeIntervalSince1970))
        }
        sql += " ORDER BY bm25(items_fts), items.created_at DESC LIMIT ?;"
        bindings.append(.int(limit))

        let statement = try database.prepare(sql)
        for (offset, binding) in bindings.enumerated() {
            binding.bind(statement, at: Int32(offset + 1))
        }

        var items: [ClipItem] = []
        while try statement.step() {
            items.append(decode(statement))
        }
        return items
    }

    func items(ids: [Int64]) throws -> [ClipItem] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let statement = try database.prepare("SELECT * FROM items WHERE id IN (\(placeholders));")
        for (offset, id) in ids.enumerated() {
            statement.bind(id, at: Int32(offset + 1))
        }
        var byID: [Int64: ClipItem] = [:]
        while try statement.step() {
            let item = decode(statement)
            byID[item.id] = item
        }
        return ids.compactMap { byID[$0] }
    }

    func item(id: Int64) throws -> ClipItem? {
        let statement = try database.prepare("SELECT * FROM items WHERE id = ? LIMIT 1;")
        statement.bind(id, at: 1)
        return try statement.step() ? decode(statement) : nil
    }

    func missingEmbeddings(provider: String, limit: Int) throws -> [ClipItem] {
        let statement = try database.prepare("""
            SELECT * FROM items
            WHERE length(text) > 0
              AND (embedding IS NULL OR embedding_provider IS NULL OR embedding_provider != ?)
            ORDER BY created_at DESC
            LIMIT ?;
            """)
        statement.bind(provider, at: 1)
        statement.bind(limit, at: 2)
        var items: [ClipItem] = []
        while try statement.step() {
            items.append(decode(statement))
        }
        return items
    }

    func vectorRecords(provider: String) throws -> [VectorRecord] {
        let statement = try database.prepare("""
            SELECT id, embedding, embedding_language FROM items
            WHERE embedding IS NOT NULL
              AND length(embedding) > 0
              AND embedding_provider = ?
              AND embedding_language IS NOT NULL
              AND embedding_language != 'failed';
            """)
        statement.bind(provider, at: 1)
        var records: [VectorRecord] = []
        while try statement.step() {
            guard let data = statement.data(at: 1),
                  !data.isEmpty,
                  data.count % MemoryLayout<Float>.size == 0,
                  let language = statement.optionalText(at: 2)
            else { continue }
            let vector = data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            records.append(VectorRecord(id: statement.int64(at: 0), language: language, vector: vector))
        }
        return records
    }

    func stats(provider: String? = nil) throws -> StoreStats {
        let statement = try database.prepare("""
            SELECT count(*),
                   sum(CASE WHEN favorite = 1 THEN 1 ELSE 0 END),
                   sum(CASE
                       WHEN embedding IS NOT NULL
                            AND length(embedding) > 0
                            AND embedding_language != 'failed'
                            AND (? IS NULL OR embedding_provider = ?)
                       THEN 1 ELSE 0
                   END),
                   min(created_at)
            FROM items;
            """)
        statement.bind(provider, at: 1)
        statement.bind(provider, at: 2)
        _ = try statement.step()
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let oldest = statement.double(at: 3)
        return StoreStats(
            itemCount: statement.int(at: 0),
            favoriteCount: statement.int(at: 1),
            indexedCount: statement.int(at: 2),
            databaseBytes: size,
            oldestItem: oldest > 0 ? Date(timeIntervalSince1970: oldest) : nil
        )
    }

    func exportJSON() throws -> Data {
        let statement = try database.prepare("SELECT * FROM items ORDER BY created_at DESC;")
        var rows: [ExportItem] = []
        while try statement.step() {
            let item = decode(statement)
            rows.append(ExportItem(
                kind: item.kind.rawValue,
                text: item.text,
                sourceApp: item.sourceApp,
                createdAt: item.createdAt,
                favorite: item.isFavorite
            ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(rows)
    }

    func imageURL(for item: ClipItem) -> URL? {
        item.imagePath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Helpers

    private func imagePath(id: Int64) throws -> String? {
        let statement = try database.prepare("SELECT image_path FROM items WHERE id = ?;")
        statement.bind(id, at: 1)
        guard try statement.step() else { return nil }
        return statement.optionalText(at: 0)
    }

    private func decode(_ statement: SQLiteStatement) -> ClipItem {
        ClipItem(
            id: statement.int64(at: 0),
            kind: ItemKind(rawValue: statement.text(at: 1)) ?? .text,
            text: statement.text(at: 2),
            sourceApp: statement.optionalText(at: 3),
            sourceBundle: statement.optionalText(at: 4),
            createdAt: Date(timeIntervalSince1970: statement.double(at: 5)),
            isFavorite: statement.bool(at: 6),
            imagePath: statement.optionalText(at: 8),
            hash: statement.text(at: 7)
        )
    }
}

private struct ExportItem: Codable {
    let kind: String
    let text: String
    let sourceApp: String?
    let createdAt: Date
    let favorite: Bool
}

private enum SQLiteBinding {
    case text(String)
    case int(Int)
    case double(Double)

    func bind(_ statement: SQLiteStatement, at index: Int32) {
        switch self {
        case .text(let value): statement.bind(value, at: index)
        case .int(let value): statement.bind(value, at: index)
        case .double(let value): statement.bind(value, at: index)
        }
    }
}
