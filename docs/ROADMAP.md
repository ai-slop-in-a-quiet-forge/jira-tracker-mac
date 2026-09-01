# Roadmap and open work

Chrono works and is in daily use. Everything below is either a known gap, a deliberate omission
worth revisiting, or something that would make it useful to more people.

Nothing here is claimed by anyone. Pick something up and open a pull request — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

`Scripts/seed-issues.sh` creates these as GitHub issues with labels, if they are not already
there.

Difficulty is a rough guide to *scope*, not to how clever you need to be:

- **S** — an afternoon, mostly self-contained
- **M** — a weekend, touches a few files
- **L** — a substantial piece of work with design decisions in it

---

## Known limitations

Honest list of things Chrono does not currently do well.

### The web remote's port-collision fallback is untested — **S**
`WebRemoteServer` retries on an OS-assigned port if the configured one fails to bind. That path
has never executed: `allowLocalEndpointReuse` means a second bind of the same port succeeds
rather than colliding, and macOS let a normal user process bind port 80, so no failure could be
provoked. Needs a test that injects a listener failure, which probably means putting a seam in
front of `NWListener`.

*Labels: `tests`, `area: remote`, `good first issue`*

### No Focus mode detection — **M**
macOS exposes no supported API for reading whether a Focus mode is active, so Chrono relies on
its own snooze instead. `ActivitySnapshot.focusModeActive` exists and is always `false`. If
someone finds a supported route, the policy already honours it. Reading the private
`~/Library/DoNotDisturb` database is explicitly *not* wanted — it breaks between releases.

*Labels: `enhancement`, `area: sensors`, `help wanted`*

### Hotkeys cannot be changed in the app — **S**
`HotkeySet` is stored, persisted and registered properly, and the defaults work. But Settings ▸
Tracking only *displays* them. Needs a shortcut-recorder control, and `HotkeyManager.apply`
called again on change.

*Labels: `enhancement`, `area: ui`, `good first issue`*

### Every string is hardcoded English — **M**
No localisation at all. Extracting strings into a catalogue is mechanical work that would open
the app to a lot more people. Worth doing before the string count grows further.

*Labels: `enhancement`, `i18n`, `good first issue`, `help wanted`*

### Accessibility has not been audited — **M**
The panel and timesheet have had no VoiceOver pass, and several controls are icon-only with only
a tooltip. Keyboard navigation of the issue list is untested.

*Labels: `accessibility`, `area: ui`, `help wanted`*

### One Jira site at a time — **M**
`JiraConnection` holds a single set of credentials. People who contract across several Jira
sites cannot use Chrono for more than one. The Keychain layer already namespaces tokens by
account, so the storage side is half done; the engine would need `jiraAccountID` respected per
segment.

*Labels: `enhancement`, `area: jira`*

### ~~Timesheet cannot edit times inline~~ — done
Clicking an entry's times in the timesheet opens a bounded editor. `editSegmentTimes` refuses
anything that would overlap a neighbour or the running timer, and says which boundary was hit.

(The earlier note here claimed `updateSegment` was tested. It was not — it had no callers and no
tests at all. It still exists for programmatic use, where its quiet clamping is appropriate.)

### Chrono cannot tell you an update exists — **S**
Mostly solved: `brew upgrade --cask chrono` updates a Homebrew install, and the tap re-points
itself at each new release within a day. What is still missing is the app noticing on its own —
anyone who took the direct download has no signal that a newer build shipped, short of visiting
the releases page. Sparkle would do it properly but means hosting an appcast, which brushes
against the no-server principle; a periodic check against the public releases API would not, and
is much smaller.

*Labels: `packaging`, `enhancement`, `good first issue`*

### Not signed or notarised — **M**
Releases are ad-hoc signed, so a downloaded build is quarantined and the first launch has to be
approved through System Settings ▸ Privacy & Security. On macOS 15 the right-click ▸ Open
shortcut no longer works, so that is the only route. Installing with Homebrew does not avoid it:
`--no-quarantine` was removed in Homebrew 6, so a cask install is quarantined exactly like a
download. Ad-hoc signing also means the code identity changes every release — the designated
requirement is a bare cdhash, so two builds of identical source do not share one. Consequently
Homebrew cannot carry a Gatekeeper approval across an upgrade, and the Bluetooth, Local Network
and Keychain prompts all return on each update. Proper signing needs a Developer ID, which needs someone willing to hold
and renew it. Until then, building from source avoids all of it.

