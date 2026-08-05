# Persistent tailnet-only capacity dashboard service

This document owns the architecture narrative, trust design, and verification evidence for the always-on capacity dashboard, including its captain chat destination and exact PR merge approval flow.
Mechanics live with their owners: `docs/configuration.md` (config schema), `bin/fm-dash-serve.mjs --help` (routes and one-click allowlist), `bin/fm-dash-install.sh --help` (persistence and tailscale wiring), `bin/fm-dash-inbox.sh --help` (command consumption), `bin/fm-dash-chat.sh --help` (chat claiming and replies), `bin/fm-dash-pr-evidence.mjs` (read-only merge evidence), `bin/fm-dash-merge.sh --help` (guarded merge-approval consumption), and the capacity skill (handling semantics for delivered commands).

## What it is

The service publishes the producer-generated `data/capacity-dashboard.html` at one stable tailnet HTTPS URL that survives reboots, and layers interactive abilities onto it:

- Every current one-click-eligible `CAP-NN` action gets an "Approve & send" button.
- A "Refresh capacity" button reruns `bin/fm-capacity.mjs` server-side and reloads the page; the service also reruns the producer automatically on the configured interval.
- The producer's first viewport is a four-question captain brief: what needs the captain now, who is active and doing what, what is stuck and why, and what shipped in the bounded recent-completion reading.
  The stuck answer includes only intervention-dependent work, while self-clearing waits remain visible on Work and in the canonical manifest.
  One compact Recommended next row projects the existing primary recommendation and its stable `CAP-NN` action path without introducing a second recommendation model or authority path.
  The shipped answer does not represent an exact since-last-visit delta because no browser visit timestamp is stored.
  Genuinely active people lead the brief's bounded roster projection, while idle and unavailable people remain visible behind the same answer.
  Intentional Brief, Work, People, and Ideas navigation keeps recommendations, automatic waits, the pipeline manifest, the full live roster, lanes, definition health, recurring work, parking, landed history, and idea verdicts directly reachable without loading the brief with secondary detail.
  The four answers and Recommended next row stack without horizontal overflow at 320-390px, and every captain Go, Not now, guidance, option, and durable click-command control remains available at those widths.
- The producer assigns each current work identity to exactly one pipeline stage and counts each identity once in pipeline measures.
  The captain brief projects those canonical cards without deriving work state again, so one card can answer both the action-now and stuck-work questions where relevant.
- Recorded GitHub pull-request URLs are reconciled through the producer's bounded `gh-axi` reads before they become current delivery gates, so a merged PR-only wait leaves current work, a closed PR requires delivery reconciliation rather than approval, and unreadable forge state stays explicitly unavailable.
- The People page's Live Agents section shows each observed worker and readable registered domain supervisor with the task, a captain-language activity label, and the observation time.
  Main-home rows use the canonical current-state snapshot, readable secondmate homes contribute their bounded structured worker inventory, and an unreadable home stays visible as an unavailable supervisor rollup rather than disappearing or being guessed.
  When the bounded registry reading cannot identify every additional supervisor, the section reports an explicit unavailable aggregate instead of inventing identities or a count.
