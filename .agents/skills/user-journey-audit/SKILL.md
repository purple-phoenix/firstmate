---
name: user-journey-audit
description: >-
  Run an evidence-backed browser audit of one application with a bounded persona set derived from observable product surfaces, automatically implement confirmed ordinary reversible bugs, and queue grounded feature opportunities without implementing them.
  Use when the captain invokes /user-journey-audit or explicitly asks Firstmate for a user-journey audit of an application.
user-invocable: true
metadata:
  internal: true
---

# user-journey-audit

This skill is the single owner of Firstmate's user-journey audit procedure.
One invocation audits one explicitly resolved application or project, then stops.
It never schedules, repeats, or initiates an audit without a new captain invocation.

The audit is an evidence-producing scout whose confirmed ordinary reversible defects carry narrow implementation authority from the invocation itself.
That authority covers implementation through the project's configured delivery path, but it never grants merge authority.
Grounded feature opportunities are backlog inputs only and are never implementation-authorized by this skill.

## 1. Resolve exactly one target

Resolve the project through `AGENTS.md` section 7 before creating any work.
An explicit project wins, and a clear follow-up inherits its referent.
Otherwise match the request against the project registry, work under way, and user-facing project documentation.
Proceed only when exactly one target is confidently resolved, name it to the captain, and ask one concise question when multiple or no projects plausibly match.
Never combine applications, repositories, deployments, or unrelated product surfaces in one invocation.

Resolve the fitting secondmate scope before using the main home.
Keep `local-only` work in the main home.
The home that owns the audit also owns its report, evidence, decision records, and backlog follow-ups.

## 2. Establish the safe audit environment

Audit a safe isolated local instance by default.
Use only synthetic accounts and disposable data.
Never browse or mutate production, use production credentials, call paid APIs, create external records, send messages, publish content, or perform any other external mutation unless the captain explicitly authorizes that exact scope for this invocation.
Even with production authorization, escalate destructive, irreversible, security-sensitive, privacy-sensitive, billing, or production-impacting actions and fixes instead of taking them automatically.

Drive the application with `chrome-devtools-axi`.
Read its current help before use and keep the browser headless by default.
Headed or visible browsing requires explicit captain authorization.
Do not substitute another browser driver merely because it is convenient.

Read only the project's `README.md`, `AGENTS.md`, and documented operator commands needed to start, seed, reset, and locate the isolated instance before the first behavioral pass.
Do not inspect implementation source, tests, route definitions, fixtures, or product plans to script expected journeys before that pass.
If the application cannot run locally and no safer already-authorized test environment exists, report the blocker and stop rather than falling through to production.

## 3. Dispatch one audit scout

Load `harness-adapters`, resolve the configured dispatch profile, scaffold one scout brief with `bin/fm-brief.sh <id> <repo> --scout`, and spawn it through the normal lifecycle.
The brief must carry the resolved target, authorized environment, all safety boundaries in this skill, the behavioral method below, and the durable artifact paths.
Do not split persona exploration into multiple scouts because one evidence set and one cross-persona synthesis are the audit deliverable.

The scout may create scratch-only launch adapters, seed data, accessibility probes, or capture helpers inside its isolated worktree.
Scratch helpers never become project changes, never receive production credentials, and never survive by accident.
If a reusable project helper or Firstmate mechanism is genuinely required, record that need and route it as ordinary ship work with tests and the configured validation path.
Never silently install or commit a durable helper from the audit.

## 4. Preserve the fresh-user pass

Begin with one clean browser profile and only the information visible to a person arriving at the product.
Record the first-contact page, apparent product promise, visible calls to action, terminology, navigation, help, empty states, and the first meaningful task attempted.
Follow plausible cues without using source-derived knowledge of hidden routes or expected flows.
Record wrong turns and ambiguity rather than correcting them from implementation knowledge.

This pass is evidence, not a permanent persona definition.
It preserves a genuinely fresh perspective before persona synthesis or source-led diagnosis can bias the journey.

