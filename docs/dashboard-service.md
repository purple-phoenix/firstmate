# Persistent tailnet-only capacity dashboard service

This document owns the architecture narrative, trust design, and verification evidence for the always-on capacity dashboard.
Mechanics live with their owners: `docs/configuration.md` (config schema), `bin/fm-dash-serve.mjs --help` (routes and one-click allowlist), `bin/fm-dash-install.sh --help` (persistence and tailscale wiring), `bin/fm-dash-inbox.sh --help` (command consumption), and the capacity skill (handling semantics for delivered commands).

## What it is

The service publishes the producer-generated `data/capacity-dashboard.html` at one stable tailnet HTTPS URL that survives reboots, and layers interactive abilities onto it:

- Every current one-click-eligible `CAP-NN` action gets an "Approve & send" button.
- A "Refresh capacity" button reruns `bin/fm-capacity.mjs` server-side and reloads the page; the service also reruns the producer automatically on the configured interval.
- The page is de-anonymized for the authenticated captain: opaque `item-NN`/`project-NN`/`home-NN` references become real names, and work items and decisions are clickable rich detail views (description, test plan, PR link, tailnet preview links, report excerpt, recent activity) assembled from task briefs, recorded metadata, the backlog, and scout reports.
- Open decisions with `data/<origin>/decisions/<key>.md` records show each recorded option with its impact, a per-option Approve button, and a bounded custom-answer control.
- An Ideas section renders `data/ideas/idea-backlog.md`; each idea opens its pitch (`data/ideas/pitches/IDEA-XX.md` when present, else the concept summary) with Approve, Deny, and Add-suggestions controls.
- The producer's collapsed parking lot of captain-parked work (active hold kind `parked`, kept out of the blocked band by `bin/fm-capacity.mjs`) is enriched with each item's real title, park reason, and backlog `since` date labeled "on the books since", plus an Unpark button; the click only enqueues an `unpark` command record and firstmate lifts the hold through the normal backlog lifecycle.
- The producer's calm Recurring section of scheduled cadence work (active hold kind `future` with a still-future `--until` date, kept out of the blocked band by `bin/fm-capacity.mjs`) is enriched with each item's real title, schedule reason, and last completed run with its recorded artifact link, plus a Run now button; the click only enqueues a `run-now` command record and firstmate lifts the schedule hold and dispatches through the normal lifecycle.
- A service bar shows how many captain commands are queued for firstmate.
- Every acknowledgeable action or verdict acknowledges instantly: the served page renders its state straight from the durable command channel, so a pending record renders "Sent to firstmate - in progress", a claimed record renders "Received - being worked" with its claim time, and a claimed click within the last six hours keeps a re-emitted stable action ID rendered as previously approved or denied instead of a bare verdict control.
- Idea suggestions are deliberately additive and never acknowledge persistently, so sending one cannot disable a later approve or deny verdict.
- A pending or generation-matched claimed action therefore does not look undecided after a reload, and a stable ID re-emitted within the six-hour window stays acknowledged; outside that window it is a genuinely new decision context and renders fresh.
- A Subscription usage band shows cached `quota-axi --json` windows for Claude, Codex, and Grok, including percent used and reset distance with reset time formatted by the captain's browser in local time.
- Every blocked row carries its plain-language blocker chain resolved to the root cause plus an explicit "What you can do" line, so no blocked row leaves the captain guessing; chains stay privacy-safe in the on-disk file and de-anonymize at serve time like every other reference.
- A keyless `needs-decision` status event renders honestly as a worker question that Firstmate is handling in chat, with no fabricated decision identity, `Decide` framing, or dead-end decision detail view.
- The served page has zero copy-prompt affordances: each producer copy button is replaced by direct dispatch, or removed outright in read-only mode, while the offline file keeps its copy buttons for `file://` use.
- The installer pins the installing shell's `PATH` into the launchd agent so the generator's state-reader tools resolve, and the service marks a render `RENDER DEGRADED` loudly on the page and in its log when most worker states read unknown - degraded data is never presented as truth.
- That degraded banner distinguishes unresolved current-state sources from a missing-tools environment so a state-reader attribution miss is not mislabeled as only a PATH problem.

`bin/fm-capacity.mjs` remains the single owner of the dashboard's content and look; the service injects its interactive layer at serve time and never modifies the file on disk, so the file keeps working offline exactly as before.
The on-disk dashboard stays identity-opaque: the producer's opt-in `--refs` sidecar (`state/dash-refs.json`, `fm-capacity-refs.v1`, mode 0600) carries the opaque-to-real mapping, and only the captain-authenticated service reads it to enrich the served page.

## Components

