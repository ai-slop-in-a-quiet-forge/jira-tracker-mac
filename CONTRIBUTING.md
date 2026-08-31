# Contributing to Chrono

Chrono is free software and will stay that way. There is no paid tier, no "pro" version and no
plan to add one. If you find it useful, the best thing you can do is make it better for the next
person.

Contributions of every size are welcome — a typo fix is a real contribution. You do not need to
ask permission before opening a pull request.

## Project principles

These are the things a contribution should not quietly undo. If you think one of them is wrong,
open an issue and argue the case — they are commitments, not scripture.

1. **Free, forever.** Apache-2.0, no paid tier, no feature held back for a paid version.
2. **No server.** Chrono talks to your Jira and nothing else. There is no Chrono backend to
   depend on, be billed for, or have an outage.
3. **No telemetry.** Not anonymised, not opt-in, not "just crash reports". If we need to know
   something, we ask in an issue.
4. **Never invent time.** When Chrono is not certain how long you worked, it says so and asks.
   It never rounds a gap in its knowledge into a number on someone's timesheet.
5. **Your data stays yours.** Plain JSON on your disk, exportable to CSV, with the storage
   location shown in the app.
6. **Proportionate permissions.** Chrono reads *how long* since you last typed, never what you
   typed. It reads a "device in use" flag, never audio or video. If a feature needs more than
   that, it needs a very good reason.

## Getting set up

You need macOS 14+ and Xcode 15+ (or just the Swift 5.9+ toolchain).

```bash
git clone git@github.com:ai-slop-in-a-quiet-forge/jira-tracker-mac.git
cd jira-tracker-mac

swift build                      # build everything
swift test                       # run the test suite (fast — under a second)
Scripts/build-app.sh --debug     # assemble dist/Chrono.app
Scripts/build-app.sh --run       # ...and launch it
```

There is no `.xcodeproj` for the Mac app, and that is deliberate: a `pbxproj` is thousands of
lines of opaque identifiers that nobody can review and that conflicts on every merge.
`Scripts/build-app.sh` is the build. You can still edit in Xcode by opening `Package.swift`.

For the iOS app:

```bash
python3 Scripts/generate-ios-project.py       # regenerate the project
open ios/ChronoRemote/ChronoRemote.xcodeproj
```

Same reasoning — the `.xcodeproj` is generated from a readable script. **If you add or remove an
iOS source file, edit the list in `Scripts/generate-ios-project.py` and regenerate.** CI checks
that the committed project matches the generator.

## Where things live

```
Sources/ChronoCore/     Pure logic. No AppKit, no UIKit, no timers.
Sources/ChronoApp/      macOS app: menu bar, panels, sensors, transports.
ios/ChronoRemote/       iOS Bluetooth remote.
Tests/ChronoCoreTests/  Tests for the core.
Scripts/                Build and project generation.
docs/                   Architecture, roadmap, platform notes.
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before a substantial change. It explains the
decisions and, more usefully, what each one was defending against.

## The rules that matter

Three constraints keep this codebase testable. Breaking them is the main thing a review will
push back on.

### 1. `ChronoCore` has no UI framework and no timers

It compiles for macOS and iOS, and the iOS app links the same files. If you find yourself
wanting `import AppKit` in `ChronoCore`, the logic belongs in `ChronoCore` and the *platform
call* belongs in `ChronoApp`. `ActivitySnapshot` exists precisely as that seam.

### 2. Time comes from an injected `Clock`, never `Date()`

```swift
// no
let elapsed = Date().timeIntervalSince(start)

