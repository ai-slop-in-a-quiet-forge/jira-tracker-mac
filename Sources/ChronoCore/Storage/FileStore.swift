import Foundation

/// Reads and writes Codable values as JSON files, atomically.
///
/// Two properties matter more than anything else here, because this is where the user's
/// timesheet lives:
///
/// 1. **A crash mid-write must never truncate the history.** Writes go to a temporary file and
///    are swapped in with an atomic replace.
/// 2. **A file from a different app version must never wipe the user's data.** Rather than
///    failing to decode when a field has been added or removed, `loadMerging` layers the
///    stored JSON over the JSON of a default value, so missing keys fall back to defaults and
///    unknown keys are ignored.
public struct FileStore: Sendable {
    public let directory: URL

    /// `FileManager` is not `Sendable`, so it is reached through the shared instance rather
    /// than stored. Every call made here (create, replace, move, remove, contentsOfDirectory)
    /// is documented as thread-safe on the default manager.
    private var fileManager: FileManager { .default }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Chrono` (or the sandbox equivalent).
    public static func applicationSupport(appName: String = "Chrono") throws -> FileStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return FileStore(directory: base.appendingPathComponent(appName, isDirectory: true))
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func exists(_ name: String) -> Bool {
        fileManager.fileExists(atPath: url(for: name).path)
    }

    // MARK: - Encoders

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys keep the file diff-friendly, which matters if a user ever puts their
        // Chrono directory in a private git repo or Dropbox.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Write

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try ensureDirectoryExists()
        let data = try Self.makeEncoder().encode(value)
        let target = url(for: name)

        // Write to a sibling temp file, then atomically swap. `.atomic` alone would be
        // enough on APFS, but doing it explicitly keeps the behaviour obvious.
        let temp = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        defer { try? fileManager.removeItem(at: temp) }

        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: target)
        }
    }

    // MARK: - Read

    /// Strict load. Returns `nil` when the file is simply absent; throws when it is present
    /// but unreadable.
    public func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let target = url(for: name)
        guard fileManager.fileExists(atPath: target.path) else { return nil }
        let data = try Data(contentsOf: target)
        guard !data.isEmpty else { return nil }
        return try Self.makeDecoder().decode(type, from: data)
    }

    /// Best-effort load: absent, unreadable and undecodable all collapse to `nil`.
    /// Saves every call site from juggling the double optional that `try?` produces here.
    public func loadOptional<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        do { return try load(type, from: name) } catch { return nil }
    }

    /// Forgiving load, used for everything the app must be able to start without.
    ///
    /// The stored JSON is merged *over* the encoded form of `defaults`, so a file written by
    /// an older version that lacks newly-added fields still loads cleanly. A file that cannot
    /// be salvaged is moved aside rather than deleted, so the user (or a bug report) can still
    /// get at it.
    public func loadMerging<T: Codable>(defaults: T, from name: String) -> (value: T, recovered: Bool) {
        let target = url(for: name)
        guard fileManager.fileExists(atPath: target.path),
              let data = try? Data(contentsOf: target),
              !data.isEmpty
        else { return (defaults, false) }

        let decoder = Self.makeDecoder()

        // Fast path: the file is already complete and current.
        if let value = try? decoder.decode(T.self, from: data) { return (value, false) }

        // Slow path: merge over defaults and try again.
        if let merged = try? mergedData(stored: data, defaults: defaults),
           let value = try? decoder.decode(T.self, from: merged) {
            return (value, true)
        }

        quarantine(target)
        return (defaults, true)
    }

    /// Deep-merges the stored object over the defaults object at the JSON level.
    private func mergedData<T: Encodable>(stored: Data, defaults: T) throws -> Data {
        let defaultsData = try Self.makeEncoder().encode(defaults)
        guard
            let defaultsObject = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
            let storedObject = try JSONSerialization.jsonObject(with: stored) as? [String: Any]
        else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let merged = Self.deepMerge(base: defaultsObject, overlay: storedObject)
        return try JSONSerialization.data(withJSONObject: merged)
    }

    /// Overlay wins for scalars and arrays; dictionaries recurse. Arrays are replaced rather
    /// than concatenated — for a settings list like "meeting app bundle IDs", the user's saved
    /// list is the truth, not the union with ours.
    static func deepMerge(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, overlayValue) in overlay {
            if let overlayDict = overlayValue as? [String: Any],
               let baseDict = result[key] as? [String: Any] {
                result[key] = deepMerge(base: baseDict, overlay: overlayDict)
            } else {
                result[key] = overlayValue
            }
        }
        return result
    }

    /// Moves an unreadable file out of the way with a timestamped name.
    private func quarantine(_ target: URL) {
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        let ruined = directory.appendingPathComponent("\(target.lastPathComponent).corrupt-\(stamp)")
        try? fileManager.moveItem(at: target, to: ruined)
    }

    // MARK: - Housekeeping

    public func listFiles(withPrefix prefix: String) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix(prefix) }
            .sorted() ?? []
    }

    public func delete(_ name: String) throws {
        let target = url(for: name)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }
}

extension ISO8601DateFormatter {
    /// `20240521T091300Z` — safe to embed in a filename on every platform.
    static let filenameSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return f
    }()
}
