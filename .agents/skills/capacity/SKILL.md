---
name: capacity
description: >-
  Diagnose meaningful fleet capacity and delivery bottlenecks, then render an offline pipeline dashboard with stable captain action IDs.
  Use when the captain invokes /capacity or asks about capacity, bottlenecks, pipeline utilization, work supply, idle lanes, or maximizing fleet throughput.
user-invocable: true
metadata:
  internal: true
---

# capacity

This skill is the single owner of Firstmate's conditional capacity procedure and captain collaboration loop.
Its goal is maximum meaningful throughput, never artificial utilization.
Firstmate has no fixed ephemeral worker pool or concurrency cap, and an idle persistent secondmate is healthy when no useful unblocked work matches its scope.
One invocation gathers one fresh snapshot, replaces one private dashboard, presents current recommendations, and stops.
It never self-schedules, invents work, or treats a prior dashboard as current truth.

## 1. Gather and render fresh evidence

Run `bin/fm-capacity.mjs --json` exactly once for the invocation and read the returned `fm-capacity.v1` model.
The command gathers a fresh bounded `fm-fleet-snapshot.v1` observation across the main home and every bounded registered secondmate home, classifies capacity, and replaces `data/capacity-dashboard.html` under the effective `FM_HOME`.
Its header and `--help` output are the single owners of the model schema, bounds inherited from the canonical snapshot, environment probes, bottleneck priority, stable action identifiers, output path, and rendering mechanics.
Do not assemble a competing snapshot with ad hoc state reads, GitHub calls, terminal capture, or chat inspection.
Never infer current state from `state/<id>.status`, because it is append-only wake-event history rather than current-state truth.
Do not scrape scout reports, browser review artifacts, or Lavish surfaces to discover decisions.
Structured captain holds and the keyed open-decision fold are the only decision inputs.
Decision filing and its structured options document are owned by the decision-hold lifecycle.

The generated dashboard is a polished, responsive, accessible, self-contained HTML file that works directly from disk.
Do not invoke, depend on, open, poll, share, or embed Lavish for `/capacity`.
Do not expose the dashboard through any local, LAN, public, or third-party service; the sole sanctioned exposure is the tailnet-only dashboard service in section 6, and even that surface is never Funnel and never public.
The normal invocation may replace only the generated private dashboard and the producer-owned private wait-history cache documented by `bin/fm-capacity.mjs --help`.
Never put secrets, credentials, PHI, production data, or report bodies into the dashboard.

## 2. Interpret capacity safely

Use the model's evidence-backed classifications and do not substitute a utilization percentage.
The model separates grounded ready-work supply, conservative independent starts, active delivery stages, structured waiting gates, persistent scope alignment, configured dispatch lanes, definition health, aging signals, and recent completions.
Captain-parked work (an active structured hold with kind `parked`) is deliberately dormant rather than stuck: the model keeps it in the separate `parked` collection, out of the blocked band, blocked counts, attention summaries, and wait treatments, and the dashboard shows it only in a collapsed parking-lot section that disappears when empty.
Scheduled recurring work (an active structured hold with kind `future` and a still-future `--until` date) is healthy cadence work rather than stuck or dormant work: the model keeps it in the separate `recurring` collection with its next-run date and last-completed-run linkage, out of the blocked band and counts the same way, and the dashboard shows it in one calm Recurring section that disappears when empty; `bin/fm-capacity.mjs --help` owns the honest recurrence key and its expiry semantics.
Treat a main-home item as independently startable only when the model places it in `pipeline.ready` after its definition, dependency, and conservative coarse-overlap checks.
Treat an idle secondmate as an opportunity only when its validated structured home already contains grounded ready work in its own scope.
Treat every other idle secondmate as healthy rather than proposing busywork.
Natural-language secondmate scope remains a judgment boundary, so never route main-home work by guessing from project membership alone.
Configured harness and backend availability are observable, while quota is not observed by this skill and must never be guessed.
Age is a review signal rather than proof of a stall, and recovery still requires authoritative current-state evidence.

Keep these bottleneck classes distinct when summarizing the model:

- Demand shortage means no grounded useful outcome is ready, so adding agents cannot improve meaningful throughput.
- Definition shortage means nominal backlog items lack sufficient scope, acceptance criteria, project resolution, deliverable kind, or dependency definition.
- Overlap serialization means otherwise useful work is held by an explicit dependency or a conservative coarse subsystem boundary.
- Captain-held work means a structured decision, approval, or credential requires the captain.
- Validation, CI, or approval means delivery value is waiting in the finishing stages rather than in implementation supply.
- Lane mismatch means grounded work exists but a configured runtime, authenticated delivery path, harness lane, or already-matched persistent scope cannot currently carry it.
- Execution shortage means grounded independent work exists and normal dispatch is available, not that an arbitrary worker count is below a target.
- Unavailable state means the evidence is insufficient for a safe capacity claim and must be reconciled before apparent idle is trusted.

