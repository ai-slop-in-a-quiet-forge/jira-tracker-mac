# Architecture

Notes on how Chrono is put together, and why. The "why" matters more than the "what" here —
most of these choices were made against a specific failure mode.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│  ChronoApp (macOS)          ios/ChronoRemote (iOS)           │
│  AppKit status item         SwiftUI + CoreBluetooth central  │
│  SwiftUI panels                                              │
│  Sensors, transports                                         │
└──────────────┬───────────────────────────┬───────────────────┘
               │                           │
        ┌──────▼───────────────────────────▼──────┐
        │              ChronoCore                 │
        │  models · engine · Jira · storage       │
        │  remote protocol · signing              │
        │  no AppKit, no UIKit, no timers          │
        └─────────────────────────────────────────┘
```

`ChronoCore` has three rules, and they are what make the rest work:

1. **No UI framework.** It compiles for macOS and iOS, and would compile for anything with a
   Swift toolchain.
2. **No timers.** Nothing in the core decides *when* something happens; callers drive it.
3. **The clock is injected.** Every piece of time arithmetic goes through a `Clock` protocol.

Rule 3 is the important one. The interesting bugs in a time tracker are all about time:
a laptop sleeping for six hours, NTP correcting the clock backwards mid-session, a session
crossing midnight, a crash with the timer running. With an injected clock, each of those is a
three-line test that runs in microseconds instead of a manual experiment nobody repeats.

## The state machine

Three states, made unambiguous by the shape of the stored data rather than by a separate enum
that could disagree with it:

| state   | `activeTarget` | `runningSince` |
|---------|----------------|----------------|
| idle    | `nil`          | `nil`          |
| running | set            | set            |
| paused  | set            | `nil`          |

History is an **append-only list of segments**. Pausing closes a segment; resuming opens a new
one against the same target. Nothing is mutated in place, so trimming idle time, splitting across
midnight and editing a note all produce new segments and leave the audit trail intact.

Consequences worth stating:

- Pausing does not deselect the task, so resuming is one click.
- "Total on this task today" is a query over segments, not a counter that can drift.
- Switching task closes one segment and opens another atomically — there is no window where
  nothing is tracked.

## Crash recovery, and refusing to guess

While a timer runs, the engine writes a **heartbeat** every few seconds. If the app is killed at
17:05 and reopened at 09:00 the next morning, the persisted state says "running since 09:00
yesterday", but the heartbeat says we only ever observed it running until 17:05.

So Chrono presents both numbers: eight hours it can vouch for, sixteen it cannot, and three
choices. It never silently logs the gap. This is the single most valuable thing in the app,
because the alternative — a tracker that occasionally invents sixteen hours — destroys trust in
every other number it reports.

## Meeting detection

The signal that actually correlates with "you are in a call" is **audio or video capture being
live**, not which app is frontmost. Teams is always open; your microphone is not always hot.

Read via `kAudioDevicePropertyDeviceIsRunningSomewhere` (CoreAudio) and the CoreMediaIO
equivalent for video. Both are public API, need no permissions, and observe capture started by
*any* process. Chrono never opens either device itself, so it never appears in the orange
privacy indicator.

Confidence is graded, because false positives are what get an app like this muted:

| signal | verdict |
|--------|---------|
| mic **and** camera live | certain |
| mic or camera live, **and** a meeting app or browser running | strong |
| a meeting app merely frontmost | weak, and opt-in only |
| mic alone | **not a meeting** — dictation, Voice Memos, menu bar utilities |

A weak signal must persist three times longer before it earns an interruption. Settings shows a
live sensor readout, so the mechanism is inspectable rather than magic.

## Interventions

`InterventionPolicy.evaluate` is a pure function of (sensor snapshot, engine summary, settings,
debounce memory) returning **at most one** intervention, in strict priority order. All the
judgement about when to interrupt someone lives in code that runs in microseconds under test,
rather than scattered across timer callbacks.

Priority: runaway session → idle → meeting → forgot-to-start → paused-too-long → periodic
check-in → break → end-of-day.

Prompts that need an answer are shown in Chrono's **own non-activating floating panel**, not as
notifications. Three reasons, all learned from how this fails in practice: notification
permission can be denied; a Focus mode swallows banners silently; and the app's core promise is
that it *will* tell you when the wrong thing is being tracked. A panel Chrono draws itself cannot
be suppressed by any of that, and being non-activating means answering it does not steal focus
from the call you are on.

## Worklogs

Segments become drafts; drafts become Jira worklogs.

- **One draft per issue per calendar day.** A reviewer wants "3h 20m on Tuesday", not eleven
  fragments reflecting every time you tabbed away.
- **Rounding applies to the daily total.** Rounding each fragment up to the nearest quarter hour
  would turn twelve 90-second interruptions into three invented hours.
- **Below the minimum is not consumed.** A 40-second stretch is not logged *and not marked as
  used*, so it merges into the next draft for that issue and day instead of vanishing.
- **Drafts are durable.** They survive relaunch, with attempt counts and exponential backoff
  capped at 30 minutes.

### The duplicate problem

If a worklog POST times out, the worklog may or may not exist in Jira. Retrying blindly risks
double-logging an hour of someone's day; not retrying risks losing it.

Jira's worklog endpoint has no idempotency header, so there is nothing to ask Jira about the
request. Instead, before re-sending a draft that has already been attempted, Chrono lists the
issue's worklogs and looks for one **by the same author, with the same `started` instant and the
same duration**. `started` comes from us with millisecond precision, so a false match is
vanishingly unlikely.

If the duplicate *check itself* fails, Chrono submits anyway. A duplicate is visible and
correctable by a human; silently dropped time is neither.

## Storage

`~/Library/Application Support/Chrono/`, plain JSON.

- **Atomic writes.** Temp file then atomic replace, because this is the user's timesheet.
- **Debounced.** The engine ticks every second; the disk does not need to.
- **Forward-compatible reads.** Rather than failing to decode when a field has been added,
  `FileStore.loadMerging` layers the stored JSON over the JSON encoding of a default value. A
  file written by an older version loads with defaults for the new fields. A file that cannot be
  salvaged is moved aside, never deleted.
- **Archived.** Segments older than 45 days move to monthly files, so the file written every few
  seconds stays small.

Secrets are never in these files — Keychain, or read from 1Password on demand.

## Remote protocol

One wire contract for both transports, so the iOS app and the browser remote cannot drift, and a
future transport only has to move bytes.

BLE is the constraint that shapes it: a negotiated ATT payload is typically 185 bytes. So the
state snapshot uses single-character keys and integer seconds, and a test asserts a
worst-case snapshot still fits in one notification — which removes the need for a chunking layer
entirely.

### Signing

Every command carries `HMAC-SHA256(SHA256(secret), "counter.timestamp." + payload)`.

Replay is blocked two ways, because either alone has a gap:

- a **monotonic counter**, which stops replay within a session but resets when the Mac restarts;
- a **timestamp freshness window**, which stops replay of a captured packet later, covering
  exactly the restart case the counter does not.

The pairing secret travels only in the QR code's URL fragment. Browsers never transmit fragments,
so even though the LAN remote is plain HTTP, the secret itself is never sent over the network.

The web remote ships its own SHA-256/HMAC in JavaScript because `crypto.subtle` requires a
secure context and the remote is plain HTTP on a LAN address. `SigningContractTests` pins a
shared test vector against the Swift implementation so the two cannot silently diverge.

## Things deliberately not done

- **No OAuth.** It would require a registered app with a redirect URL — a server. API tokens are
  scoped, revocable, and need nothing.
- **No auto-resume after a pause.** Waking your Mac is not the same as going back to the task.
  Chrono offers; it does not decide.
- **No SQLite.** One user's timesheet is a few thousand records. JSON is inspectable, diffable,
  and has no migration story to get wrong.
- **No `.xcodeproj` for the Mac app.** A build script is reviewable; a pbxproj is not.
- **No Focus-mode detection.** macOS exposes no supported API for it, so Chrono relies on its own
  snooze rather than pretending to know.
