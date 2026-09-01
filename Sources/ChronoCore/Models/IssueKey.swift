import Foundation

/// Recognising Jira issue keys in text.
///
/// One definition, in ChronoCore, because two places now need it: the search box (where the user
/// types a key) and branch names (where a key has to be found inside surrounding text). They want
/// *different strictness*, and that difference is the interesting part — see `inBranchName`.
public enum IssueKey {

    /// Whether the whole string is shaped like a key (`ABC-123`, `CYM_2-4517`).
    ///
    /// Deliberately lenient about case: someone typing `cym-123` into the search box means the
    /// issue, and Jira resolves it.
    ///
    /// Hand-parsed rather than done with a regex: it is faster on a per-keystroke path, and the
    /// rules are clearer written out than encoded in a pattern.
    public static func looksLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split on the *last* dash, so a project key containing one still parses.
        guard let dash = trimmed.lastIndex(of: "-") else { return false }

        let project = trimmed[trimmed.startIndex..<dash]
        let number = trimmed[trimmed.index(after: dash)...]

        guard let first = project.first, first.isLetter else { return false }
        guard project.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return false }
        return true
    }

    /// Finds the issue key in a git branch name, or nil if there is not one.
    ///
    /// ## Why this is stricter than `looksLike`
    ///
    /// Here the key has to be *found* rather than validated, and the surrounding text is full of
    /// things that would pass a lenient test. `release-2`, `hotfix-3` and `v-12` are all shaped
    /// like `word-number`, and offering someone a "RELEASE-2" that does not exist is worse than
    /// offering nothing — it looks like the feature is broken rather than inapplicable.
    ///
    /// So this requires the project part to be **upper case** and at least two characters, which
    /// is what Jira itself enforces for project keys. Ordinary branch prefixes are lower case by
    /// near-universal convention, so that one rule removes almost all the noise.
    public static func inBranchName(_ branch: String) -> String? {
        // Split on characters that cannot appear in a key, so `feature/ABC-1` and
        // `users/name/ABC-1/wip` both reduce to a token containing the key.
        for token in branch.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == " " || $0 == "\\" }) {
            let characters = Array(token)
            for offset in characters.indices {
                // Only start where key material starts, so `fix-ABC-1` is found but the `BC-1`
                // inside `ABC-1` is never considered a key of its own.
                let isBoundary = offset == 0 || !isKeyBody(characters[offset - 1])
                guard isBoundary, let key = key(in: characters, from: offset) else { continue }
                return key
            }
        }
        return nil
    }

    // MARK: - Internals

    private static func isKeyBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Reads `PROJECT-123` starting at `start`, or nil.
    private static func key(in characters: [Character], from start: Int) -> String? {
        guard characters[start].isLetter, characters[start].isUppercase else { return nil }

        var index = start + 1
        while index < characters.count,
              characters[index] == "_"
                || characters[index].isNumber
                || (characters[index].isLetter && characters[index].isUppercase) {
            index += 1
        }

        // Jira requires at least two characters in a project key, which also rules out `V-1`
        // and similar version-ish branch names.
        guard index - start >= 2, index < characters.count, characters[index] == "-" else { return nil }
        let project = String(characters[start..<index])

        var digits = ""
        var after = index + 1
        while after < characters.count, characters[after].isNumber {
            digits.append(characters[after])
            after += 1
        }
        guard !digits.isEmpty else { return nil }

        // What follows the number must not be more key material: `ABC-12x` is not a reference to
        // `ABC-12`, it is something else entirely.
        if after < characters.count, characters[after].isLetter || characters[after].isNumber {
            return nil
        }

        return "\(project)-\(digits)"
    }
}