// yes
let elapsed = clock.now.timeIntervalSince(start)
```

This is what makes the interesting cases testable: a laptop asleep for six hours, NTP moving the
clock backwards, a session crossing midnight, a crash with the timer running. Each becomes a
three-line test instead of a manual experiment nobody repeats.

### 3. Segments are append-only

History is an immutable list. Pausing closes a segment; resuming opens a new one. Trimming idle
time, splitting across midnight and editing a note all *return new segments*. Do not mutate
history in place — the audit trail is a feature.

## Compatibility promises

Breaking either of these needs a version bump and a migration, not a quiet change:

- **The storage format.** Someone's timesheet is in there. `FileStore.loadMerging` layers stored
  JSON over defaults so adding a field is safe; removing or renaming one is not.
- **The remote protocol.** One phone should be able to drive any Chrono. If the wire format
  changes incompatibly, bump `ChronoRemote.protocolVersion`.

If you change the signing scheme, update `SigningContractTests` **and** the JavaScript in
`RemoteWebAssets.swift`. That test pins a shared vector against both implementations
specifically so they cannot drift apart unnoticed.

## Tests

Test the logic, not the pixels.

- Anything in `ChronoCore` should have tests. It is pure and fast, so there is no excuse.
- Anything involving time, rounding, money-adjacent arithmetic or the sync queue **must** have
  tests.
- SwiftUI views are not unit tested here. Verify them by running the app.

Write test names as sentences describing the behaviour, not the method:

```swift
@Test("A timer running at a crash is recovered up to the last heartbeat, not to now")
@Test("Time below the minimum is not logged and not consumed")
```

When a test fails, work out which of the two is wrong before changing either. Several tests here
encode decisions that look surprising until you know why — that is what the names are for.

## Code style

Follow the surrounding code. Beyond that:

- **Comments explain *why*.** The code already says what it does. A comment earns its place by
  recording a decision, a constraint, or a trap:

  ```swift
  // Monospaced digits are the difference between a calm menu bar and one that
  // twitches every second.
  ```

  Not:

  ```swift
  // Set the font to monospaced.
  ```

- Small files. Roughly 200–400 lines, 800 as a hard ceiling. Split by responsibility.
- Prefer value types and immutability. `TrackingTarget` is an enum rather than a struct with an
  optional issue key precisely so invalid states cannot be represented.
- Name things for what they mean to the user. `unfiledSeconds`, not `adhocSecs`.
- No new dependencies without discussion. Chrono currently has **zero** third-party
  dependencies, and that is worth defending — it is why it builds from a clean clone with one
  command.

## Commits and pull requests

Commit messages use conventional-commit prefixes:

```
feat: add a Lock Screen widget to the iOS remote
fix: stop the menu bar title jittering when seconds are shown
docs: explain the duplicate-worklog check
test: cover midnight-crossing sessions
refactor: move the HTTP parser into ChronoCore
```

Explain **why** in the body if it is not obvious. Look at `git log` for the house style — the
useful commits here describe the failure mode they were defending against.

For pull requests:

1. Run `swift test` and `Scripts/build-app.sh --debug` before opening.
2. Say what you changed and, if it touches behaviour, how you verified it on a real Jira site.
3. Screenshots for UI changes, please.
4. Small and focused beats large and comprehensive. Two PRs are fine.
5. Draft PRs are welcome if you want feedback early.

Nobody is going to be precious about review here. If something is good enough and moves the
project forward, it goes in.

## Good places to start

See [docs/ROADMAP.md](docs/ROADMAP.md), or the
[good first issue](https://github.com/ai-slop-in-a-quiet-forge/jira-tracker-mac/labels/good%20first%20issue)
label.

Genuinely useful, genuinely small:

- **Hotkey customisation UI.** The shortcuts work and are stored in `HotkeySet`, but Settings
  only displays them. Needs a recorder control.
- **Localisation.** Every string is hardcoded English. Extracting them is mechanical and would
  open the app up to a lot of people.
- **Accessibility audit.** VoiceOver labels on the panel and timesheet.
- **Git branch detection.** A branch called `CYM-1234-fix-parser` should make Chrono offer
  `CYM-1234`. Small feature, disproportionately nice.
- **Tempo CSV export.** Teams using Tempo need a specific column layout.

And if you want to take on something big: the **Windows port** is fully specified in
[docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md), including the Windows equivalent of every sensor.
The test suite is the specification. That would help a lot of people.

## Reporting bugs

Include your macOS version, whether you built from source or downloaded a release, and what you
expected instead. For anything involving time being logged wrongly, the contents of
`~/Library/Application Support/Chrono/state.json` are enormously helpful — but **read it first
and redact anything you would not want public.** It contains issue keys and your notes. It never
contains credentials.

For security issues, see [SECURITY.md](SECURITY.md) — please do not open a public issue.

## Licence

Contributions are under [Apache-2.0](LICENSE), the same licence as the project. Apache-2.0 was
chosen deliberately: it gives contributors an explicit patent grant, and it means nobody —
including the original author — can take a future version proprietary and leave the community
behind.

There is no CLA. You keep the copyright on your contribution.
