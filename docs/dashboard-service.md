# Persistent tailnet-only capacity dashboard service

This document owns the architecture narrative, trust design, and verification evidence for the always-on capacity dashboard.
Mechanics live with their owners: `bin/fm-dash-serve.mjs --help` (routes, config schema, one-click allowlist), `bin/fm-dash-install.sh --help` (persistence and tailscale wiring), `bin/fm-dash-inbox.sh --help` (command consumption), and the capacity skill (handling semantics for delivered commands).

## What it is

The service publishes the producer-generated `data/capacity-dashboard.html` at one stable tailnet HTTPS URL that survives reboots, and layers interactive abilities onto it:

- Every current one-click-eligible `CAP-NN` action gets an "Approve & send" button.
- A "Refresh capacity" button reruns `bin/fm-capacity.mjs` server-side and reloads the page; the producer also reruns automatically on the configured interval so the page never goes stale.
- The page is de-anonymized for the authenticated captain: opaque `item-NN`/`project-NN`/`home-NN` references become real names, and work items and decisions are clickable rich detail views (description, test plan, PR link, tailnet preview links, report excerpt, recent activity) assembled from task briefs, recorded metadata, the backlog, and scout reports.
- Open decisions show each recorded option with its impact, and every option carries an Approve button.
- An Ideas section renders `data/ideas/idea-backlog.md`; each idea opens its pitch (`data/ideas/pitches/IDEA-XX.md` when present, else the concept summary) with Approve, Deny, and Add-suggestions controls.
- A service bar shows how many captain commands are queued for firstmate.

`bin/fm-capacity.mjs` remains the single owner of the dashboard's content and look; the service injects its interactive layer at serve time and never modifies the file on disk, so the file keeps working offline exactly as before.
The on-disk dashboard stays identity-opaque: the producer's opt-in `--refs` sidecar (`state/dash-refs.json`, `fm-capacity-refs.v1`, mode 0600) carries the opaque-to-real mapping, and only the captain-authenticated service reads it to enrich the served page.

## Components

- `bin/fm-dash-serve.mjs` - the HTTP service, bound to 127.0.0.1 only.
- `bin/fm-dash-install.sh` - launchd agent (`RunAtLoad` + `KeepAlive`, so it survives reboots and crashes), `tailscale serve` mapping, `config/dash.json`, and the registered `fm-dash` watcher check.
- `state/dash-inbox/` - durable captain command records (`fm-dash-command.v1`), one file per clicked action.
- `state/fm-dash.check.sh` - watcher check registered through `bin/fm-check-register.sh`; prints one line while commands are pending so the watcher wakes firstmate.
- `bin/fm-dash-inbox.sh` - firstmate's list/claim helper; claim archives each record under `state/dash-inbox/archive/` so a command is surfaced exactly once.

## Inbound command channel

Button clicks never execute anything.
The design keeps the web process outside every fleet-mutation path:

1. The captain clicks "Send to firstmate" on a `CAP-NN` action.
2. The service validates the request (see trust design) and writes one durable `fm-dash-command.v1` record into `state/dash-inbox/` with an atomic temp-file rename, mode 0600.
3. The registered `fm-dash` watcher check notices the pending record on its normal cadence (`FM_CHECK_INTERVAL`, default 300 seconds) and wakes the running firstmate through the standard durable wake queue.
4. Firstmate claims the records with `bin/fm-dash-inbox.sh claim` and handles each prompt as the captain's approval of that action ID under the capacity skill's section 4 semantics.

Consequences of that shape:

- The service holds no session with firstmate, no terminal access, and no merge, dispatch, or teardown capability; compromise of the web process yields at most bogus `CAP-NN` approval records, which firstmate still re-resolves through every normal lifecycle authority check.
- Delivery is durable: a click made while firstmate is down waits in the inbox and is delivered on the next watcher cycle or session start sweep of pending checks.
- Delivery latency is the watcher check cadence, not instantaneous; the page says "queued for firstmate" honestly rather than pretending immediacy.
- Commands survive service restarts, firstmate restarts, and reboots because the inbox is plain durable state.