## 5. Build a bounded dynamic persona set

After the fresh-user pass, derive two to four personas from the product surfaces actually observed, the roles or contexts those surfaces imply, and the journeys encountered.
Use two personas for a narrow single-purpose product and add a third or fourth only when a materially different role, experience level, constraint, or returning-state need is evidenced.
Do not use a permanently fixed new-user and returning-user pair.
Include fresh-user and returning-user perspectives when the observable product supports both, but let the product determine their concrete goals and contexts.

For every persona, record:

- Goal.
- Context of use.
- Prior experience with the product or domain.
- Constraints that materially affect the journey.
- Observable success criteria.
- The product evidence that justified including the persona.

Choose diversity along dimensions that can change behavior in this application, such as experience, device, permissions, time pressure, assistive-technology needs, connectivity, or collaboration role.
Do not invent demographic traits that have no evidenced bearing on the journey.
Keep accounts, cookies, local storage, seed state, and browser profiles isolated whenever personas require different histories or permissions.

Write the synthesis to `data/<id>/personas.md` before running the full matrix.
If exploration later reveals a materially missing perspective, replace or add one persona within the four-person cap and record why the set changed.

## 6. Exercise realistic browser journeys

Translate each persona's goals and success criteria into the smallest realistic journey set supported by the observable product.
Exercise each journey end to end through the browser rather than treating page presence as success.
Cover these path types when the product exposes them:

- A primary success path that reaches the product's observable value.
- Navigation and findability across the relevant surfaces.
- Input validation with realistic invalid, incomplete, and boundary values.
- Recovery from mistakes, interruptions, expired state, or dead ends.
- Accessibility-relevant keyboard, focus, labeling, semantics, zoom, and responsive behavior.
- Returning-user continuation with established disposable state.
- Settings, permissions, sharing, import, or export only when they remain local and non-mutating outside the authorized environment.

Do not force an unsupported path merely to fill a checklist.
Record the observable reason when a path type does not apply.
Use desktop and mobile-sized viewports when responsive behavior is part of the observable product.

Keep chronological notes in `data/<id>/audit-notes.md`.
For each attempt, record the persona, goal, starting state, steps, outcome, elapsed effort where useful, recovery behavior, and evidence identifiers.

## 7. Capture durable evidence safely

Store screenshots, console excerpts, network summaries, accessibility observations, and other supporting artifacts under `data/<id>/evidence/`.
Use privacy-safe stable filenames that link each artifact to a report finding.
For every material finding, retain the page URL or route, the shortest reliable reproduction from a clean disposable state, expected and observed behavior, repeatability, and the relevant artifacts.

Never capture passwords, tokens, cookies, API keys, production data, real personal identifiers, or unrelated screen content.
Use synthetic values and redact sensitive material before it enters a durable artifact.
Keep large raw captures bounded and prefer the smallest evidence that proves the observation.

After the first behavioral pass, load `diagnostic-reasoning` before investigating a possible defect.
Source inspection is permitted only then and only to reproduce, disconfirm, or explain a specific observed failure.
Separate confirmed behavior, hypotheses, and unresolved uncertainty.

## 8. Classify the report

Write a self-contained report at `data/<id>/report.md`.
The report must explain the environment, fresh-user pass, persona derivation, journey coverage, findings, evidence, limitations, and recommended next actions without requiring terminal history or chat context.

Keep these classes separate:

- Confirmed defects are observable violations with reliable reproduction and a defensible expected behavior.
- UX friction is behavior that works but imposes avoidable confusion, effort, accessibility cost, or recovery cost.
- Feature opportunities are additions grounded in a journey need rather than missing correctness.
- Unresolved uncertainties are observations whose cause, expected behavior, safety, or repeatability is not established.

