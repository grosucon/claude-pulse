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
- **Opening the popover does NOT refresh** — would spam the endpoint every time you peek. Press the **Refresh** button (it spins during the fetch) when you want a fresh read.

## Install

```bash
./scripts/install.sh
```

Builds, bundles, and drops `Claude Pulse.app` into `~/Applications/`:

- **Spotlight**: ⌘-Space → "Claude Pulse"
- **Finder**: `~/Applications` → Claude Pulse
- **Auto-launch on login**: System Settings → General → Login Items & Extensions → add `~/Applications/Claude Pulse.app`

The first time you click the menu bar icon, macOS prompts to allow Keychain access — click **Always Allow**.

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

## Caveats

- **Unofficial endpoint.** `/api/oauth/usage` is undocumented. If Anthropic changes the response shape, the popover gauges go blank until the parser is updated.
- **Personal use only.** Don't redistribute the binary to other users — Anthropic's Feb 2026 policy bans third-party reuse of OAuth tokens. Each user must install from source against their own Keychain.
- **Cross-surface counting.** Anthropic counts your claude.ai web, Claude Desktop, and Claude Code usage against the same weekly limit. The endpoint returns the combined number (not just Claude Code), so this is accurate.

## Project layout

See [`CLAUDE.md`](CLAUDE.md) for architecture, conventions, and the running playbook for changes.