## Trust design

Identity is enforced at every layer that can fail:

- `tailscale serve` terminates HTTPS on the tailnet and injects the `Tailscale-User-Login` header for the authenticated tailnet peer; Funnel traffic would carry no such identity.
- The service refuses every route except `/healthz` unless that header matches a login in `config/dash.json` (`captain_logins`, recorded from the tailnet self login at install time or passed with `--captain`).
- With no configured captain login the service serves only a setup notice and refuses everything else.
- The service binds 127.0.0.1, so the only remote path in is the tailscale proxy; a local process on the captain's machine is already inside the trust boundary because it could write `FM_HOME` state directly.

Dispatch is validated against records the server itself reads:

- A `CAP-NN` request must currently be recommended by the served dashboard itself AND sit in the service's fixed one-click allowlist of reviewed lifecycle-safe actions; unknown or future IDs are refused with guidance to raise them in captain chat, so new actions default to chat-only.
- A decision approval must name a decision in the producer's refs sidecar, and the chosen option must be one the server just parsed from that decision's structured backlog record; an off-record option is refused.
- An idea verdict must name an idea currently listed in `data/ideas/idea-backlog.md` and one of the approve, deny, or suggest verbs; on approval, firstmate creates the work item(s) through the normal backlog lifecycle - the service itself never creates work.
- The only free text accepted anywhere is the bounded add-suggestions note on an idea, which is captain-authored data for firstmate (the tailnet identity check makes it genuinely the captain), never a command the service interprets or executes.
- Destructive, irreversible, and security-sensitive choices stay in captain chat structurally: no current `CAP-NN` prompt grants such authority, the capacity skill forbids treating a dashboard approval as merge or discard authority, decision records carry an explicit re-confirm-in-chat boundary for destructive consequences, and firstmate re-resolves every claimed command through the normal lifecycle before acting.

Funnel is never acceptable for this surface.
The installer only ever creates a plain `tailscale serve` mapping, verifies after configuring that no Funnel exposure exists for the served port, and tears the mapping back down and refuses if one is found.

## Setup and removal

```
bin/fm-dash-install.sh install                # defaults: port 8847, serve port 8443, captain = tailnet self login
bin/fm-dash-install.sh install --read-only    # serve and auto-render only; no dispatch, no watcher check
bin/fm-dash-install.sh status
bin/fm-dash-install.sh uninstall
```

A read-only install is the right shape for running the service ahead of command-consumption wiring: the page, detail views, refresh, and auto-render all work, while every mutation route refuses.

Install is idempotent and prints the stable URL, `https://<machine>.<tailnet>.ts.net:8443/`.
Uninstall removes the serve mapping and launchd agent but keeps `config/dash.json` and any pending commands.
The launchd agent logs to `state/dash-serve.log`.
On a non-macOS host the installer refuses and the service can be run under the local init system with the same tailscale serve mapping.

## Verification evidence

2026-07-28, macOS 15.6, node v26.5.0, tailscale CLI present at /opt/homebrew/bin/tailscale.
`bash tests/fm-dash.test.sh` passed end to end against a live local service instance: identity-less and wrong-identity requests got 403 with no inbox write; an authorized dispatch wrote exactly one mode-0600 `fm-dash-command.v1` record and a duplicate click coalesced; free-text, non-allowlisted (`CAP-99`), and not-currently-recommended IDs were refused; `/api/refresh` regenerated the dashboard through the real producer; claim archived and printed each record exactly once; the registered check shim printed one line only while commands were pending; and the rendered plist carried `RunAtLoad`, `KeepAlive`, the pinned `FM_HOME`, and no Funnel reference.
The launchd bootstrap and live `tailscale serve` mapping mutate the host machine and were not exercised from the isolated task worktree; run `bin/fm-dash-install.sh install` once on the target machine and confirm `status` shows the agent loaded, the serve mapping present, and `tailscale serve status` showing no Funnel line for the port.