*Labels: `packaging`, `help wanted`*

---

## Features worth building

### ~~Suggest an issue from the current git branch~~ — done
Add folders under Settings ▸ Jira ▸ *Suggest from your git branch* and the panel offers the issue
named by each checked-out branch. A configured list, not window-title sniffing: the latter guesses
at a convention every editor implements differently.

### ~~Tempo CSV export~~ — done
`TempoExport` writes the columns Tempo's worklog importer reads, one row per issue per day, and
reports the ad-hoc time it could not include.

*Labels: `enhancement`, `area: jira`, `good first issue`*

### Calendar integration for meeting time — **L**
Chrono knows you are *in* a call but not *which* meeting. Reading the local calendar (EventKit,
with permission) would let it label meeting time with the actual event, and offer to backfill
meetings you forgot to track. Needs care: a calendar is sensitive, so this must be opt-in,
read-only and clearly scoped.

*Labels: `enhancement`, `area: sensors`*

### Screen sharing as a meeting signal — **S**
Sharing your screen is an even stronger "in a meeting" signal than a live microphone, and would
catch the case where you are presenting on mute. `CGDisplayStream`-based detection or checking
for the screen-recording indicator are both worth investigating.

*Labels: `enhancement`, `area: sensors`*

### Per-app idle exemptions — **M**
Reading a long document is not idleness. An allowlist ("do not count me as idle while Preview or
a PDF reader is frontmost") would remove a real annoyance. The frontmost-app plumbing already
exists in `AppSensor`.

*Labels: `enhancement`, `area: sensors`*

### The Lock Screen timer goes stale while the app is suspended — **M**
The Live Activity ships: `ChronoRemoteWidget` is a second target in the generated project, and
the Lock Screen counts up on its own from a date anchor rather than costing an ActivityKit update
per second.

What is left is the case where iOS suspends the app. Without the `bluetooth-central` background
mode the app cannot hear a pause made on the Mac, so the Lock Screen keeps counting until the app
is next opened. The activity is marked stale when the phone *knows* it has lost the Mac, but a
suspended app does not know.

Declaring the background mode needs an `Info.plist` for the app target — `INFOPLIST_KEY_` covers
a fixed list of top-level keys and `UIBackgroundModes` is not among them (`NSSupportsLiveActivities`
is, which is why the Live Activity itself needed no plist). Worth doing deliberately: it is a real
trade against battery, and honest state restoration wants `CBCentralManagerOptionRestoreIdentifierKey`
too.

*Labels: `enhancement`, `platform: ios`*

### Weekly summary worth reading — **M**
The timesheet reports totals. It could report something more useful: how fragmented the week
was, which issues ate the time, how much went unfiled, how the estimate-versus-actual looked.
`DayRollup` and `WeekRollup` already compute most of the inputs.

*Labels: `enhancement`, `area: ui`*

### Menu bar day total — **S**
The menu bar shows the current session. Some people would rather see progress toward the day's
target. A setting and a small change to `StatusItemController.menuBarTitle`.

*Labels: `enhancement`, `area: ui`, `good first issue`*

---

## Platforms

### Windows and Linux build — **L**
Fully specified in [WINDOWS-PORT.md](WINDOWS-PORT.md): which layers transfer verbatim, the
recommended stack with reasoning against the alternatives, and the Windows equivalent of every
sensor Chrono uses — including microphone and camera detection, and the Bluetooth peripheral
role, both of which are usually assumed to be Mac-only.

The 112 core tests are the specification. Port them first, before any UI.

This is the single most valuable contribution anyone could make, because it is the one thing
blocking whole teams from using Chrono together.

*Labels: `platform: windows`, `help wanted`, `epic`*

---

## Explicitly not planned

Saying no to these is part of the design, not a lack of time. Argue the case in an issue if you
disagree — but start by reading the principle it conflicts with in
[CONTRIBUTING.md](../CONTRIBUTING.md).

- **A hosted or team version.** Needs a server, which the project does not have and does not want.
- **Any telemetry.** Including anonymised, including opt-in.
- **A paid tier.** Not now, not later.
- **Screenshot-based or keystroke-level activity monitoring.** Chrono is a tool for the person
  using it, not for watching them. It deliberately cannot see what you type.
- **Automatic time allocation by AI guesswork.** Guessing which ticket your afternoon belonged to
  and logging it unasked is exactly the "inventing time" failure the app is built to avoid.
  Suggesting, with the user confirming, is a different matter and would be welcome.
