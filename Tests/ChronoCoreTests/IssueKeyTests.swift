import Foundation
import Testing
@testable import ChronoCore

@Suite("Issue keys")
struct IssueKeyTests {

    // MARK: - looksLike

    @Test("Accepts the shapes Jira uses", arguments: [
        "ABC-123", "CYM-1", "CYM_2-4517", "cym-123", "A1-9",
    ])
    func acceptsKeys(text: String) {
        #expect(IssueKey.looksLike(text))
    }

    @Test("Rejects what is not a key", arguments: [
        "", "ABC", "123", "-123", "ABC-", "ABC-12a", "ABC 123", "1ABC-2",
    ])
    func rejectsNonKeys(text: String) {
        #expect(IssueKey.looksLike(text) == false)
    }

    @Test("Surrounding whitespace is ignored")
    func trimsWhitespace() {
        #expect(IssueKey.looksLike("  ABC-123\n"))
    }

    // MARK: - inBranchName

    @Test("Finds the key in the branch shapes people actually use", arguments: [
        ("CYM-1234-fix-parser", "CYM-1234"),
        ("CYM-1234", "CYM-1234"),
        ("feature/CYM-1234-thing", "CYM-1234"),
        ("bugfix/CYM-1234_thing", "CYM-1234"),
        ("users/abhishek/CYM-1234/wip", "CYM-1234"),
        ("fix-CYM-1234", "CYM-1234"),
        ("CYM_2-4517-something", "CYM_2-4517"),
        ("feature/ABC-7", "ABC-7"),
    ])
    func findsKey(branch: String, expected: String) {
        #expect(IssueKey.inBranchName(branch) == expected)
    }

    @Test("Finds nothing in a branch without a key", arguments: [
        "main", "master", "develop", "", "wip", "feature/no-key-here",
    ])
    func findsNothing(branch: String) {
        #expect(IssueKey.inBranchName(branch) == nil)
    }

    @Test("Lower-case word-number branches are not mistaken for keys", arguments: [
        "release-2", "hotfix-3", "v-12", "sprint-4", "release/2-1",
    ])
    func rejectsLowerCaseNoise(branch: String) {
        // These all pass the lenient `looksLike` test, which is exactly why branch extraction
        // needs its own stricter rule. Offering a "RELEASE-2" that does not exist reads as a
        // broken feature rather than an inapplicable one.
        #expect(IssueKey.inBranchName(branch) == nil)
    }

    @Test("A single-letter project is rejected, matching Jira's own minimum")
    func rejectsSingleLetterProject() {
        #expect(IssueKey.inBranchName("A-1") == nil)
        #expect(IssueKey.inBranchName("V-2-thing") == nil)
        #expect(IssueKey.inBranchName("AB-1") == "AB-1")
    }

    @Test("A number followed by more key material is not a key")
    func rejectsTrailingMaterial() {
        // `ABC-12x` is not a reference to ABC-12.
        #expect(IssueKey.inBranchName("ABC-12x") == nil)
        #expect(IssueKey.inBranchName("ABC-12-x") == "ABC-12")
    }

    @Test("The first key wins when a branch mentions two")
    func firstKeyWins() {
        #expect(IssueKey.inBranchName("CYM-1-and-CYM-2") == "CYM-1")
    }

    @Test("Mixed-case project keys are not accepted in a branch")
    func rejectsMixedCase() {
        // Jira project keys are upper case; `Feature-1` is a branch name, not a key.
        #expect(IssueKey.inBranchName("Feature-1") == nil)
        #expect(IssueKey.inBranchName("Cym-123") == nil)
    }

    @Test("Windows-style separators are handled")
    func backslashSeparator() {
        #expect(IssueKey.inBranchName("feature\\CYM-9") == "CYM-9")
    }

    @Test("Anything found in a branch is also a valid key")
    func extractedKeysAreValid() {
        // The two rules must not disagree: a key the branch parser reports has to be one the
        // rest of the app will accept.
        let branches = [
            "CYM-1234-fix", "feature/ABC-7", "CYM_2-4517-x", "fix-AB-1", "users/x/QQ-42/y",
        ]
        for branch in branches {
            let key = IssueKey.inBranchName(branch)
            #expect(key != nil, "expected a key in \(branch)")
            if let key { #expect(IssueKey.looksLike(key), "\(key) from \(branch) is not a valid key") }
        }
    }
}