- The page is de-anonymized for the authenticated captain: opaque `item-NN`/`project-NN`/`home-NN` references become real names, and work items and decisions are clickable rich detail views (description, test plan, PR link, tailnet preview links, report excerpt, recent activity) assembled from task briefs, recorded metadata, the backlog, and scout reports.
- Open decisions with `data/<origin>/decisions/<key>.md` records show each recorded option with its impact, a per-option Approve button, and a bounded custom-answer control, reached from a Choose button on their needs-you row.
- Every other needs-you row - a captain-kind hold or decision without an options document, a your-go prioritization hold, a captain-gated pause, or approval-ready work - gets generic Go ahead, Not now, and Send-guidance controls (the producer anchors each row with `data-your-go-ref`); a hold whose reason asks the captain to furnish something concrete leads with a Provide-it control whose guidance box is prefilled with the ask, and each click only enqueues a `your-go` command record that firstmate re-resolves through the normal lifecycle.
- The Ideas page renders `data/ideas/idea-backlog.md`; each idea opens its pitch (`data/ideas/pitches/IDEA-XX.md` when present, else the concept summary) with Approve, Deny, and Add-suggestions controls.
- The producer's collapsed parking lot of captain-parked work (active hold kind `parked`, kept out of the blocked band by `bin/fm-capacity.mjs`) is enriched with each item's real title, park reason, and backlog `since` date labeled "on the books since", plus an Unpark button; the click only enqueues an `unpark` command record and firstmate lifts the hold through the normal backlog lifecycle.
- The producer's calm Recurring section of scheduled cadence work (active hold kind `future` with a still-future `--until` date, kept out of the blocked band by `bin/fm-capacity.mjs`) is enriched with each item's real title, schedule reason, and last completed run with its recorded artifact link, plus a Run now button; the click only enqueues a `run-now` command record and firstmate lifts the schedule hold and dispatches through the normal lifecycle.
- A Chat destination gives the captain a phone-ready conversation with the same Firstmate agent over the tailnet, and an approval-ready task with a green GitHub PR gets an exact merge review; both are served-page abilities owned by their sections below, and the offline file carries neither.
- A service bar shows how many captain commands are queued for firstmate.
- Every acknowledgeable action or verdict acknowledges instantly: the served page renders its state straight from the durable command channel, so a pending record renders "Sent to firstmate - in progress", a claimed record renders "Received - being worked" with its claim time, and a claimed click within the last six hours keeps a re-emitted stable action ID rendered as previously approved or denied instead of a bare verdict control.
- Acknowledgment labels remain readable at narrow phone widths by stacking into the prompt's single content column.
- Idea suggestions are deliberately additive and never acknowledge persistently, so sending one cannot disable a later approve or deny verdict.
- A pending or generation-matched claimed action therefore does not look undecided after a reload, and a stable ID re-emitted within the six-hour window stays acknowledged; outside that window it is a genuinely new decision context and renders fresh.
- A Subscription usage band shows cached `quota-axi --json` windows for Claude, Codex, and Grok, including percent used and reset distance with reset time formatted by the captain's browser in local time.
- Every blocked row carries its plain-language blocker chain resolved to the root cause plus an explicit "What you can do" line, so no blocked row leaves the captain guessing; chains stay privacy-safe in the on-disk file and de-anonymize at serve time like every other reference.
- A keyless `needs-decision` status event renders honestly as a worker question that Firstmate is handling in chat, with no fabricated decision identity, `Decide` framing, or dead-end decision detail view.
- The served page has zero copy-prompt affordances: each producer copy button is replaced by direct dispatch, or removed outright in read-only mode, while the offline file keeps its copy buttons for `file://` use.
- The installer pins the installing shell's `PATH` into the launchd agent so the generator's state-reader tools resolve, and the service marks a render `RENDER DEGRADED` loudly on the page and in its log when most worker states read unknown while distinguishing unresolved current-state sources from missing tools - degraded data is never presented as truth or mislabeled as only a PATH problem.
- Work whose current task or endpoint evidence cannot be read stays explicitly unavailable and receives neither authoritative activity detail nor a fabricated progress estimate or ETA.

`bin/fm-capacity.mjs` remains the single owner of the dashboard's content and look; the service injects its interactive layer at serve time and never modifies the file on disk, so the file keeps working offline exactly as before.
The on-disk dashboard stays identity-opaque: the producer's opt-in `--refs` sidecar (`state/dash-refs.json`, `fm-capacity-refs.v1`, mode 0600) carries the opaque-to-real mapping, and only the captain-authenticated service reads it to enrich the served page.

## Components

