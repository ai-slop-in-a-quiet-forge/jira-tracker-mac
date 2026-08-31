import Foundation
import ChronoCore

/// Reads secrets through the 1Password CLI.
///
/// Present because storing an API token in a plaintext file (or even asking the user to paste
/// one) is worse than reading it from the vault they already keep it in. Entirely optional: if
/// `op` is missing or locked, Chrono falls back to the Keychain and says so.
public enum OnePassword {

    public enum Failure: Error, LocalizedError {
        case notInstalled
        case notSignedIn
        case referenceNotFound(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The 1Password CLI (op) is not installed."
            case .notSignedIn:
                return "1Password is locked. Unlock it and try again."
            case .referenceNotFound(let reference):
                return "1Password could not find \(reference)."
            case .failed(let detail):
                return "1Password returned an error: \(detail)"
            }
        }
    }

    /// Where `op` usually lives. `Process` does not consult a login shell, so PATH is not
    /// inherited when the app is launched from Finder or as a login item.
    private static let candidatePaths = [
        "/opt/homebrew/bin/op",
        "/usr/local/bin/op",
        "/usr/bin/op",
    ]

    public static func executableURL() -> URL? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static var isAvailable: Bool { executableURL() != nil }

    /// Resolves an `op://Vault/Item/field` reference.
    public static func read(reference: String) async -> Result<String, Failure> {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("op://") else {
            return .failure(.failed("A 1Password reference must start with op://"))
        }
        guard let executable = executableURL() else { return .failure(.notInstalled) }

        return await withCheckedContinuation { continuation in
            // Off the main actor: `op` can take a second, and may block on biometric approval.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(executable: executable, reference: trimmed))
            }
        }
    }

    private static func run(executable: URL, reference: String) -> Result<String, Failure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["read", "--no-newline", reference]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(.notInstalled)
        }

        // Read before waiting, so a large value cannot fill the pipe buffer and deadlock.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let secret = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let lowered = errorText.lowercased()
            if lowered.contains("not signed in") || lowered.contains("authorization") || lowered.contains("session") {
                return .failure(.notSignedIn)
            }
            if lowered.contains("isn't an item") || lowered.contains("not found") || lowered.contains("no item") {
                return .failure(.referenceNotFound(reference))
            }
            // Never surface the raw error verbatim without bounding it; op can be chatty.
            return .failure(.failed(String(errorText.prefix(200))))
        }
        guard !secret.isEmpty else { return .failure(.referenceNotFound(reference)) }
        return .success(secret)
    }
}