- `bin/fm-dash-serve.mjs` - the HTTP service, bound to 127.0.0.1 only.
- `bin/fm-dash-install.sh` - launchd agent (`RunAtLoad` + `KeepAlive`, so it survives reboots and crashes), `tailscale serve` mapping, `config/dash.json`, and the registered `fm-dash` watcher check.
- `state/dash-inbox/` - durable captain command records (`fm-dash-command.v1`), one file per clicked action.
- `state/fm-dash.check.sh` - watcher check registered through `bin/fm-check-register.sh`; prints one line while commands are pending so the watcher wakes firstmate.
- `bin/fm-dash-inbox.sh` - firstmate's list/claim helper; claim prints each record before archiving it under `state/dash-inbox/archive/`, so an interruption may re-surface a command but cannot silently lose one.

## Inbound command channel

Button clicks never execute anything.
The design keeps the web process outside every fleet-mutation path:

1. The captain clicks a send or verdict control for a `CAP-NN` action, structured decision answer, idea verdict, parking-lot unpark, or recurring run-now request.
2. The service validates the request (see trust design) and writes one durable `fm-dash-command.v1` record into `state/dash-inbox/` with an atomic temp-file rename, mode 0600.
3. The registered `fm-dash` watcher check notices the pending record on its normal cadence (`FM_CHECK_INTERVAL`, default 300 seconds) and wakes the running firstmate through the standard durable wake queue.
4. Firstmate claims the records with `bin/fm-dash-inbox.sh claim` and handles each record by its kind under the capacity skill's dashboard-command semantics.
5. Claiming touches `state/dash-inbox/.model-stale`; while auto-render is enabled the service polls that marker and reruns the producer promptly, so the model catches up with handled clicks well before the next full auto-render interval.

Consequences of that shape:

- The service holds no session with firstmate, no terminal access, and no merge, dispatch, or teardown capability; compromise of the web process yields at most bogus dashboard command records, which firstmate still re-resolves through every normal lifecycle authority check.
- Delivery is durable: a click made while firstmate is down waits in the inbox and is delivered on the next watcher cycle or session start sweep of pending checks.
- Delivery latency is the watcher check cadence, not instantaneous; the page acknowledges the click instantly from the durable record, then says honestly that the command is queued for firstmate rather than pretending execution.
- Commands survive service restarts, firstmate restarts, and reboots because the inbox is plain durable state.
- Consumption is at-least-once across an interruption between delivery and archive, so Firstmate must apply normal idempotency checks when handling a re-surfaced record.

## Trust design

Identity is enforced at every layer that can fail:

- `tailscale serve` terminates HTTPS on the tailnet and injects the `Tailscale-User-Login` header for the authenticated tailnet peer; Funnel traffic would carry no such identity.
- The service refuses every route except `/healthz` unless that header matches a login in `config/dash.json` (`captain_logins`, recorded from the tailnet self login at install time or passed with `--captain`).
- Authenticated browser POSTs must also carry a matching Origin and `Sec-Fetch-Site: same-origin`; same-machine clients without Origin or `Sec-Fetch-Site` headers remain allowed because a local process is already inside the filesystem trust boundary.
- With no configured captain login the service serves only a setup notice and refuses everything else.
- The service binds 127.0.0.1, so the only remote path in is the tailscale proxy; a local process on the captain's machine is already inside the trust boundary because it could write `FM_HOME` state directly.

Dispatch is validated against records the server itself reads:

- A `CAP-NN` request must currently be recommended by the served dashboard itself AND sit in the service's fixed one-click allowlist of reviewed lifecycle-safe actions; unknown or future IDs are refused with guidance to raise them in captain chat, so new actions default to chat-only.
- A decision answer must name a decision in the producer's current-generation refs sidecar, and its integer option index must match the options document the server just parsed; a custom answer is accepted only for a decision with that document and is bounded to 2,000 characters.
- Decision answers persist and deduplicate against an owner-qualified home, origin, and key so equal keys from different origins or homes remain independently routable after refs regenerate.
- An idea verdict must name an idea currently listed in `data/ideas/idea-backlog.md` and one of the approve, deny, or suggest verbs; on approval, firstmate creates the work item(s) through the normal backlog lifecycle - the service itself never creates work.
- An unpark request must name an item the currently served dashboard itself lists in its parking lot and resolve through the current-generation refs sidecar; the record only asks firstmate to lift the parked hold through the normal backlog lifecycle, and the service never edits any backlog.
- A run-now request must name an item the currently served dashboard itself lists as recurring and resolve through the current-generation refs sidecar; the record only asks firstmate to lift the schedule hold and dispatch through the normal lifecycle, and the service never edits any backlog or dispatches work itself.
- The only free text accepted anywhere is bounded captain-authored content: an idea-suggestion note or decision custom answer authenticated as above and delivered as data for Firstmate, never interpreted or executed by the service.
- A newer approve or deny verdict is published under a fresh immutable inbox name before the unchanged older pending verdict is removed, while suggestions remain additive.
- Destructive, irreversible, and security-sensitive choices stay in captain chat structurally: no current `CAP-NN` prompt grants such authority, the capacity skill forbids treating a dashboard approval as merge or discard authority, decision records carry an explicit re-confirm-in-chat boundary for destructive consequences, and firstmate re-resolves every claimed command through the normal lifecycle before acting.

