#!/usr/bin/env python3
"""Creates Chrono's starter issues and labels on GitHub.

Idempotent: labels are updated in place, and an issue whose exact title already exists (open or
closed) is skipped. Safe to re-run after editing the lists below.

Uses the GitHub REST API over the standard library only — no `gh`, no `requests`, nothing to
install. The token is resolved in this order:

  1. --token-ref op://Vault/Item/field   (default: the reference below)
  2. GITHUB_TOKEN in the environment
  3. `gh auth token`, if the CLI happens to be installed

Reading the token from 1Password rather than an environment variable or a file is the point: it
never lands in shell history, a dotfile, or this repository.

    python3 Scripts/seed-issues.py --dry-run    # show what would happen
    python3 Scripts/seed-issues.py              # create anything missing
"""

import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "ai-slop-in-a-quiet-forge/jira-tracker-mac"
API = "https://api.github.com"
DEFAULT_TOKEN_REF = "op://Personal/personal-api-token-for-gh-quietforge/credential"

LABELS = [
    ("bug", "d73a4a", "Something behaves wrongly"),
    ("enhancement", "a2eeef", "New capability or improvement"),
    ("good first issue", "7057ff", "Small, self-contained, a nice way in"),
    ("help wanted", "008672", "Maintainers would welcome someone taking this on"),
    ("tests", "fbca04", "Test coverage"),
    ("docs", "0075ca", "Documentation"),
    ("accessibility", "c2e0c6", "VoiceOver, keyboard navigation, contrast"),
    ("i18n", "c5def5", "Localisation and translation"),
    ("packaging", "bfd4f2", "Building, signing, distribution"),
    ("epic", "5319e7", "Large piece of work, likely several PRs"),
    ("area: jira", "1d76db", "Jira API, worklogs, sync"),
    ("area: sensors", "d4c5f9", "Idle, microphone, camera, power events"),
    ("area: ui", "f9d0c4", "Menu bar, panel, timesheet, settings"),
    ("area: remote", "fef2c0", "Phone remote transports and protocol"),
    ("platform: ios", "bfdadc", "The iOS companion app"),
    ("platform: windows", "e99695", "Windows and Linux support"),
]

