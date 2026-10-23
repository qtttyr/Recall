import Foundation

/// The kind of content Recall remembers. Kept deliberately small: every extra
/// type is another decision the user has to make. The classifier decides for them.
enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
    case code
    case image

    var label: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .code: "Code"
        case .image: "Image"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "arrow.up.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        }
    }
}

/// A row in the local memory. Everything is value-typed so it can cross actor
/// boundaries without surprises.
struct ClipItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let kind: ItemKind
    let text: String
    let sourceApp: String?
    let sourceBundle: String?
    let createdAt: Date
    let isFavorite: Bool
    let imagePath: String?
    let hash: String

    /// One-line representation for the panel. Newlines are flattened because
    /// the list is intentionally a single visual rhythm, not a document viewer.
    var displayText: String {
        if kind == .image {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Image" : trimmed
        }
        let flattened = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened
    }

    var subtitle: String {
        var parts: [String] = []
        if let sourceApp, !sourceApp.isEmpty {
            parts.append(sourceApp)
        } else {
            parts.append(kind.label)
        }
        if kind == .link, let host = URL(string: text)?.host {
            parts.append(host)
        }
        parts.append(RelativeTime.string(from: createdAt))
        return parts.joined(separator: "  ·  ")
    }
}

/// A captured pasteboard value before it gets an identity in SQLite.
struct ClipCandidate: Sendable {
    let kind: ItemKind
    let text: String
    let sourceApp: String?
    let sourceBundle: String?
    let imageData: Data?
    let hash: String
}

enum RelativeTime {
    static func string(from date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default:
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