- `bin/fm-dash-serve.mjs` - the HTTP service, bound to 127.0.0.1 only.
- `bin/fm-dash-install.sh` - launchd agent (`RunAtLoad` + `KeepAlive`, so it survives reboots and crashes), `tailscale serve` mapping, `config/dash.json`, and the registered `fm-dash` watcher check.
- `state/dash-inbox/` - durable captain command records (`fm-dash-command.v1`), one file per clicked action or merge approval.
- `state/dash-chat/` - durable captain chat records: `messages/` (unclaimed `fm-dash-chat-message.v1`), `archive/` (claimed), and `replies/` (the one-per-message `fm-dash-chat-reply.v1` ledger).
- `state/dash-merge/consumed/` - the merge-approval consumption ledger: one nonce-named outcome record per consumed approval, written only by `bin/fm-dash-merge.sh`.
- `state/fm-dash.check.sh` - watcher check registered through `bin/fm-check-register.sh`; prints one line while commands or chat messages are pending so the watcher wakes firstmate.
  Its presence makes the dashboard an armed inbound captain channel under `bin/fm-supervision-lib.sh`, so the home keeps a live supervision cycle and the 30-second check cadence exactly like Telegram and X mode.
- `bin/fm-dash-inbox.sh` - firstmate's list/claim helper; claim prints each record before archiving it under `state/dash-inbox/archive/`, so an interruption may re-surface a command but cannot silently lose one.
- `bin/fm-dash-chat.sh` - firstmate's chat claim/reply helper with the same print-before-archive delivery shape plus a create-only reply ledger, so a message is delivered at least once and answered at most once.
- `bin/fm-dash-pr-evidence.mjs` - the read-only trusted probe that turns a task's recorded GitHub PR into typed merge-review evidence; it never mutates anything.
- `bin/fm-dash-merge.sh` - the only consumer of merge-approval records; it revalidates every binding, claims the one-time nonce, independently rechecks the live PR, and merges exclusively through `bin/fm-pr-merge.sh`.

## Inbound command channel

Button clicks never execute anything.
The design keeps the web process outside every fleet-mutation path:

