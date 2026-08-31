import Foundation

/// Minimal Atlassian Document Format builder.
///
/// Jira REST v3 will not accept a plain string for a worklog comment — it wants ADF, a
/// JSON document tree. Rather than pull in a dependency to emit four nested dictionaries,
/// this builds the one document shape worklog comments ever need: a paragraph per line.
public enum ADF {
    /// Wraps plain text into an ADF document, one paragraph per newline-separated line.
    /// Returns `nil` for empty input so callers can omit the field entirely.
    public static func document(from text: String?) -> [String: Any]? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let paragraphs = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> [String: Any] in
                let trimmed = String(line)
                // An empty paragraph must have no content array at all; ADF rejects an
                // empty text node.
                guard !trimmed.isEmpty else { return ["type": "paragraph"] }
                return [
                    "type": "paragraph",
                    "content": [["type": "text", "text": trimmed]],
                ]
            }

        return ["type": "doc", "version": 1, "content": paragraphs]
    }

    /// Flattens an ADF document back to plain text — used when displaying worklog comments
    /// that Jira sends us during reconciliation.
    public static func plainText(from document: Any?) -> String {
        guard let node = document else { return "" }
        return String(extract(node).joined(separator: "").prefix(2000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extract(_ node: Any) -> [String] {
        if let dict = node as? [String: Any] {
            let type = dict["type"] as? String
            var parts: [String] = []
            if type == "text", let text = dict["text"] as? String { parts.append(text) }
            if let content = dict["content"] as? [Any] {
                parts.append(contentsOf: content.flatMap(extract))
            }
            // Paragraphs and list items become line breaks so the text stays readable.
            if type == "paragraph" || type == "listItem" || type == "heading" { parts.append("\n") }
            return parts
        }
        if let array = node as? [Any] { return array.flatMap(extract) }
        if let text = node as? String { return [text] }
        return []
    }
}