# (title, labels, body)
ISSUES = [
    (
        "Test the web remote's port-collision fallback",
        ["tests", "area: remote", "good first issue"],
        """`WebRemoteServer` retries on an OS-assigned port if the configured one fails to bind, but
that branch has never actually executed.

Two reasons it could not be provoked while writing it:

- `allowLocalEndpointReuse` means a second bind of the same port succeeds rather than colliding.
- macOS let a normal user process bind port 80, so even a privileged port did not fail.

It is annotated as untested in the source, which is honest but not a substitute for a test.

**Where:** `Sources/ChronoApp/Remote/WebRemoteServer.swift`

**Probable approach:** put a small seam in front of `NWListener` so a test can inject a listener
that reports `.failed`, then assert the server ends up listening on a different port. That may
mean moving the retry logic somewhere testable, the way `HTTPRequest` was moved into
`ChronoCore`.""",
    ),
    (
        "Let hotkeys be changed in Settings",
        ["enhancement", "area: ui", "good first issue"],
        """The global shortcuts work, are persisted in `HotkeySet` and are registered without needing any
Accessibility permission. But Settings ▸ Tracking only *displays* them, so the defaults
(`⌃⌥T`, `⌃⌥S`, `⌃⌥P`, `⌃⌥I`) are all anyone can have.

**What is needed:** a shortcut-recorder control, writing back into `settings.hotkeys`, then
calling `HotkeyManager.apply(_:handlers:)` again so the change takes effect without a relaunch.

**Where:** `Sources/ChronoApp/Panels/Settings/TrackingSettingsTab.swift` (currently
`shortcutRow` renders them read-only), `Sources/ChronoApp/App/HotkeyManager.swift`.

Worth handling the case where a combination is already taken by another app —
`RegisterEventHotKey` fails and currently just logs.""",
    ),
    (
        "Localise the interface",
        ["enhancement", "i18n", "good first issue", "help wanted"],
        """Every user-facing string is hardcoded English. Extracting them into a String Catalogue is
mechanical work that would open Chrono up to a lot more people, and it gets harder the longer it
waits.

**Scope:** `Sources/ChronoApp/Panels/**`, plus the notification and intervention copy in
`Sources/ChronoApp/Platform/Notifier.swift` and `Panels/InterventionView.swift`.

Two things to be careful about:

- Duration formatting in `ChronoCore/Util/Formatting.swift` produces `2h 15m`. That needs proper
  localisation, not string concatenation.
- The menu bar has a hard width budget. Some languages will need shorter forms.

Splitting this across several PRs (one screen at a time) is completely fine.""",
    ),
    (
        "Accessibility audit of the panel and timesheet",
        ["accessibility", "area: ui", "help wanted"],
        """No VoiceOver pass has been done. Several controls are icon-only with a tooltip, which is not
an accessible label, and keyboard navigation of the issue list is untested.

**Worth checking:**

- Labels and traits on the pause/stop/more buttons in `NowTrackingCard`.
- The issue rows in `PanelList` — currently a tap gesture on a container, which VoiceOver will
  not announce as a button.
- Colour is used alone to convey state in a few places (the day progress bar, draft states).
- Contrast of `.tertiary` text at 10–10.5pt.
- Whether the floating intervention panel is announced when it appears.

Small PRs, one area at a time, very welcome.""",
    ),
    (
        "Support more than one Jira site",
        ["enhancement", "area: jira"],
        """`JiraConnection` holds a single set of credentials, so anyone contracting across several Jira
sites can only use Chrono for one of them.

Partly prepared already: `KeychainStore` namespaces tokens by account email, and
`PersistedState.jiraAccountID` exists and warns when history appears to belong to a different
account.

**What is needed:** a list of connections rather than one, the active connection selectable from
the panel, and `jiraAccountID` respected per segment so a worklog goes to the right site. The
sync queue would need to fan out per account.

Design decisions worth discussing in this issue before writing code.""",
    ),
    (
        "Edit entry start and end times inline in the timesheet",
        ["enhancement", "area: ui", "good first issue"],
        """`TrackingEngine.updateSegment(id:start:end:note:)` already exists, is tested, and handles
clamping. The timesheet only exposes *delete* and *move to another issue*, so correcting a start
time means deleting the entry and re-adding it.

**What is needed:** make the times in `SegmentRow` editable — most likely a popover with two
`DatePicker`s, mirroring `BackfillButton`'s form — and call `updateSegment`.

**Where:** `Sources/ChronoApp/Panels/TimesheetSections.swift`

Worth refusing an edit that would overlap the neighbouring segment, the way
`backdateStart(by:)` already does.""",
    ),
    (
        "Suggest an issue key from the current git branch",
        ["enhancement", "good first issue"],
        """A branch called `CYM-1234-fix-parser` should make Chrono offer `CYM-1234` at the top of the
panel. Small feature, disproportionately nice for developers, and it removes the most common
reason to type anything at all.

**The hard part is knowing which repository you are looking at.** Options, roughly in order of
preference:

1. A configured list of directories to watch, checked with `git rev-parse --abbrev-ref HEAD`.
2. The frontmost app's window title, which many editors set to the project path.
3. Ask the user to point Chrono at their code directory once.

Option 1 is the least magical and the easiest to reason about. `IssueService.looksLikeIssueKey`
already parses the key format.""",
    ),
    (
        "Tempo-compatible CSV export",
        ["enhancement", "area: jira", "good first issue"],
        """`Export` produces a reasonable generic CSV, but teams using Tempo need a specific column
layout to import time.

Additive and self-contained: a third function alongside `segmentsCSV` and `dailyTotalsCSV`, plus
a menu entry in Settings ▸ Advanced.

**Where:** `Sources/ChronoCore/Storage/Export.swift`,
`Sources/ChronoApp/Panels/Settings/AdvancedSettingsTab.swift`

Please include a test — the existing CSV code has none, and quoting is exactly where this kind
of thing breaks. `Export.escape` implements RFC 4180 and is worth exercising.""",
    ),
    (
        "Detect screen sharing as a meeting signal",
        ["enhancement", "area: sensors"],
        """Sharing your screen is an even stronger "you are in a meeting" signal than a live microphone,
and it catches the case Chrono currently misses entirely: presenting while muted.

**Where:** `Sources/ChronoApp/Platform/MediaSensor.swift` for the detection,
`Sources/ChronoCore/Engine/ActivitySnapshot.swift` for the new field, and
`meetingSignal(settings:)` for how it grades.

Suggested grading: screen sharing plus a known meeting app running should be `.certain`, on a par
with mic-and-camera.

Worth investigating whether this can be read without requiring Screen Recording permission —
Chrono currently needs no permissions at all for its sensors, which is a property worth keeping.""",
    ),
    (
        "Per-app idle exemptions",
        ["enhancement", "area: sensors"],
        """Reading a long document is not idleness, but Chrono cannot tell the difference. An allowlist —
"do not count me as idle while Preview, a PDF reader or a browser is frontmost" — would remove a
real annoyance for anyone whose work involves reading.

The plumbing mostly exists: `AppSensor.frontmostApp()` already reports the frontmost bundle id,
and `ActivitySnapshot` carries it.

**What is needed:** a setting for the allowlist, and a check in `InterventionPolicy` (or in
`ActivityMonitor` when composing the snapshot) that suppresses the idle prompt while an exempt
app is in front.

Please add tests to `PolicyTests` — the policy is pure, so this is cheap to cover.""",
    ),
    (
        "iOS Live Activity and Lock Screen widget",
        ["enhancement", "platform: ios"],
        """The iOS remote works, but you have to open it. A Live Activity showing the running timer, and
a Lock Screen control to pause, would make it genuinely ambient — which is the whole point of
having a phone remote.

**The structural part:** this needs a widget extension target, so
`Scripts/generate-ios-project.py` grows a second target and an app group for sharing state.
Anyone taking this on should expect the generator to be most of the work.

**Where:** `ios/ChronoRemote/`, `Scripts/generate-ios-project.py`

The BLE client already keeps a locally-ticking `displayElapsed`, which is what a Live Activity
needs to avoid updating once a second over Bluetooth.""",
    ),
    (
        "A weekly summary worth reading",
        ["enhancement", "area: ui"],
        """The timesheet reports totals. It could report something a person would actually act on: how
fragmented the week was, which issues ate the time, how much never got a ticket, how estimates
compared with reality.

`DayRollup` and `WeekRollup` already compute most of the inputs, including `contextSwitches` and
`untrackedWithinSpanSeconds`, which nothing currently surfaces properly.

**Where:** `Sources/ChronoApp/Panels/TimesheetView.swift`, with any new aggregation added to
`Sources/ChronoCore/Models/DayRollup.swift` (and tested there).

Design input welcome in this issue before anyone writes code — the risk here is building a
dashboard nobody reads.""",
    ),
    (
        "Option to show the day's total in the menu bar",
        ["enhancement", "area: ui", "good first issue"],
        """The menu bar shows the current session's elapsed time. Some people would rather see progress
toward the day's target, or both.

**What is needed:** a setting, and a branch in `StatusItemController.menuBarTitle(engine:status:)`.

**Where:** `Sources/ChronoApp/MenuBar/StatusItemController.swift`,
`Sources/ChronoCore/Models/Settings.swift`

Please keep the width stable — the title uses monospaced digits and hours:minutes precisely so
the menu bar does not shuffle sideways once a second. There is a test in `RollupTests`
(`compactFormatIsStable`) guarding that property for the existing format.""",
    ),
    (
        "Calendar integration for meeting time",
        ["enhancement", "area: sensors"],
        """Chrono knows you are *in* a call but not *which* meeting. Reading the local calendar would let
it label meeting time with the real event, and offer to backfill meetings you forgot to track at
all.

**Constraints, because a calendar is sensitive:**

- Opt-in, off by default, like every other Chrono sensor.
- Read-only.
- Only events overlapping the tracked period, and only title and time.
- Nothing about it should leave the machine.

**Where:** a new sensor in `Sources/ChronoApp/Platform/`, feeding `ActivitySnapshot`; EventKit
with `NSCalendarsUsageDescription` added in `Scripts/build-app.sh`.

Note this would be the first permission prompt Chrono ever shows for a sensor, which is worth
being deliberate about.""",
    ),
    (
        "Homebrew cask for installation",
        ["packaging", "help wanted"],
        """Installing currently means cloning and running `Scripts/build-app.sh`. That is fine for
developers and a real barrier for everyone else.

A cask would be the least-effort route to `brew install --cask chrono`. It needs somewhere to
host a built artefact, so it is coupled to cutting actual releases.

Sparkle-style in-app updates would be nicer but require hosting an appcast, which brushes against
the project's no-server principle. A cask plus GitHub Releases keeps that promise intact.

Related: signing and notarisation, which a downloadable build really needs.""",
    ),
    (
        "Sign and notarise releases",
        ["packaging", "help wanted"],
        """Builds are ad-hoc signed (`codesign --sign -`), which is fine for a local build and means a
*downloaded* build gets Gatekeeper warnings.

This needs someone willing to hold an Apple Developer ID, which is the actual blocker — not the
technical work. `Scripts/build-app.sh` already isolates signing to one step, so wiring in a real
identity plus `notarytool` is small.

Until then, building from source is the supported path and the README says so.

Worth discussing in this issue: who holds the certificate, and what happens to releases if that
person steps away. A project that promises to stay free should not end up depending on one
person's paid account.""",
    ),
    (
        "Investigate Focus mode detection",
        ["enhancement", "area: sensors", "help wanted"],
        """`ActivitySnapshot.focusModeActive` exists and is always `false`, because macOS exposes no
supported API for reading whether a Focus mode is on. `InterventionPolicy` already honours the
field, so a working implementation needs no policy changes.

**Explicitly not wanted:** reading the private `~/Library/DoNotDisturb` database or the
`usernoted` container. Those break between releases and would make Chrono unreliable in a way
that is hard for a user to diagnose.

If a supported route exists — an entitlement, a public framework, something in a newer SDK —
this issue is the place to record it. A negative answer with evidence is a genuinely useful
outcome too, and would let the field be deleted rather than left misleading.""",
    ),
    (
        "Windows and Linux build",
        ["platform: windows", "help wanted", "epic"],
        """This is the single most valuable contribution anyone could make, because it is the one thing
stopping whole teams from using Chrono together.

It is fully specified in [docs/WINDOWS-PORT.md](../blob/main/docs/WINDOWS-PORT.md):

- which layers transfer verbatim (engine, drafting rules, Jira contract, wire protocol, storage
  format) and which need reimplementing;
- the recommended stack (.NET 8 + Avalonia) with the reasoning against Tauri, Swift-on-Windows
  and Electron;
- **the Windows equivalent of every sensor**, including the two usually assumed to be Mac-only:
  microphone and camera use via the `CapabilityAccessManager` ConsentStore registry keys, and the
  Bluetooth peripheral role via `GattServiceProvider`;
- the real UX gap — the Windows tray has no text label — and proposed answers.

**Start with the tests.** The 112 core tests are the specification; port them before any UI, and
the hard-won behaviour comes across intact instead of being rediscovered by bug report.

**Two rules the port must keep:** do not change the storage format, and do not change the remote
protocol without bumping `ChronoRemote.protocolVersion`. One phone should drive either desktop,
and a person should be able to move between machines with their history.

Phases 1–3 in that document are a usable app on their own and worth shipping before the sensors
exist. Comment here if you start on it, so effort is not duplicated.""",
    ),
]