1. The captain clicks a send or verdict control for a `CAP-NN` action, structured decision answer, idea verdict, parking-lot unpark, recurring run-now request, or needs-you your-go request.
2. The service validates the request (see trust design) and writes one durable `fm-dash-command.v1` record into `state/dash-inbox/` with an atomic temp-file rename, mode 0600.
3. The registered `fm-dash` watcher check notices the pending record on the shared watcher cadence and wakes the running firstmate through the standard durable wake queue.
   [`configuration.md`](configuration.md#watcher-check-cadence-configcheck-cadenceenv) owns that cadence: it defaults to 300 seconds and is 30 seconds while an inbound captain channel is armed.
4. Firstmate claims the records with `bin/fm-dash-inbox.sh claim` and handles each record by its kind under the capacity skill's dashboard-command semantics.
5. Claiming touches `state/dash-inbox/.model-stale`; while auto-render is enabled the service polls that marker and reruns the producer promptly, so the model catches up with handled clicks well before the next full auto-render interval.

Consequences of that shape:

- The service holds no session with firstmate, no terminal access, and no direct merge, dispatch, or teardown capability; compromise of the web process yields at most bogus dashboard command, chat, or approval records, which firstmate still re-resolves through every normal lifecycle authority check - a forged merge approval additionally fails `bin/fm-dash-merge.sh`'s independent live recheck unless the named PR genuinely is the open, green, captain-ready one recorded on the task.
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
- A decision answer must name a decision in the producer's current-generation refs sidecar, and its integer option index must match the structured options available there, parsed directly from the main-home document or projected from the bounded supervisor-home snapshot; a custom answer is accepted only when those structured options are available and is bounded to 2,000 characters.
- Decision answers persist and deduplicate against an owner-qualified home, origin, and key so equal keys from different origins or homes remain independently routable after refs regenerate.
- An idea verdict must name an idea currently listed in `data/ideas/idea-backlog.md` and one of the approve, deny, or suggest verbs; on approval, firstmate creates the work item(s) through the normal backlog lifecycle - the service itself never creates work.
- An unpark request must name an item the currently served dashboard itself lists in its parking lot and resolve through the current-generation refs sidecar; the record only asks firstmate to lift the parked hold through the normal backlog lifecycle, and the service never edits any backlog.
- A run-now request must name an item the currently served dashboard itself lists as recurring and resolve through the current-generation refs sidecar; the record only asks firstmate to lift the schedule hold and dispatch through the normal lifecycle, and the service never edits any backlog or dispatches work itself.
- A your-go request must name an item the currently served dashboard itself lists as awaiting the captain (a `data-your-go-ref` anchor) and resolve through the current-generation refs sidecar, with one of the go, park, or guidance actions; the record only routes the captain's verdict to firstmate for normal-lifecycle re-resolution, a your-go answer for a decision shares that decision's durable acknowledgment identity, and a newer verdict for the same item replaces its pending predecessor under a fresh immutable inbox name.
- A chat message must be bounded, well-formed text (length-capped, malformed Unicode and control characters refused, backpressure past the pending bound) with a valid client idempotency key, and is stored verbatim as data for Firstmate, never interpreted, executed, or rendered as markup.
- A merge preview or approval must name a currently listed approval-ready item that resolves through the current-generation refs sidecar to a main-home task with a canonical GitHub PR; the approval is written only when the server's own fresh forge evidence is eligible and matches what the captain reviewed, and it is consumed only by `bin/fm-dash-merge.sh`.
- The only free text accepted anywhere is bounded captain-authored content: a chat message, idea-suggestion note, decision custom answer, or your-go guidance note authenticated as above and delivered as data for Firstmate, never interpreted or executed by the service.
- A newer approve or deny verdict is published under a fresh immutable inbox name before the unchanged older pending verdict is removed, while suggestions remain additive.
- Destructive, irreversible, and security-sensitive choices stay in trusted channels structurally, with exactly one deliberately engineered exception: a validated exact PR merge approval (its own section below).
  No `CAP-NN` prompt, chat message, decision answer, your-go click, or generic control grants such authority; decision records carry an explicit re-confirm-in-chat boundary for destructive consequences, and firstmate re-resolves every claimed command through the normal lifecycle before acting.
  There is no free-form command field, shell allowlist, generic action executor, or plugin registry, and an inbox record of any unknown sensitive kind is refused and routed to trusted discussion rather than interpreted.

## Captain chat

The authenticated served page carries a Chat destination: a phone-ready conversation with the same firstmate agent, inside the same service, identity checks, and supervision cycle - not a second agent, service, webhook, or watcher.
It exists for the same reason the Telegram channel does - SSH from a phone is miserable - but stays entirely on the tailnet.

- A sent message becomes one bounded `fm-dash-chat-message.v1` record in `state/dash-chat/messages/` (atomic rename, mode 0600), carrying the authenticated captain login and a client idempotency key, so double-taps, retries, and concurrent tabs never create a second record.
- The registered `fm-dash` watcher check counts unclaimed chat messages exactly like pending commands, so delivery rides the same wake path on the 30-second armed-channel cadence; no new poller, daemon, or process exists.
- `bin/fm-dash-chat.sh claim` prints each message before archiving it (at-least-once delivery), and `bin/fm-dash-chat.sh reply <message_id> --text-file <path>` records the answer through a create-only ledger that refuses a second reply, so an interrupted turn can replay delivery without ever double-answering.
- The page renders sent, received, and answered states straight from those directories, keeps a bounded searchable history with load-earlier paging, and prunes only answered messages beyond the configured bound.
- Chat text is captain input for firstmate to read - never shell, a path, script source, or HTML.
  Both sides of the conversation render as text nodes; the only markup ever created from content is a safe `https://` link.
  A chat message carries no authority by itself: instructions re-enter the normal lifecycle, and merge, destructive, irreversible, and security-sensitive asks keep their existing confirmation boundaries.
- The privacy statement shown in the UI is the honest one: traffic between the captain's device and the firstmate machine is protected by Tailscale WireGuard encryption plus HTTPS, including across DERP relays, but this is not end-to-end application encryption - content is plaintext at the two endpoints, and local history is protected by endpoint security and FileVault rather than application-level content encryption.
- Credentials are never solicited or wanted here: the UI warns that passwords, keys, tokens, and recovery codes go to the terminal or keychain, and firstmate never asks for one in chat.
- Long reports, evidence boards, and test output stay behind tailnet-only links rather than being pasted into chat.
- There are no content-bearing push notifications; the conversation is fetched over the tailnet when the captain opens the page.

## Exact PR merge approval

The one deliberately engineered sensitive action: the captain can approve merging one exact, reviewed pull-request version from the dashboard.
Every other destructive, irreversible, or security-sensitive action keeps its trusted-channel boundary, and unknown sensitive action kinds are refused.

The flow keeps the web process outside the merge path end to end:

1. The producer marks a task approval-ready exactly as before; the served page offers "Review merge…" only for such a row whose main-home task records a canonical GitHub PR.
2. Opening the review spawns the read-only `bin/fm-dash-pr-evidence.mjs` probe server-side (never with client-supplied input; the task and URL come from the server-read refs sidecar and task record).
   The confirmation surface shows the full canonical PR URL, repository and PR number, title, base branch, the exact immutable head SHA, merge method, the current check set with each result, recorded risk and validation mode where available, and the approval validity window.
3. A merge control is active only when the fresh evidence shows an open, non-draft, mergeable PR whose current checks are all terminal green - a superset of the required-check set, so it is never weaker than branch protection.
   Draft, red, pending, closed, merged, conflicting, unreadable, unknown-head, or missing-evidence PRs render an honest refusal with no active control.
4. Approval requires a separate explicit confirmation - a review attestation naming the PR number and exact version, then a dedicated approve action - never a generic Go-ahead or a chat message.
5. The service re-probes the forge, requires the client-echoed URL, head SHA, check-set identity, and method to match its own fresh evidence, and writes one typed `kind=merge-approval` record bound immutably to the canonical URL, repository, number, exact head SHA, task identity, merge method, check-set/result identity, captain tailnet login, creation time, short expiry, and a one-time nonce.
   Any change to code, checks, method, task, login, or mergeability between review and consumption invalidates the approval.
6. Firstmate claims the record through the normal inbox and hands it ONLY to `bin/fm-dash-merge.sh`, which revalidates every binding, claims the nonce with a create-only consumption record BEFORE any merge attempt (so replays, concurrent runs, replaced records, and crash-restarts can never merge twice), independently rechecks the live PR through the evidence probe, and merges exclusively through the guarded `bin/fm-pr-merge.sh` owner.
   A consumed, expired, or invalidated approval never regains authority; the captain approves again from a fresh review.

A validated exact dashboard merge approval is the captain's explicit merge word for that one PR version.
Approval never comes from chat prose, a dashboard visit, a generic decision, prior PR approval, or a stale or already-consumed record.

## Decision options document

The home that owns a decision writes `data/<origin>/decisions/<key>.md`, where `<origin>` is the originating work ID and `<key>` is its stable decision key.
The refs sidecar carries `decision/<home>/<origin>/<key>`, preserving the same durable identity even when the key is not a backlog item ID.
For a supervisor-home decision, the bounded home snapshot reads that exact structured record and the producer carries either its parsed detail or its concrete unavailability reason in the private refs sidecar.
The service renders available supervisor-home detail with the same title, context, recommendation markers, options, and approval controls as a main-home decision, with ownership retained only as a small provenance note.
An unreadable or malformed supervisor-home record renders `Decision details unavailable` with its recorded reason and keeps the row's generic Go ahead, Not now, and Send guidance controls.
If a registered home is outside the bounded home reading, any keyed parent-side decision fold remains an explicitly unavailable row instead of disappearing or being presented as read.
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
Legacy decisions without the document keep the generic your-go controls on their needs-you row (option-validated answers still require the document), and their detail view routes the captain to chat for anything beyond those controls.
In v1, the other sanctioned secondmate content read is a bounded read-only excerpt from a resolved `data/<id>/report.md` document return channel.
Secondmate briefs, metadata, status tails, and chat remain prohibited, and everything outside structured decision records and resolved report excerpts shows only the limited ownership note.

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
2026-07-30, macOS 15.6, node v26.5.0: universal needs-you interaction passed - `bash tests/fm-dash.test.sh` and `bash tests/fm-capacity.test.sh` passed end to end; the producer anchored every Approve, Review, and Decide row with `data-your-go-ref`/`data-your-go-kind`; a served fixture with an options-backed decision, a prioritization hold, and a captain-deliverable optionless decision rendered Choose on the first, Go ahead / Not now / Send guidance on the second, and a leading Provide-it control on the third; authorized go, park, and guidance dispatches wrote mode-0600 `your-go` records carrying the hold identity, chosen action, and bounded text, with decision targets carrying `decision_identity`; repeated verdicts coalesced, contradictory verdicts replaced under a fresh inbox name, malformed, unknown-action, empty-guidance, unlisted, and stale references were refused with no inbox write; and a live Chrome check confirmed the rendered controls plus the guidance box prefilled and focused with the deliverable ask.
Same date and environment: supervisor-home decision projection passed through `bash tests/fm-fleet-snapshot-view.test.sh` (16 tests), the capacity refs regression, and the live dashboard-service regression; a structured remote record rendered its title, context, recommendation marker, options, and approval flow, while a concrete unreadable reason and a bounded-out home rendered honest unavailable rows whose generic controls still wrote valid commands, and the main-home detail response stayed unchanged.
2026-07-31, macOS 15.6, node v26.5.0: `bash tests/fm-capacity.test.sh` and `bash tests/fm-dash.test.sh` passed against the four-question brief, canonical work and live-agent projections, active-first person ordering, focused page routing, Ideas-page enrichment, bounded recent-completion wording, 320-390px stacking, and preserved narrow-screen captain controls.
2026-08-01, macOS 15.6, node v26.5.0: `bash tests/fm-capacity.test.sh` and `bash tests/fm-dash.test.sh` passed with self-clearing waits excluded from Brief Stuck but retained on Work and in the manifest, the existing primary recommendation projected through the same stable action path, and a served Chrome DevTools layout probe confirming the row and its action control fit without page overflow at exactly 390px.
2026-08-05, macOS 15.6, node v26.5.0, ShellCheck 0.11.0: captain chat and exact merge approval passed end to end.
`bash tests/fm-dash.test.sh` (32 tests) covered the serve-layer-only chat destination with its honest transport statement and credential warning; identity failing closed on every chat route with no record written; refusal of empty, oversized, malformed-Unicode, control-character, and keyless messages; captain text stored verbatim as data and never appearing in served HTML; client-key idempotency across retries and concurrent tabs; at-least-once claim delivery with at-most-once ledgered replies and sent/received/answered states rendered from the durable records; the wake shim counting commands and chat messages in one line; and read-only mode refusing chat and merge routes.
`bash tests/fm-dash-merge.test.sh` (5 tests) covered the evidence probe's eligibility matrix (draft, red, pending, closed, merged, conflicting, unreadable, non-GitHub, and missing-evidence PRs all refused); preview and approval validating identity, row currency, fresh-evidence echo cross-check, and eligibility before writing one mode-0600 typed record bound to URL, repository, number, exact head, method, check-set identity, captain login, expiry, and nonce; the guarded consumer merging exactly once through the (fake) merge owner with the full refusal matrix - expired, wrong-login, non-GitHub, wrong-PR, symlinked, malformed, and task-mismatched records refused; head or check changes at the independent live recheck invalidating the consumed approval; a crash-claimed nonce and a failed attempt never retrying - and a live headless Chrome preview that sent chat at 390px (markup-bearing text rendered inert, https link safe, no page overflow) and click-approved one exact merge on desktop through review, attestation, and confirmation into the durable record that the real claim path delivered to the guarded consumer exactly once, plus the red-PR refusal rendering with no active control.
`bash tests/fm-check-cadence.test.sh` confirmed the installed writable dashboard is an armed inbound captain channel on the shared 30-second cadence.
No real PR, forge, merge, live dashboard service, tailscale mapping, or launchd state was touched: gh, the evidence probe, and the merge owner were fixture fakes throughout.
