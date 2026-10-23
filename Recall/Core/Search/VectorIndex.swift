import Accelerate
import Foundation

/// A contiguous in-memory vector matrix per language. For the sizes Recall is
/// designed for (tens of thousands of short clipboard items) a brute-force
/// BLAS pass is both simpler and faster than maintaining an ANN index.
actor VectorIndex {
    private struct Set {
        var ids: [Int64] = []
        var matrix: [Float] = []
        var dimensions: Int = 0

        var count: Int { ids.count }
    }

    private var sets: [String: Set] = [:]

    func rebuild(from store: ClipStore, provider: String) async throws {
        let records = try await store.vectorRecords(provider: provider)
        var grouped: [String: [VectorRecord]] = [:]
        for record in records {
            grouped[record.language, default: []].append(record)
        }

        var next: [String: Set] = [:]
        for (language, records) in grouped {
            guard let dimensions = records.first?.vector.count, dimensions > 0 else { continue }
            var set = Set(dimensions: dimensions)
            set.ids.reserveCapacity(records.count)
            set.matrix.reserveCapacity(records.count * dimensions)
            for record in records where record.vector.count == dimensions {
                set.ids.append(record.id)
                set.matrix.append(contentsOf: record.vector)
            }
            next[language] = set
        }
        sets = next
    }

    func upsert(id: Int64, language: String, vector: [Float]) {
        guard !vector.isEmpty else { return }
        if var set = sets[language] {
            guard set.dimensions == vector.count else { return }
            if let index = set.ids.firstIndex(of: id) {
                let start = index * set.dimensions
                set.matrix.replaceSubrange(start..<(start + set.dimensions), with: vector)
            } else {
                set.ids.append(id)
                set.matrix.append(contentsOf: vector)
            }
            sets[language] = set
        } else {
            var set = Set(dimensions: vector.count)
            set.ids = [id]
            set.matrix = vector
            sets[language] = set
        }
    }

    func remove(id: Int64, language: String) {
        guard var set = sets[language], let index = set.ids.firstIndex(of: id) else { return }
        let start = index * set.dimensions
        set.matrix.removeSubrange(start..<(start + set.dimensions))
        set.ids.remove(at: index)
        sets[language] = set
    }

    func search(
        query: [Float],
        language: String,
        limit: Int,
        minimumScore: Float = -1
    ) -> [(id: Int64, score: Float)] {
        guard let set = sets[language],
              set.dimensions == query.count,
              !set.ids.isEmpty,
              limit > 0
        else { return [] }

        var scores = [Float](repeating: 0, count: set.ids.count)
        set.matrix.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { vector in
                scores.withUnsafeMutableBufferPointer { output in
                    cblas_sgemv(
                        CblasRowMajor,
                        CblasNoTrans,
                        Int32(set.ids.count),
                        Int32(set.dimensions),
                        1,
                        matrix.baseAddress,
                        Int32(set.dimensions),
                        vector.baseAddress,
                        1,
                        0,
                        output.baseAddress,
                        1
                    )
                }
            }
        }

        let ranked = scores.indices
            .filter { minimumScore < 0 || scores[$0] >= minimumScore }
            .sorted { lhs, rhs in
                if scores[lhs] == scores[rhs] {
                    return set.ids[lhs] < set.ids[rhs]
                }
                return scores[lhs] > scores[rhs]
            }
            .prefix(limit)

        return ranked.map { (set.ids[$0], scores[$0]) }
    }

    func count(language: String) -> Int {
        sets[language]?.count ?? 0
    }

    var totalCount: Int {
        sets.values.reduce(0) { $0 + $1.count }
    }
}
