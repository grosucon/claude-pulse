# Claude Pulse

A small macOS menu bar app that mirrors `claude /usage` — real numbers, no estimation.

```
 [icon] 6%       ← click to open
```

```
┌─ Claude Pulse ──────────────┐
│  Current session            │
│  ██░░░░░░░░░  6% used       │
│  resets in 4 hr, 54 min     │
│                             │
│  WEEKLY                     │
│  All models    4% used      │
│  ▌░░░░░░░░░                 │
│  resets Tue 11:59 PM        │
│                             │
│  Sonnet only   0% used      │
│  ░░░░░░░░░░                 │
│  not used yet               │
│                             │
│  Claude Design 0% used      │
│  ░░░░░░░░░░                 │
│  not used yet               │
│                             │
│  EXTRA USAGE                │
│  Spend     €0.00 / €40.00   │
│  ░░░░░░░░░░                 │
│  resets Jun 1               │
│                             │
│  ↻ 13:55             Quit   │   ↻ spins while refreshing
└─────────────────────────────┘
```

## How it works

The app reads your Claude Code OAuth token from the macOS Keychain (the same `Claude Code-credentials` item the `claude` CLI writes) and calls Anthropic's `https://api.anthropic.com/api/oauth/usage` endpoint — the same one `/usage` itself uses. Numbers match the in-CLI panel exactly, no calibration constants involved.

- **No third-party services, no telemetry**, no on-disk caching of the token (ephemeral `URLSession`).
- **Polls every 5 minutes.** The endpoint is per-token rate-limited (~5 requests per window) and the token is shared with the `claude` CLI itself — polling faster gets you 429'd. On a 429, the next poll is pushed ~20 minutes out (4× backoff) so the endpoint isn't hammered.
- **Auto-refreshes ~10s after each session reset** so the popover doesn't sit on stale numbers (or count up past zero) for the rest of the 5-minute window. One extra fetch per 5-hour session — well under the rate-limit ceiling.
- **Opening the popover does NOT refresh** — would spam the endpoint every time you peek. Press the **Refresh** button (it spins during the fetch) when you want a fresh read.
- **Keychain reads go through `/usr/bin/security`**, not `SecItemCopyMatching` directly. Reason: `claude` rotates the OAuth token every ~8 hours and its write resets the keychain item's partition list, which would normally evict Claude Pulse and trigger an "Always Allow" prompt three times a day even after you'd already granted access. Apple's `security` CLI lives in the `apple-tool` partition that survives those resets, so the prompt only ever appears on first install. Trade-off: a `Process` spawn per poll instead of an in-process call — negligible at a 5-minute cadence.

## Install

```bash
./scripts/install.sh
```

Builds, bundles, and drops `Claude Pulse.app` into `~/Applications/`:

- **Spotlight**: ⌘-Space → "Claude Pulse"
- **Finder**: `~/Applications` → Claude Pulse
- **Auto-launch on login**: System Settings → General → Login Items & Extensions → add `~/Applications/Claude Pulse.app`

The first time you click the menu bar icon, macOS may prompt to allow Keychain access — click **Always Allow**. You should only see this prompt once; see "How it works" for why.

Re-run `./scripts/install.sh` after any code change to refresh the installed bundle. To stop: `pkill -f 'Claude Pulse.app'`.

## Tests

```bash
swift test
```

## Smoke-test against your real data

```bash
swift run -c release CPSmoke
```

Prints today's snapshot (utilization %, reset times, extra usage) straight from Anthropic.

## On-disk data

Each poll appends a line to:

```
~/Library/Application Support/ClaudePulse/snapshots.jsonl
```

Append-only JSONL, one record per line: the parsed usage percentages and reset times (~500 bytes/record). Survives Finder drag-to-Trash of `Claude Pulse.app` and survives `./scripts/install.sh`.

- **Only writes on change.** A successful poll is recorded only when your usage actually moved since the last record — back-to-back idle polls (same numbers) are skipped, so the log doesn't fill with duplicates. Failures (rate-limit, network, malformed) are always recorded.
- **Capped size.** The file is trimmed to the most recent ~10,000 records (≈ 35 days of *changes* at the 5-minute poll), so it can't grow without bound. At ~500 bytes/record that's a ceiling of ~5 MB.
- **No tokens are written.** The OAuth bearer never enters the snapshot record — pinned by a regression test. The file is created `0600` (owner read/write only).
- To clear history: `rm ~/Library/Application\ Support/ClaudePulse/snapshots.jsonl`.
- Third-party uninstallers like AppCleaner *will* find and delete this file along with the app bundle. If you want history to survive a full uninstall, copy it out first.

Nothing reads the file yet — it's the foundation for upcoming features (burn-rate forecasts, sparkline, threshold notifications).

## Caveats

- **Unofficial endpoint.** `/api/oauth/usage` is undocumented. If Anthropic changes the response shape, the popover gauges go blank until the parser is updated.
- **Personal use only.** Don't redistribute the binary to other users — Anthropic's Feb 2026 policy bans third-party reuse of OAuth tokens. Each user must install from source against their own Keychain.
- **Cross-surface counting.** Anthropic counts your claude.ai web, Claude Desktop, and Claude Code usage against the same weekly limit. The endpoint returns the combined number (not just Claude Code), so this is accurate.