# ------------------------------------------------------------------------------- transport

def resolve_token(argv: list[str]) -> str | None:
    """Finds a token without ever printing it."""
    ref = DEFAULT_TOKEN_REF
    if "--token-ref" in argv:
        ref = argv[argv.index("--token-ref") + 1]

    result = subprocess.run(
        ["op", "read", "--no-newline", ref],
        capture_output=True, text=True, check=False,
    )
    if result.returncode == 0 and result.stdout.strip():
        print(f"token: 1Password ({ref})")
        return result.stdout.strip()

    if os.environ.get("GITHUB_TOKEN"):
        print("token: GITHUB_TOKEN")
        return os.environ["GITHUB_TOKEN"].strip()

    result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=False)
    if result.returncode == 0 and result.stdout.strip():
        print("token: gh auth token")
        return result.stdout.strip()

    return None


def trust_store() -> ssl.SSLContext:
    """An SSL context with a working CA bundle.

    Python's default trust store is frequently unset on macOS — notably inside a virtualenv,
    where `ssl.get_default_verify_paths().cafile` comes back as None and every HTTPS request
    fails with CERTIFICATE_VERIFY_FAILED. Rather than the usual "disable verification" fix,
    which would be indefensible in a script handling a personal access token, point at a real
    bundle explicitly.
    """
    candidates = [
        os.environ.get("SSL_CERT_FILE"),
        ssl.get_default_verify_paths().cafile,
        "/etc/ssl/cert.pem",                              # macOS
        "/opt/homebrew/etc/ca-certificates/cert.pem",      # Homebrew OpenSSL
        "/etc/ssl/certs/ca-certificates.crt",              # Debian, Ubuntu
        "/etc/pki/tls/certs/ca-bundle.crt",                # Fedora, RHEL
    ]
    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return ssl.create_default_context(cafile=candidate)

    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        # Verification stays on. If there is genuinely no bundle anywhere, failing loudly is
        # the correct outcome.
        return ssl.create_default_context()