## Decision options document

The home that owns a decision writes `data/<origin>/decisions/<key>.md`, where `<origin>` is the originating work ID and `<key>` is its stable decision key.
The refs sidecar carries `decision/<home>/<origin>/<key>`, preserving the same durable identity even when the key is not a backlog item ID.
The document is producer-owned decision data and uses this format:

```markdown
# Choose the rollout policy

Explain the decision context and constraints here.

## Options

- [recommended] Conservative rollout - Slower delivery with the lowest regression risk.
- Fast rollout - Reaches everyone this week with higher regression risk.
```

The first level-one heading is the title, prose before `## Options` is context, and each option is one bullet with an optional `[recommended]` marker followed by ` - ` and its impact.
Indented continuation lines extend the preceding impact.
The service accepts at most 20 options and applies bounded text limits while rendering.
Firstmate and workers author this document when filing a new decision, and `bin/fm-decision-hold.sh hold --options-file` publishes it under the originating work in the deciding home through the decision-hold lifecycle.
Legacy decisions without the document remain visible but route the captain to answer in chat.
In v1, an authenticated detail view may assemble only a bounded read-only excerpt from a resolved secondmate `data/<id>/report.md`, the sanctioned document return channel.
Secondmate briefs, metadata, status tails, and chat remain prohibited, and everything else shows only the limited ownership note.

Funnel is never acceptable for this surface.
The installer only ever creates a plain `tailscale serve` mapping, verifies after configuring that no Funnel exposure exists for the served port, and tears the mapping back down and refuses if one is found.
Unreadable, malformed, or schema-unexpected `tailscale serve status --json` output is a verification failure and triggers the same teardown.

## Setup and removal

```
bin/fm-dash-install.sh install                # defaults: port 8847, serve port 8443, captain = tailnet self login
bin/fm-dash-install.sh install --read-only    # serve and auto-render only; no dispatch, no watcher check
bin/fm-dash-install.sh status
bin/fm-dash-install.sh uninstall
```

A read-only install is the right shape for running the service ahead of command-consumption wiring: the page, detail views, refresh, and auto-render all work, command dispatch refuses, and any watcher registration from a prior writable install is removed.

Install is idempotent and prints the stable URL, `https://<machine>.<tailnet>.ts.net:8443/`.
Changing `--serve-port` stages the full replacement, verifies it, removes the previous mapping, and restores the prior config, launchd state, watcher registration, and observed live mapping state if any step fails.
Install refuses a requested serve port that is already owned by another mapping.
Uninstall removes only serve mappings whose live shape is a single root proxy to this dashboard's configured loopback target, plus the launchd agent, watcher check, and watcher trust registration, while keeping `config/dash.json` and any pending commands.
The launchd agent logs to `state/dash-serve.log`.
On a non-macOS host the installer refuses and the service can be run under the local init system with the same tailscale serve mapping.

## Verification evidence

2026-07-28, macOS 15.6, node v26.5.0, tailscale CLI present at /opt/homebrew/bin/tailscale.
`bash tests/fm-dash.test.sh` passed end to end against a live local service instance: identity-less and wrong-identity requests got 403 with no inbox write; cross-origin browser posts were refused; authorized CAP, parking-lot unpark, and recurring run-now dispatches wrote mode-0600 `fm-dash-command.v1` records; duplicate and stale unpark and run-now requests were refused or deduplicated; served parking and recurring rows received their authenticated enrichment while the offline artifact withheld private reasons and identities; decision documents, custom answers, newest-verdict replacement, usage filtering, and blocked chains were exercised; `/api/refresh` regenerated the dashboard through the real producer; claim delivered before archive and safely replayed after a simulated archive failure; the registered check shim printed one line only while commands were pending; and the rendered plist carried `RunAtLoad`, `KeepAlive`, the pinned `FM_HOME`, and no Funnel reference.
Same date and environment: the click-acknowledgment lifecycle passed against a live instance - a pending record acknowledged as sent across reloads, a claimed record acknowledged as received under its generation, a rewritten recent claim behind a regenerated model acknowledged as previously approved while a 10-hour-old claim rendered fresh, decision and idea detail views carried their own acknowledgment fields without cross-contamination, the claim helper's stale marker triggered a prompt server-side regeneration, and the backlog was byte-identical before and after serving acknowledgments.
The launchd bootstrap and live `tailscale serve` mapping mutate the host machine and were not exercised from the isolated task worktree; run `bin/fm-dash-install.sh install` once on the target machine and confirm `status` shows the agent loaded, the serve mapping present, and `tailscale serve status` showing no Funnel line for the port.
