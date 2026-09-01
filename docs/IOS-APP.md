# The iPhone remote

Two ways to control Chrono from your phone. They are independent, both optional, and both off
until you enable them in Settings ▸ Phone.

|  | Web remote | iOS app |
|--|-----------|---------|
| Install | Nothing — scan a QR code | Build once in Xcode |
| Works without Wi-Fi | No | **Yes** (Bluetooth LE) |
| Expires | Never | Free Apple ID: 7 days. Paid account: 1 year |
| Needs Xcode | No | Yes, once |

Start with the web remote. Build the app when you want it to keep working after you leave the
building.

## Web remote (no install)

1. Settings ▸ Phone ▸ enable **the phone web remote**.
2. Click **Show the pairing code**.
3. Scan it with your iPhone camera and open the link.
4. Share ▸ **Add to Home Screen**. It then opens full-screen and behaves like an app.

It polls every 2.5 seconds and ticks the timer locally in between, so it counts smoothly. Pause,
resume, stop, switch to a meeting bucket, snooze reminders, or switch to any recent issue.

Requires your phone and Mac to be on the same network. If you wander out of range it simply shows
a stale indicator, and reconnects when you return.

## iOS app (Bluetooth)

### Build and install

```bash
open ios/ChronoRemote/ChronoRemote.xcodeproj
```

1. Select the **ChronoRemote** scheme and your iPhone as the destination.
2. Set your signing team in `ios/ChronoRemote/Local.xcconfig` (see below) rather than in
   *Signing & Capabilities*. Xcode will pick a bundle identifier automatically if
   `in.chrono.remote` is taken.
3. Press **Run**.
4. On the iPhone: Settings ▸ General ▸ VPN & Device Management ▸ trust your developer certificate.

Always run the **ChronoRemote** scheme, never `ChronoRemoteWidget`. The extension holds a Live
Activity and nothing else, so it publishes no widget for the Home Screen and there is nothing to
launch on its own — running it fails with `Failed to get descriptors for extensionBundleID`. The
`.appex` is embedded in the app and the system loads it when `Activity.request` is called; to
debug it, run the app and use *Debug ▸ Attach to Process*.

### Signing

The project file is generated *and* committed, so a **Team** set through Xcode's UI is written
into it — where it becomes a permanent local modification everyone has to work around, and is
wiped the next time anyone regenerates. The team therefore lives in `Local.xcconfig`, which is
gitignored and referenced as the targets' base configuration:

```bash
# Xcode ▸ Settings ▸ Accounts shows your team id
echo 'DEVELOPMENT_TEAM = XXXXXXXXXX' > ios/ChronoRemote/Local.xcconfig
```

`Scripts/generate-ios-project.py` creates the file if it is missing and never overwrites it — it
is the one file here you are expected to edit. Setting `CHRONO_DEVELOPMENT_TEAM` before the first
run seeds it for you.

Only device builds and archives need a team; the simulator does not. Because the value is not in
the project file, `git status` stays clean and the tracked project is byte-identical for every
contributor.

First build needs iOS platform support installed in Xcode (Settings ▸ Components). Without it
the Swift compiles fine but the app-icon step fails.

With a **free** Apple ID the app stops launching after 7 days and needs a re-run. A paid
Developer account ($99/year) makes it a year.

### Pairing

1. On the Mac: Settings ▸ Phone ▸ enable **Advertise over Bluetooth LE**, then **Show the pairing
   code**.
2. In the app, tap **Scan the code** and point it at the Mac.

The same QR code serves both transports, so there is one pairing step regardless of which you
use. After that the app finds the Mac over Bluetooth on its own; no network involved.

### What it does

- Live timer, task, and today's progress against your target.
- A prominent banner when the Mac thinks you are on a call while a task is still tracking — the
  exact moment you want to hit pause.
- Pause / resume / stop, switch to a meeting bucket, snooze reminders for 30 minutes.
- Queued-worklog and unfiled-time counts, so you know if something needs attention.

Buttons apply optimistically so they feel instant; the Mac's next notification is authoritative.

### On the Lock Screen

While a timer is running the app puts a Live Activity on the Lock Screen and in the Dynamic
Island: the task, the elapsed time, today's progress against your target, and the same call
warning the app shows. Nothing to open.

The timer there ticks on the phone, not over Bluetooth. Each snapshot from the Mac is converted
into a start *instant* — `now - elapsed` — and the Lock Screen counts up from it on its own. That
is not an optimisation: ActivityKit rate-limits updates and starts dropping them from an app that
asks too often, so a per-second update would end up frozen at a stale time while still looking
authoritative. Updates are spent only on things a clock cannot derive — pausing, resuming,
changing task, a call starting.

When the phone loses the Mac the activity dims and reads *Out of range* rather than vanishing: a
timer that is probably still running is more useful than a blank card, as long as it does not
claim more certainty than it has.

**One thing it cannot do yet.** The app is not registered for Bluetooth background execution, so
while iOS has it suspended it cannot hear that you paused on the Mac. The Lock Screen keeps
counting until you next open the app, at which point it corrects itself. Fixing that means adding
the `bluetooth-central` background mode, which is a real trade against battery and is tracked in
[ROADMAP.md](ROADMAP.md) rather than assumed.

## Security

Both transports use the same scheme.

- Every command carries `HMAC-SHA256(SHA256(secret), "counter.timestamp." + payload)`.
- The pairing secret reaches the phone **only** in the QR code's URL fragment. Browsers never
  send fragments to servers, so even over plain HTTP the secret is never transmitted.
- Replays are rejected by a monotonic per-device counter *and* a two-minute timestamp freshness
  window. The counter covers replay within a session; the window covers replay after the Mac
  restarts and forgets counters.
- A phone can pause, resume, stop, switch to a meeting bucket, set a note and snooze. It cannot
  reconfigure Jira, submit arbitrary worklogs, or read or delete your history.
- **Ask me before a phone can stop a timer** (Settings ▸ Phone) downgrades a remote stop to a
  pause and asks you to confirm on the Mac. Pausing is always safe; stopping also pushes a
  worklog.
- **Unpair every device** rotates the secret, which invalidates every paired phone immediately.

The secret is stored in the iPhone's Keychain, and in your Mac's login Keychain.

## Troubleshooting

**The app says "Looking for your Mac…" forever.** Check Bluetooth is on for both, and that
Settings ▸ Phone shows *Advertising* on the Mac. Chrono only advertises while the setting is on.

**"Pairing rejected — re-scan the QR code."** The secret was rotated on the Mac. Scan the new code.

**Commands are refused after the Mac restarts.** Only if the phone's clock is more than two
minutes off. Check Set Automatically in Date & Time.

**The web remote loads but shows no data.** The page is served, so the network is fine; the
signature is being rejected. Unpair in the page's header and re-scan.
