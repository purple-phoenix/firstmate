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

The generated dashboard is a polished, responsive, accessible, self-contained HTML file that works directly from disk.
Do not invoke, depend on, open, poll, share, or embed Lavish for `/capacity`.
Do not expose the dashboard through a local, LAN, Tailscale, public, or third-party service.
The normal invocation may replace only the generated private dashboard and must not write a cache unless the producing script's help explicitly adds and owns one in the future.
Never put secrets, credentials, PHI, production data, or report bodies into the dashboard.

## 2. Interpret capacity safely

Use the model's evidence-backed classifications and do not substitute a utilization percentage.
The model separates grounded ready-work supply, conservative independent starts, active delivery stages, structured waiting gates, persistent scope alignment, configured dispatch lanes, definition health, aging signals, and recent completions.
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
