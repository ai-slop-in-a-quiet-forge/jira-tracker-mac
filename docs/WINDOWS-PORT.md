# Phase 2: a build for Windows colleagues

Chrono was rebuilt native for macOS deliberately, trading cross-platform reach for a ~8 MB
install, a real menu bar, reliable mic/camera-based meeting detection and genuine Bluetooth.
This document is the plan for giving Windows colleagues the same app without giving any of that up.

It is a spec, not a stub: everything below is a decision with a reason, so the port is a
re-skin rather than a rediscovery.

## What actually transfers

| Layer | Transfers? | Notes |
|-------|-----------|-------|
| Domain model, engine, drafting rules | **Logic, verbatim** | ~2,000 lines of pure logic with no platform dependency |
| The 103 core tests | **As the specification** | Port these first; they define correct behaviour |
| Jira REST client | **Contract, verbatim** | Endpoints, payload shapes, error taxonomy, dedupe strategy |
| Remote protocol + signing | **Verbatim** | Wire format is language-agnostic and already has a cross-language test vector |
| Storage format | **Verbatim** | Plain JSON; a Windows build can read a Mac file and vice versa |
| Intervention policy | **Logic, verbatim** | Pure function; only the sensor inputs are platform-specific |
| Sensors | **Reimplement** | Table below |
| UI | **Reimplement** | Same information architecture, native idiom |

The important consequence: **the test suite is the port's specification.** Transliterate
`Tests/ChronoCoreTests` into the target language before writing any UI, and the hard-won
behaviour — idle trimming, settle idempotency, crash recovery, rounding on daily totals, the
duplicate-worklog check — comes across intact rather than being rediscovered by bug report.

## Platform equivalents

Every macOS mechanism Chrono relies on has a Windows counterpart. This is the part most likely to
be assumed impossible, so it is spelled out.

| Need | macOS (current) | Windows equivalent |
|------|-----------------|--------------------|
| Idle time | `CGEventSource.secondsSinceLastEventType` | `GetLastInputInfo` (user32) |
| **Microphone in use** | `kAudioDevicePropertyDeviceIsRunningSomewhere` | Registry: `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\...` — each app subkey carries `LastUsedTimeStart` / `LastUsedTimeStop`; a non-zero Start with a zero Stop means in use *now* |
| **Camera in use** | CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` | Same ConsentStore pattern under `\webcam\` |
| Frontmost app | `NSWorkspace.frontmostApplication` | `GetForegroundWindow` + `GetWindowThreadProcessId` + `QueryFullProcessImageName` |
| Running apps | `NSWorkspace.runningApplications` | `EnumProcesses` / `CreateToolhelp32Snapshot` |
| Sleep / wake | `NSWorkspace.willSleepNotification` | `WM_POWERBROADCAST` (`PBT_APMSUSPEND` / `PBT_APMRESUMEAUTOMATIC`) |
| Screen lock | `com.apple.screenIsLocked` distributed notification | `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE` (`WTS_SESSION_LOCK` / `_UNLOCK`) |
| Tray icon + live text | `NSStatusItem` with attributed title | `Shell_NotifyIcon`. **Caveat:** the Windows tray has no text label, only a 16×16 icon. See "The menu bar problem" below |
| Secrets | Keychain | Windows Credential Manager (`CredWrite`/`CredRead`, DPAPI-backed) |
| Launch at login | `SMAppService.mainApp` | `HKCU\...\CurrentVersion\Run`, or a Startup-folder shortcut |
| Global hotkeys | Carbon `RegisterEventHotKey` | `RegisterHotKey` (user32) — same model, no extra permission |
| Notifications | `UNUserNotificationCenter` | Toast notifications (`Windows.UI.Notifications`) |
| **BLE peripheral** | `CBPeripheralManager` | `GattServiceProvider` (`Windows.Devices.Bluetooth.GenericAttributeProfile`) — Windows *does* support the GATT server role, so the iPhone remote can work here too |
| LAN remote | `NWListener` | Any TCP listener; the served page is unchanged |
| QR code | CoreImage `CIQRCodeGenerator` | `ZXing.Net` or `QRCoder` |

Note that mic/camera detection — the feature most likely to be written off as Mac-only — has a
clean Windows implementation. The ConsentStore registry approach is what Windows' own
"microphone in use" indicator reads.

## Recommended stack

**.NET 8 + Avalonia UI**, with the core ported to C#.

Why:

- Every API in the table above is directly reachable (`CsWin32` / `Windows.SDK.Contracts`),
  including the GATT server for Bluetooth.
- `NotifyIcon` and custom flyout windows give a tray experience close to the current panel.
- Self-contained trimmed publish lands around 25–40 MB — the same order as the Mac app, not
  Electron's 200 MB.
- C# maps onto the existing design almost one-to-one: records for the value types, `async`/`await`
  for the Jira client, and xUnit for the ported tests.
- It also runs on Linux, which covers the rest of the request for free.

Alternatives considered:

- **Tauri v2 (Rust + system webview)** — smallest binary (~15 MB) and the web remote's page could
  be reused as the desktop UI. Rejected as first choice because BLE peripheral support in Rust on
  Windows is immature, and the tray/flyout experience needs more hand-work.
- **Swift on Windows** — would reuse `ChronoCore` literally. Rejected: no SwiftUI on Windows, so
  the entire UI is bespoke anyway, and the toolchain is a support burden for colleagues.
- **Electron** — where this project started. Rejected for the reasons in the README.
- **Kotlin Multiplatform / Compose Desktop** — credible, but the Win32 interop story for the
  sensors is worse than .NET's.

## The menu bar problem

The single biggest UX difference: **the Windows tray shows an icon, not text.** The Mac app's
best feature is glanceable — `CYM-1234 1:24` sitting in the menu bar all day.

Options, in order of preference:

1. **Render the elapsed time into the tray icon** as a 16×16 bitmap, redrawn each minute. Cramped
   but genuinely glanceable, and this is what several Windows timers do.
2. **A small always-on-top pill widget**, snapped to a screen edge, showing task and time; opt-in.
3. Tooltip only, with the time in the flyout. Weakest — a tooltip needs a hover.

Recommend 1 as the default with 2 available, and keep the tray tooltip as a fallback.

## Phasing

1. **Port the core and its tests.** No UI. Done when all 103 tests pass in C#.
2. **Jira client + sync queue**, including the duplicate-worklog check. Verified against a real
   Jira Cloud site.
3. **Tray, flyout panel, timesheet.** Feature parity with the Mac panel; native idiom, not a copy
   of the visual design.
4. **Sensors and interventions.** Idle first, then ConsentStore mic/camera, then power/session
   events. Ship the same live sensor readout in Settings — it is how users trust the feature.
5. **Remote transports.** LAN first (the page is unchanged), then the GATT server.
6. **Packaging.** MSIX or a signed installer; self-contained trimmed publish.

Phases 1–3 are a usable app on their own, and worth shipping before 4 exists.

## Compatibility rules for the port

- **Do not change the storage format.** Same JSON, same keys, so a person can move between a Mac
  and a Windows machine and keep their history.
- **Do not change the remote protocol** without bumping `ChronoRemote.protocolVersion`. One phone
  should drive either desktop.
- **Keep the signing test vector.** `SigningContractTests` already pins Swift against JavaScript;
  add the C# implementation to the same vector.
- **Keep the sensor seam.** The Windows code should produce the same `ActivitySnapshot` and hand it
  to the same ported policy, so the interruption behaviour is identical by construction rather
  than by intent.
