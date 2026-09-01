import Foundation
import Observation
import ChronoCore

/// Reads the checked-out branch of each watched repository and offers the issue it names.
///
/// ## Why a configured list of directories
///
/// The alternatives are worse. Reading the frontmost window title guesses at a convention every
/// editor implements differently, and breaks silently when one changes. Watching the filesystem
/// for git activity is a wildly disproportionate thing for a time tracker to do, and would need
/// permissions to match. An explicit list is the least magical option and the easiest to reason
/// about when it is *not* doing what you expect.
///
/// ## Why `git` rather than reading `.git/HEAD`
///
/// Parsing `.git/HEAD` would avoid a subprocess, but it is only correct for the simple case: it
/// is wrong for a worktree, wrong for a submodule, and wrong in a detached HEAD, which is exactly
/// when a wrong answer is most confusing. `git rev-parse` already knows all of that.
@MainActor
@Observable
final class BranchSuggestions {

    struct Suggestion: Identifiable, Equatable {
        /// The issue key found in the branch name.
        let key: String
        /// The repository's folder name, so two repos on the same issue are distinguishable.
        let repository: String
        /// The branch it came from, shown so an unexpected suggestion explains itself.
        let branch: String

        var id: String { "\(repository)/\(branch)" }
    }

    private(set) var suggestions: [Suggestion] = []

    /// Paths that could not be read, so Settings can mark them rather than failing quietly when
    /// a repository is renamed or on an unmounted volume.
    private(set) var unreadablePaths: Set<String> = []

    private var isRefreshing = false

    /// Re-reads every watched repository.
    ///
    /// Called when the panel opens rather than on a timer: branches change when a person switches
    /// them, which is never while they are not looking at the app, and a subprocess per repo on a
    /// schedule is a poor trade for a suggestion.
    func refresh(paths: [String]) async {
        guard !isRefreshing else { return }
        guard !paths.isEmpty else {
            suggestions = []
            unreadablePaths = []
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var found: [Suggestion] = []
        var unreadable: Set<String> = []
        var seenKeys: Set<String> = []

        for path in paths {
            guard let branch = await Self.currentBranch(at: path) else {
                unreadable.insert(path)
                continue
            }
            guard let key = IssueKey.inBranchName(branch) else { continue }
            // Two repositories on the same issue should offer it once.
            guard seenKeys.insert(key).inserted else { continue }
            found.append(
                Suggestion(
                    key: key,
                    repository: URL(fileURLWithPath: path).lastPathComponent,
                    branch: branch
                )
            )
        }

        suggestions = found
        unreadablePaths = unreadable
    }

    /// Whether `path` is a git repository, for validating a directory as it is added.
    static func isRepository(_ path: String) async -> Bool {
        await run(["rev-parse", "--is-inside-work-tree"], in: path) == "true"
    }

    // MARK: - git

    private static func currentBranch(at path: String) async -> String? {
        guard let branch = await run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) else {
            return nil
        }
        // Detached HEAD reports "HEAD", which names no issue. Not an error — just nothing to
        // suggest, so it must not be reported as an unreadable path either.
        return branch == "HEAD" ? "" : branch
    }

    /// Runs git and returns trimmed stdout, or nil when it could not run or failed.
    private static func run(_ arguments: [String], in directory: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                // `xcrun git` would pick the toolchain's copy and can prompt about licences;
                // `/usr/bin/git` is the stable shim present on every Mac.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                // Keep it hermetic: no pager to hang on, no prompt to wait for, no user config
                // deciding what `--abbrev-ref` prints.
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                environment["GIT_PAGER"] = "cat"
                process.environment = environment

                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }
}