class GitHub:
    def __init__(self, token: str):
        self.token = token
        self.context = trust_store()

    def request(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
        url = path if path.startswith("http") else f"{API}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "chrono-seed-issues")
        if data is not None:
            req.add_header("Content-Type", "application/json")

        try:
            with urllib.request.urlopen(req, timeout=30, context=self.context) as response:
                payload = response.read()
                return response.status, (json.loads(payload) if payload else None)
        except urllib.error.HTTPError as error:
            payload = error.read()
            try:
                decoded = json.loads(payload)
            except Exception:
                decoded = {"message": payload.decode("utf-8", "replace")[:200]}
            return error.code, decoded
        except urllib.error.URLError as error:
            return 0, {"message": str(error.reason)}

    def paged(self, path: str) -> list:
        """Collects every page of a list endpoint."""
        collected: list = []
        page = 1
        while True:
            status, body = self.request("GET", f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            if status != 200 or not isinstance(body, list) or not body:
                break
            collected.extend(body)
            if len(body) < 100:
                break
            page += 1
        return collected


# ------------------------------------------------------------------------------------ main

def main() -> int:
    argv = sys.argv[1:]
    dry_run = "--dry-run" in argv

    github: GitHub | None = None
    if not dry_run:
        token = resolve_token(argv)
        if not token:
            print("No token found. Add one to 1Password, set GITHUB_TOKEN, or run gh auth login.")
            return 1
        github = GitHub(token)

        status, body = github.request("GET", f"/repos/{REPO}")
        if status != 200:
            message = body.get("message") if isinstance(body, dict) else body
            print(f"Cannot read {REPO}: HTTP {status} — {message}")
            return 1
        # `push` permission is what the issues endpoint needs for labelling.
        can_push = bool(body.get("permissions", {}).get("push")) if isinstance(body, dict) else False
        print(f"repo:  {REPO} (write access: {'yes' if can_push else 'no'})")

    print(f"mode:  {'dry run' if dry_run else 'live'}\n")

    # --- labels ---------------------------------------------------------------------------
    print("Labels")
    existing_labels: set[str] = set()
    if github:
        existing_labels = {item["name"] for item in github.paged(f"/repos/{REPO}/labels")}

    for name, colour, description in LABELS:
        if dry_run:
            print(f"  would ensure  {name}")
            continue
        assert github
        payload = {"name": name, "color": colour, "description": description}
        if name in existing_labels:
            # URL-encode the name: several labels contain a space or a colon.
            encoded = urllib.parse.quote(name, safe="")
            status, body = github.request("PATCH", f"/repos/{REPO}/labels/{encoded}", payload)
            verb = "updated"
        else:
            status, body = github.request("POST", f"/repos/{REPO}/labels", payload)
            verb = "created"
        if status in (200, 201):
            print(f"  {verb:<8} {name}")
        else:
            message = body.get("message") if isinstance(body, dict) else body
            print(f"  FAILED   {name}  (HTTP {status} — {message})")

    # --- issues ---------------------------------------------------------------------------
    existing_titles: set[str] = set()
    if github:
        # This endpoint returns pull requests too; those are not issues for our purposes.
        for item in github.paged(f"/repos/{REPO}/issues?state=all"):
            if "pull_request" not in item:
                existing_titles.add(item["title"])

    print("\nIssues")
    created = skipped = failed = 0
    for title, labels, body_text in ISSUES:
        if title in existing_titles:
            print(f"  exists   {title}")
            skipped += 1
            continue
        if dry_run:
            print(f"  would create  {title}  [{', '.join(labels)}]")
            created += 1
            continue

        assert github
        status, response = github.request(
            "POST",
            f"/repos/{REPO}/issues",
            {"title": title, "body": body_text, "labels": labels},
        )
        if status == 201 and isinstance(response, dict):
            print(f"  #{response['number']:<3} {title}")
            created += 1
        else:
            message = response.get("message") if isinstance(response, dict) else response
            print(f"  FAILED   {title}  (HTTP {status} — {message})")
            failed += 1

    print(f"\n{created} created, {skipped} already there, {failed} failed")
    if github and created:
        print(f"\nhttps://github.com/{REPO}/issues")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
