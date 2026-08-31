import Foundation

/// The smallest HTTP request parser that is correct for our purposes.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// Returns `nil` while the request is still incomplete, so the caller keeps reading.
    public init?(raw: Data) {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = raw[raw.startIndex..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        // Strip any query string; nothing here uses one.
        path = String(parts[1]).components(separatedBy: "?")[0]

        var parsed: [String: String] = [:]
        for line in lines where line.contains(":") {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            parsed[pieces[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pieces[1].trimmingCharacters(in: .whitespaces)
        }
        headers = parsed

        let expectedLength = Int(parsed["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let available = raw.distance(from: bodyStart, to: raw.endIndex)
        guard available >= expectedLength else { return nil }   // keep reading

        body = expectedLength > 0
            ? raw[bodyStart..<raw.index(bodyStart, offsetBy: expectedLength)]
            : Data()
    }
}
