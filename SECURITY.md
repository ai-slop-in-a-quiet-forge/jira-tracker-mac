# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private vulnerability reporting on this repository: *Security* ▸ *Report a
vulnerability*. That creates a private thread visible only to the maintainers.

Include what you can: what an attacker can do, what access they need first, and a minimal way to
reproduce it. A partial report is much better than no report — if you are unsure whether
something counts, send it.

There is no bounty. This is a free tool maintained by volunteers, and we will be straightforwardly
grateful.

## What Chrono holds, and where

Useful context for assessing a finding.

| Secret | Stored | Notes |
|--------|--------|-------|
| Jira API token | login Keychain, `kSecAttrAccessibleAfterFirstUnlock` | Or read from 1Password on demand and never stored at all |
| Phone pairing secret | login Keychain | 32 bytes from `SecRandomCopyBytes` |
| Tracked history | `~/Library/Application Support/Chrono/*.json` | Issue keys, timestamps and your notes. **Never** credentials |

Chrono makes network requests to exactly two places: your own Jira site, and — only if you
enable the phone remote — connections *inbound* from your own local network.

## Threat model

What the design actually defends against, so a report can say which assumption it breaks.

**The phone remote** is the largest attack surface, and it is off by default.

- Both transports are opt-in. Nothing listens or advertises until enabled in Settings ▸ Phone.
- Every command must carry `HMAC-SHA256(SHA256(secret), "counter.timestamp." + payload)`. An
  unsigned or wrongly-signed request is refused.
- The pairing secret reaches the phone only through the QR code's URL **fragment**. Browsers do
  not transmit fragments, so the secret is never sent over the network even though the LAN
  remote is plain HTTP.
- Replay is blocked by a monotonic per-device counter **and** a two-minute timestamp freshness
  window. The counter covers replay within a session; the window covers replay after a restart
  has cleared the counters.
- The signature is verified **before** the counter is recorded, so an attacker cannot burn
  counter values with forged requests.
- A phone's authority is bounded: pause, resume, stop, switch to a meeting bucket, set a note,
  snooze. It cannot read history, change Jira settings or submit arbitrary worklogs.

**Known and accepted:**

- The LAN remote is plain HTTP. Request *bodies* on the local network are therefore visible to
  anyone already on it. Bodies contain commands, never the secret. Adding TLS would mean a
  self-signed certificate and a browser warning on every launch, which we judged worse.
- An attacker with read access to your logged-in user account can read the Keychain, like any
  other app you have. Chrono does not defend against local privilege escalation.
- The Mac app is ad-hoc signed. Builds are from source; there is no signed distribution channel
  yet (see [docs/ROADMAP.md](docs/ROADMAP.md)).

**Out of scope:**

- Anything requiring physical access to an unlocked machine.
- Jira's own security. Chrono uses a scoped, user-revocable API token; revoke it at
  id.atlassian.com if you suspect exposure.

## Things we would very much like to hear about

- Any way to make Chrono execute a remote command without the pairing secret.
- Any way to read the pairing secret or the Jira token off the wire, or out of a file.
- A credential appearing in any file, log line or crash report. Everything is written through
  helpers that redact tokens, but a missed path is exactly the kind of bug that hides.
