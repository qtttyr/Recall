import Foundation

enum ItemFilter: String, CaseIterable, Sendable {
    case all
    case text
    case code
    case link
    case image
    case favorite

    var label: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .code: "Code"
        case .link: "Links"
        case .image: "Images"
        case .favorite: "Pinned"
        }
    }

    var shortLabel: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .code: "Code"
        case .link: "Links"
        case .image: "Images"
        case .favorite: "Pinned"
        }
    }

    var kind: ItemKind? {
        switch self {
        case .text: .text
        case .code: .code
        case .link: .link
        case .image: .image
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .image: "photo"
        case .favorite: "pin"
        }
    }

    /// Pinned is a deliberate power filter: reachable with `#fav` and `⌘D`,
    /// but not one of the five circles in the resting search bar.
    static let visibleCases: [ItemFilter] = [.all, .text, .code, .link, .image]

    var next: ItemFilter {
        move(by: 1)
    }

    var previous: ItemFilter {
        move(by: -1)
    }

    private func move(by delta: Int) -> ItemFilter {
        let cases = Self.visibleCases
        guard let index = cases.firstIndex(of: self) else { return .all }
        return cases[(index + delta + cases.count) % cases.count]
    }
}

struct DateRange: Sendable, Equatable {
    var start: Date?
    var end: Date?
}

struct SearchQuery: Sendable, Equatable {
    static let resultLimit = 5
    static let recentLimit = 6

    var raw: String
    var text: String
    var filter: ItemFilter
    var dateRange: DateRange?
    var limit: Int

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A deterministic parser for the 90% case. No model is loaded to understand
/// "вчера", "code", or "last week" — that would make the fast path slow.
enum SearchQueryParser {
    static func parse(
        _ raw: String,
        filter explicitFilter: ItemFilter = .all,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> SearchQuery {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var filter = explicitFilter
        var dateRange: DateRange?

        // Explicit filters: #code, type:link, kind:image, #fav.
        let filterPatterns: [(String, ItemFilter)] = [
            ("#code", .code), ("type:code", .code), ("kind:code", .code),
            ("#link", .link), ("type:link", .link), ("kind:link", .link),
            ("#image", .image), ("type:image", .image), ("kind:image", .image),
            ("#text", .text), ("type:text", .text), ("kind:text", .text),
            ("#fav", .favorite), ("#favorite", .favorite), ("type:favorite", .favorite)
        ]
        for (pattern, value) in filterPatterns {
            if let range = text.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) {
                filter = value
                text.removeSubrange(range)
            }
        }

        let lowered = text.lowercased()
        let dateMatches: [(String, DateRange?)] = [
            ("вчера", yesterday(in: now, calendar: calendar)),
            ("yesterday", yesterday(in: now, calendar: calendar)),
            ("сегодня", today(in: now, calendar: calendar)),
            ("today", today(in: now, calendar: calendar)),
            ("на прошлой неделе", lastWeek(in: now, calendar: calendar)),
            ("last week", lastWeek(in: now, calendar: calendar)),
            ("за неделю", lastDays(7, in: now)),
            ("this week", lastDays(7, in: now)),
            ("в этом месяце", lastDays(30, in: now)),
            ("this month", lastDays(30, in: now))
        ]
        for (phrase, range) in dateMatches where lowered.contains(phrase) {
            dateRange = range
            if let found = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                text.removeSubrange(found)
            }
            break
        }

        // A standalone trailing filter word is a natural shortcut, but only at
        // the end: "sql запрос code" should filter, "code review" should not.
        let words = text.split(whereSeparator: \.isWhitespace)
        if let last = words.last?.lowercased() {
            let trailing: [String: ItemFilter] = [
                "code": .code, "код": .code,
                "link": .link, "links": .link, "ссылка": .link, "ссылки": .link,
                "image": .image, "images": .image, "скриншот": .image, "картинка": .image,
                "fav": .favorite, "pinned": .favorite, "избранное": .favorite
            ]
            if let value = trailing[last], filter == .all {
                filter = value
                if let range = text.range(of: String(last), options: [.backwards, .caseInsensitive]) {
                    text.removeSubrange(range)
                }
            }
        }

        return SearchQuery(
            raw: raw,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: filter,
            dateRange: dateRange,
            limit: SearchQuery.resultLimit
        )
    }

    /// FTS5 is powerful but easy to upset with punctuation. Every token becomes
    /// a quoted prefix, joined with OR, and BM25 decides what matters.
    static func ftsExpression(for text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { token in
                token.count > 1 && !stopWords.contains(token)
            }
        guard !tokens.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = tokens.filter { seen.insert($0).inserted }
        return unique.prefix(10).map { token in
            "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"*"
        }.joined(separator: " AND ")
    }

    /// Function words that turn a natural-language query into a broad OR of
    /// one- and two-letter prefixes. Keyword search is the precision path;
    /// meaning is handled by the vector engine.
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "did",
        "do", "does", "for", "from", "had", "has", "have", "he", "her", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no",
        "not", "of", "on", "or", "our", "she", "so", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "to", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "will", "with",
        "you", "your",
        "а", "без", "бы", "был", "была", "были", "быть", "в", "во", "вот",
        "все", "всё", "вы", "где", "да", "для", "до", "его", "ее", "её", "если",
        "есть", "ещё", "же", "за", "здесь", "и", "из", "или", "их", "к", "как",
        "ко", "когда", "который", "которая", "которые", "котором", "которой",
        "ли", "мне", "можно", "мы", "на", "над", "не", "ни", "но", "нужно",
        "о", "об", "она", "они", "оно", "от", "по", "под", "после", "при",
        "про", "с", "со", "так", "там", "то", "тот", "тут", "у", "уже", "что",
        "чтобы", "эта", "эти", "это", "этот", "я"
    ]

    private static func yesterday(in now: Date, calendar: Calendar) -> DateRange? {
        guard let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return DateRange(start: start, end: end)
    }

    private static func today(in now: Date, calendar: Calendar) -> DateRange? {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateRange(start: start, end: end)
    }

    private static func lastWeek(in now: Date, calendar: Calendar) -> DateRange? {
        guard let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return DateRange(start: start, end: now)
    }

    private static func lastDays(_ days: Int, in now: Date) -> DateRange? {
        DateRange(start: now.addingTimeInterval(-Double(days) * 86_400), end: now)
    }
}
