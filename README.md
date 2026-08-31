# Chrono

[![CI](https://github.com/ai-slop-in-a-quiet-forge/jira-tracker-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/ai-slop-in-a-quiet-forge/jira-tracker-mac/actions/workflows/ci.yml)
[![Licence: Apache 2.0](https://img.shields.io/badge/licence-Apache%202.0-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Contributions welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg)](CONTRIBUTING.md)

A menu bar time tracker for Jira Cloud that survives a normal working day — the ad-hoc Teams
call, the drive-by question, the afternoon you forgot to press start.

Entirely local. There is no Chrono server, no Chrono account and no telemetry. The only network
calls it makes are to your own Jira site.

**Free software, and it will stay that way.** Apache-2.0, no paid tier, no "pro" version, and no
plan to add one. Time tracking is something a lot of people are made to do and few enjoy; it
should not also be something they pay for. Contributions very welcome —
[start here](CONTRIBUTING.md).

```
┌─ menu bar ──────────────────────────────────────────────┐
│  ◔ CYM-1234  1:24                                       │
└─────────────────────────────────────────────────────────┘
        │ click
        ▼
┌──────────────────────────────────────────┐
│ ● CYM-1234                               │
│   Fix the worklog rounding bug           │
│   1:24:07              ⏸  ⏹  ⋯          │
│   Add a note                             │
├──────────────────────────────────────────┤
│ 5h 12m of 8h today   ▓▓▓▓▓▓░░░  45m unfiled │
├──────────────────────────────────────────┤
│ 🔍 Search issues, or paste a key       ⚙ │
│ RECENT                                   │
│  ▸ CYM-1231  Audit log pagination  1h  ▶ │
│  ▸ CYM-1198  SSO attribute mapping 25m ▶ │
├──────────────────────────────────────────┤
│ QUICK  Meeting  Call  Interrupt  Break   │
├──────────────────────────────────────────┤
│ ✓ Synced 2m ago      📅 Timesheet     ⚙ │
└──────────────────────────────────────────┘
```

## Why it exists

Most Jira time tracking fails for the same reason: it assumes your day is a tidy sequence of
tickets. It isn't. Calls land unannounced, you get pulled onto something with no ticket yet, and
by Friday you are reconstructing the week from memory and calendar entries.

Chrono is built around the interruptions rather than in spite of them:

- **It notices when you're on a call.** If your microphone or camera goes live while a task is
  tracking, it asks whether to pause, or move that time to a meeting bucket. One click either way.
- **It notices when you walk away.** Idle, screen lock and sleep all stop the clock, and you
  decide what happens to the time you were away for.
- **It gives unplanned work somewhere to go.** One click captures "an interruption" with correct
  timestamps; you attach it to a Jira issue later, from the timesheet, without having lost anything.
- **It never invents time.** If the app is killed with a timer running, it offers to log only up
  to the last heartbeat it can vouch for, and shows you the unknown remainder rather than billing it.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel
- A Jira Cloud API token ([create one here](https://id.atlassian.com/manage-profile/security/api-tokens))
- To build from source: Xcode 15+ or the Swift 5.9+ toolchain

## Download

[**Latest release**](https://github.com/ai-slop-in-a-quiet-forge/jira-tracker-mac/releases/latest)
— a universal build, ~3 MB zipped. Unzip and drag `Chrono.app` to Applications.

**macOS will refuse to open it the first time.** Chrono is not signed with an Apple Developer ID,
because that needs a paid account and someone willing to hold it (see
[docs/ROADMAP.md](docs/ROADMAP.md)). So Gatekeeper blocks the first launch:

1. Double-click Chrono. macOS says it cannot verify the developer — dismiss the dialog.
2. Open **System Settings ▸ Privacy & Security**, scroll down, click **Open Anyway**.
3. Confirm. macOS remembers the choice.

On macOS 15 and later the old right-click ▸ Open shortcut no longer works for this; Privacy &
Security is the only route. Two consequences worth knowing before you decide: the build is
ad-hoc signed, so its identity changes with every release — macOS re-asks for Bluetooth and Local
Network permission after an update, and the Keychain re-prompts once for your Jira token.

If none of that appeals, build from source instead. The result is identical and skips all of it,
because a locally built app is never quarantined.

## Install from source

```bash
git clone git@github.com:ai-slop-in-a-quiet-forge/jira-tracker-mac.git
cd jira-tracker-mac
Scripts/build-app.sh --install --run
```

That builds `dist/Chrono.app`, installs it and launches it. It appears in the menu bar, not the
Dock.

If `/Applications` is not writable — common on a managed or corporate Mac — it installs to
`~/Applications` instead. That works identically, launch at login included, and needs no admin
password.

Other options:

```bash
Scripts/build-app.sh            # just build into dist/
Scripts/build-app.sh --debug    # faster build while iterating
Scripts/build-app.sh --universal --zip   # what a release builds: arm64 + x86_64, then a zip
swift test                      # run the test suite
```

There is deliberately no `.xcodeproj` for the Mac app. `Scripts/build-app.sh` is the build:
it produces the bundle, the `Info.plist`, the icon and the signature from the command line.

## Connecting to Jira

Chrono uses a personal API token over HTTPS. Not OAuth — OAuth would need a registered app with
a redirect URL, i.e. a server, and the whole point is that there isn't one. The token is scoped
to you and revocable from the same page that issued it.

Two ways to give Chrono the token:

**Paste it.** Settings ▸ Jira ▸ *Paste an API token*. It is stored in your login Keychain and
never written to any of Chrono's files.

**Read it from 1Password** (preferred if you have the CLI). Put the token in a vault item and
give Chrono the reference:

```
op://Personal/jira-API-token-for-Chrono/password
```

Chrono runs `op read` at launch, so no copy of the token exists on disk at all. If 1Password is
locked or missing, it falls back to the Keychain and tells you.

You can also skip Jira entirely at first — ad-hoc tracking works immediately, and anything you
capture can be attached to an issue once you connect.

## What it does

### Tracking
- Start, pause, resume and stop from the menu bar, a keyboard shortcut, or your phone.
- Pausing keeps the task selected, so resuming is one click.
- Search issues as you type, or paste a key and press Return.
- Pin the issues you live in; recents are remembered automatically.
- Notes on a session become the Jira worklog comment.
- Backdate a start ("I actually began ten minutes ago") and add entries after the fact.

### Interruptions
- **Meeting detection** from microphone and camera activity. Microphone alone is never enough —
  dictation and a dozen menu bar utilities hold the input open — so Chrono requires audio or
  video capture *plus* a known meeting app or a browser running. Settings shows a live sensor
  readout so you can verify it by starting a call rather than taking our word for it.
- **Idle detection**, with your choice of keep / discard / discard-and-pause.
- **Auto-pause** on screen lock and sleep. Chrono never auto-*resumes*: waking your Mac is not
  the same as going back to the task.
- **Nudges**: periodic "still on this?", "you're working with no timer running", a runaway-session
  warning, an optional break reminder, and an end-of-day wrap-up.
- Everything is snoozable, and prompts that need an answer appear in Chrono's own floating panel
  rather than as notifications — so they still work if you deny notification permission or have
  a Focus mode on.

### Worklogs
- One worklog per issue per calendar day, so a reviewer sees "3h 20m on Tuesday" rather than
  eleven fragments.
- Rounding applied to the daily total, not to each fragment, so short interruptions cannot
  inflate into rounded-up minutes.
- Sessions past midnight are split so each day is logged on its own date.
- A durable queue with exponential backoff: close the lid on a train, and it syncs later.
- **No double-logging.** Jira has no idempotency header, so before re-sending a draft that already
  failed once, Chrono lists the issue's worklogs and looks for one of its own with the same start
  instant and duration. An ambiguous timeout cannot bill you twice.
- Undo, for the worklog you just submitted by accident.

### Timesheet
- Day and week view, with per-day bars.
- "Needs a ticket" sits at the top — the only part of the day that requires a decision.
- Expand any task to see and edit the individual stretches.
- The worklog queue with states, retries and errors that say what to actually do.
- CSV export, per entry or per day, with proper RFC 4180 quoting.

### Phone remote (optional, off by default)
Both transports are opt-in. Nothing listens or advertises until you turn it on in
Settings ▸ Phone.

- **Web remote** — the Mac serves one self-contained page on your local network. Scan a QR code,
  Add to Home Screen, done. No install, nothing to expire. Needs the same Wi-Fi. Uses a fixed
  port (47632 by default) so the shortcut you save on your phone keeps working across restarts.
- **iOS app** — a real app over Bluetooth LE, so it works with no Wi-Fi at all. See
  [docs/IOS-APP.md](docs/IOS-APP.md).

Both use the same signed protocol: every command carries an HMAC-SHA256 signature proving
knowledge of a pairing secret that only ever travels in the QR code's URL *fragment*, which
browsers never send to a server. Replays are rejected by a monotonic counter plus a two-minute
freshness window. A phone can pause, resume, stop, switch to a meeting bucket and snooze
reminders — it cannot reconfigure Jira or touch your history.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `⌃⌥T` | Show or hide the panel |
| `⌃⌥S` | Start or stop |
| `⌃⌥P` | Pause or resume |
| `⌃⌥I` | Capture an interruption |

Registered through the Carbon hot key API, which needs no Accessibility permission — Chrono
registers four specific combinations rather than asking to watch everything you type.

## Privacy

- Idle detection reads *how long since any input*, never what the input was.
- Microphone and camera detection reads a device "in use" flag. Chrono never opens either
  device, and so never appears in the orange privacy indicator.
- Your history is JSON in `~/Library/Application Support/Chrono`. Settings ▸ Advanced reveals it.
- Secrets live in the Keychain (or 1Password). Never in the JSON.
- The only outbound requests are to your Jira site.

## Architecture

```
Sources/ChronoCore/     platform-agnostic: engine, Jira client, persistence, remote protocol
Sources/ChronoApp/      macOS: menu bar, panels, sensors, transports
ios/ChronoRemote/       iOS: Bluetooth remote
Tests/ChronoCoreTests/  103 tests over the core
```

`ChronoCore` contains no AppKit or UIKit and no timers, and reads the clock only through an
injectable `Clock`. That is what makes the interesting cases testable — a clock going backwards,
a laptop sleeping, a session crossing midnight, a crash mid-session — and it is the layer the
iOS app links against and a Windows port would be transliterated from.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design decisions and why.

## Windows and Linux

Not yet. This started as a cross-platform Electron app and was deliberately rebuilt native for
a better Mac experience, a ~8 MB install instead of ~200 MB, and real Bluetooth.

[docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md) is the plan for getting there: which layers
transfer unchanged, which need reimplementing, and what the platform equivalents are for every
sensor Chrono relies on.

## Contributing

Yes please — including small things. A typo fix is a real contribution, and you do not need to
ask before opening a pull request.

- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to build, test and submit changes, plus the
  three constraints that keep the codebase testable.
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — known limitations and planned work, with a rough size
  on each, and an honest "explicitly not planned" list.
- **[Good first issues](https://github.com/ai-slop-in-a-quiet-forge/jira-tracker-mac/labels/good%20first%20issue)**
  — small and self-contained. Hotkey customisation, localisation, inline timesheet editing,
  branch-name issue detection, Tempo CSV export.
- **[Windows and Linux](https://github.com/ai-slop-in-a-quiet-forge/jira-tracker-mac/issues/18)**
  — the single most useful thing anyone could take on, and fully specified in
  [docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md) down to the Windows equivalent of every sensor.

Getting going takes one command:

```bash
swift test        # 112 tests, under a second
```

The project keeps some commitments that a change should not quietly undo — free forever, no
server, no telemetry, never invent time, proportionate permissions. They are written out with
their reasoning in [CONTRIBUTING.md](CONTRIBUTING.md), and they are open to challenge in an
issue.

Please also read the [Code of Conduct](CODE_OF_CONDUCT.md). For security problems, see
[SECURITY.md](SECURITY.md) — private reporting, not a public issue.

## Licence

[Apache 2.0](LICENSE), chosen deliberately: it gives contributors an explicit patent grant, and
it means nobody — including the original author — can take a future version proprietary and
leave the community behind.

There is no CLA. You keep the copyright on your contribution.