For each item, include a stable finding key, priority, affected personas, impact, confidence, reproduction or journey moment, evidence pointers, and testable acceptance criteria.
For feature opportunities, also name the user goal and journey evidence that justify the idea.
Do not convert uncertainty or subjective preference into a defect.
Do not brainstorm features that no observed journey motivated.

Render the report as an HTML review surface under `data/<id>/evidence/` and open it with `lavish-axi` when available.
Keep the Markdown report authoritative and complete even when the visual surface is used.

## 9. Complete decisions before routing work

Load `decision-hold-lifecycle` before treating the report or visual review as complete.
Inventory genuine captain product decisions and register each one in the authoritative home before the scout reports done.
An ordinary confirmed defect with no sensitive or product-choice boundary is not a captain decision merely because it will be fixed automatically.
A feature opportunity that depends on product positioning, policy, destructive behavior, privacy, billing, or another captain choice must receive a decision record.

The scout reports done only after the report, structured notes, evidence, and decision inventory are complete.
Do not tear it down yet when an eligible defect may be promoted.

## 10. Select automatic bug-fix work

Treat the invocation as implementation authorization only for confirmed defects that are ordinary, reversible, locally reproducible, and bounded to a safe project change.
Exclude destructive, irreversible, security-sensitive, privacy-sensitive, billing, migration, external-data, production-impacting, or materially ambiguous fixes.
Escalate excluded findings and leave unresolved findings as uncertainties.

Before creating or promoting work, inspect the authoritative backlog and live task records for the same project, reproduction, subsystem, or intended outcome.
If equivalent work already exists, add the report and evidence pointers to that item instead of creating a duplicate.

Partition the remaining eligible defects by one shared causal boundary and one coherent regression-test surface.
Never bundle defects merely because the same audit found them.
Order groups by impact, then repeatability, then number of affected personas, then report order.

Promote the existing scout in place with `bin/fm-promote.sh` for the first eligible non-duplicate group.
Do not create a new task for that group.
The promoted worker must inventory scratch state, return to a clean current default-branch base, carry over no audit edits or helpers, create the required ship branch, reproduce the bug, add regression coverage, and implement only that fix group.
The report and evidence remain outside the worktree as the durable source.

Create one separate ordinary ship item for each additional eligible non-duplicate group.
Give each item the report and finding keys, evidence pointers, regression expectation, configured delivery path, and dependency on the promoted group when their code boundaries overlap.
Dispatch independent groups normally and queue overlapping groups until their dependency lands.
This deterministic partition is the only automatic bundling policy.

All fixes follow the existing project lifecycle, selected delivery path, supervision, validation, approval, landing, and teardown rules.
Automatic implementation authority does not permit a PR merge or a `local-only` landing without the authority already configured for that project.
Never auto-merge.

## 11. Queue grounded feature opportunities

Add every evidence-backed non-duplicate feature opportunity to the authoritative backlog as queued work once any required product decision is resolved.
Include its stable finding key, user goal, affected personas, report path, evidence pointers, and acceptance criteria.
Do not implement, dispatch, or promote feature work from this invocation.

If a feature depends on a captain product decision, follow `decision-hold-lifecycle`: register the decision before the audit completes, then create the dependent queued feature only after the captain answers and route the answer through the required resolve sequence.
If equivalent feature work already exists, update that item with the new evidence instead of creating another.
UX friction that requires a new capability belongs with feature opportunities, while ordinary corrective behavior may enter the defect-selection procedure.

## 12. Present and finish

Give the captain a concise review summary naming the resolved application, persona set, journey coverage, top defects, top friction, queued feature opportunities, unresolved uncertainties, automatic fix work now under way or queued, and the report path.
State explicitly that fixes are implementation-authorized but not merge-authorized.
Use the rendered review surface for detail rather than copying the full report into chat.

If no eligible defect is promoted, tear down the completed scout after the decision completion gate passes.
If the scout is promoted, retain it through the ship lifecycle and tear it down only after its work lands.
Do not schedule another audit.
