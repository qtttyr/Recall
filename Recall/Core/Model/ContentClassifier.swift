import CryptoKit
import Foundation

/// Fast, deterministic content classification. No model, no network, no
/// latency: the first byte of intelligence in Recall is just observation.
enum ContentClassifier {
    static func classify(_ raw: String) -> ItemKind {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .text }

        if isLink(text) { return .link }
        if isCode(text) { return .code }
        return .text
    }

    static func hash(kind: ItemKind, text: String, imageData: Data? = nil) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        if let imageData {
            hasher.update(data: imageData)
        } else {
            hasher.update(data: Data(text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp"].contains(scheme),
              scheme == "mailto" || url.host != nil
        else { return false }
        return true
    }

    private static func isCode(_ text: String) -> Bool {
        // A URL with query parameters should stay a link, even if it has `=`.
        if isLink(text) { return false }

        let lowered = text.lowercased()
        let strongSignals = [
            "func ", "def ", "class ", "struct ", "enum ", "import ", "from ",
            "select ", "insert into ", "update ", "delete from ", "where ",
            "#include", "#!/", "console.log", "print(", "=>", "->",
            "<?php", "</", "/>", "{\n", "}\n", "};", "::"
        ]
        let weakSignals = ["{", "}", ";", "==", "!=", "&&", "||", " += ", " -= ", " = "]
        let loweredLines = lowered.split(separator: "\n", omittingEmptySubsequences: false)

        var score = 0
        for signal in strongSignals where lowered.contains(signal) { score += 2 }
        for signal in weakSignals where lowered.contains(signal) { score += 1 }

        let indented = loweredLines.dropFirst().contains { line in
            line.hasPrefix("  ") || line.hasPrefix("\t")
        }
        if indented { score += 1 }

        // A shell command or a stack trace is code too.
        if lowered.hasPrefix("$ ") || lowered.hasPrefix("npm ") || lowered.hasPrefix("git ") ||
            lowered.hasPrefix("curl ") || lowered.hasPrefix("docker ") {
            score += 2
        }

        // Don't turn a short sentence with a brace into code.
        if text.count < 24, score < 4 { return false }
        return score >= 3
    }
}