Never weaken dependency, overlap, approval, project-write, security, merge, validation, or teardown rules to improve a capacity measure.
Never recommend dispatch merely to raise utilization.

## 3. Present the current result

Give the captain a concise chat summary with the generated timestamp, dashboard path, five top-level measures, primary bottleneck, and the highest-priority recommendations by stable action ID.
Name useful ready supply, active independent work, waiting work, open captain actions, and recently landed count.
For each surfaced action, preserve the model's triggering evidence, expected throughput consequence, safety and authority boundary, and recommended next action without copying the entire dashboard into chat.
Explicitly say when no action is warranted and healthy idle is the correct state.
Link the local dashboard path for the full pipeline, lane, definition-health, evidence, landed-artifact, and copyable-prompt detail.

## 4. Collaborate through stable action IDs

The captain may approve, reject, combine, reprioritize, or discuss one or more `CAP-NN` action IDs in ordinary chat.
Treat an action ID as a discussion handle for the evidence in the latest model, never as executable dashboard authority.
Dashboard JavaScript may copy its plain-language prompt but must never mutate fleet state or call Firstmate tooling.

Before acting on an approved ID, resolve the referenced current facts again through the normal lifecycle that owns the action.
Project work re-enters project resolution, diagnostic classification when applicable, backlog definition, overlap and dependency checks, dispatch-profile selection, approval, supervision, validation, merge authority, and teardown safety.
Captain decisions re-enter `decision-hold-lifecycle`, credentials re-enter bootstrap diagnostics, and unavailable workers re-enter the appropriate recovery procedure.
An approval of a capacity recommendation does not itself authorize a PR merge, a `local-only` landing, destructive action, security-sensitive action, project write by Firstmate, or discard of unlanded work.

When the captain asks for a follow-up capacity view, run the producer again and replace the dashboard from a fresh snapshot.
Do not compare against, incrementally patch, or rely on the prior dashboard as current state.

## 5. Preserve supervision

The normal `/capacity` invocation is read-mostly and must not dispatch, merge, tear down, mutate task state, edit the backlog, register decisions, or create speculative work as a side effect.
If the fresh result reveals an action, report its stable ID and wait for or discuss the captain's ordinary chat direction.
Continue the already-required live supervision cycle after presenting the result whenever fleet work or X mode is under way.

## 6. Dashboard command service

The optional persistent dashboard service (`bin/fm-dash-serve.mjs`, installed by `bin/fm-dash-install.sh`, designed in `docs/dashboard-service.md`) publishes the generated dashboard tailnet-only, never Funnel, and layers the captain-authenticated interactions documented by that design onto the offline artifact.
The service never executes fleet commands: a click only writes a durable command record into `state/dash-inbox/`, and the registered `fm-dash` watcher check wakes Firstmate while records are pending.
Its refresh button reruns the producer server-side and is equivalent to a fresh normal invocation, so it needs no Firstmate action.

On a `check:` wake naming `fm-dash.check.sh`, run `bin/fm-dash-inbox.sh claim` and handle each claimed record by its kind:
Claim delivery is at-least-once across interruption, so check whether a re-surfaced record was already handled before applying it again.

- A `CAP-NN` record is the captain's ordinary chat approval of that action ID under section 4, including its full re-resolution and authority limits.
- A `decision` record is the captain's answer for the owner-qualified decision identity with either the recorded option text or bounded custom answer; route `decision_origin` in `decision_home` through `decision-hold-lifecycle` exactly as a chat answer, and re-confirm in chat before acting when the answer has a destructive or irreversible consequence.
- An `idea` record is the captain's verdict on the named `data/ideas/` idea: on approve, create the follow-up work item(s) through the normal backlog lifecycle; on deny, record the outcome against the idea; on suggest, treat the suggestion text as captain input on that idea.
- An `unpark` record is the captain's request to return the named parked work item to the active queue: lift its parked hold in the owning home through the normal backlog lifecycle (for a `tasks-axi` backend, `tasks-axi unhold <id>`), then re-evaluate the queue; the lift grants no dispatch authority beyond normal re-evaluation, and work owned by a secondmate is routed to that home rather than edited from the main home.
- A `run-now` record is the captain's request to run the named scheduled recurring work item early instead of waiting for its next-run date: lift its schedule hold in the owning home through the normal backlog lifecycle (for a `tasks-axi` backend, `tasks-axi unhold <id>`), then re-evaluate and dispatch through the normal lifecycle; it authorizes one early run only, grants no authority beyond normal dispatch checks, and work owned by a secondmate is routed to that home rather than edited from the main home.

A claimed record never authorizes a PR merge, `local-only` landing, destructive action, irreversible action, security-sensitive action, or discard of unlanded work; when a claimed action leads to such a choice, escalate it to captain chat exactly as section 4 requires.
Report the outcome of handled commands to the captain through normal escalation etiquette rather than assuming the dashboard told them.
While the service is installed and registered, treat pending dashboard commands like X-mode mentions for supervision: keep the live supervision cycle running even with no other fleet work so a click can wake Firstmate.
