#!/usr/bin/env node
/**
 * fm-capacity.mjs - deterministic fleet-capacity classifier and dashboard renderer.
 *
 * This file is the single owner of the fm-capacity.v1 model, bottleneck priority,
 * stable CAP action identifiers, environment-lane probes, and HTML mechanics.
 * It delegates current fleet truth to bin/fm-fleet-snapshot.sh and never parses
 * status tails, terminal chat, scout report bodies, or visual artifacts.
 *
 * Default invocation gathers a fresh canonical snapshot, replaces only
 * data/capacity-dashboard.html under the effective FM_HOME, and prints a compact
 * text summary. --json prints the complete model while still writing the dashboard.
 * --snapshot and --environment accept deterministic JSON fixtures for tests and
 * offline review; snapshot PR reads come from its pr_reconciliation result map,
 * and normal /capacity runs must not use either fixture input.
 *
 * fm-capacity.v1 fields:
 *   generated, dashboard_path, provenance, measures, primary_bottleneck,
 *   pipeline, parked, recurring, live_agents, lanes, readiness, aging,
 *   recommendations, and omissions.
 * Pipeline stages are queued, ready, building, validating_fixing,
 * pr_ci_approval, blocked, and recently_landed.
 * Blocked and self-clearing cards carry a wait treatment (wait.class, copy,
 * and honest progress); bin/fm-wait-progress.mjs owns the estimator math and
 * the private rolling observed-duration record it feeds from.
 * Items whose active hold has kind=parked are deliberately dormant: they land
 * in the separate parked collection, stay out of every pipeline stage, count,
 * attention summary, and wait treatment, and render only in a collapsed
 * parking-lot section that disappears entirely when empty.
 * Items whose active hold is a date-gated schedule (kind=future with a future
 * --until date) are scheduled cadence work, not stuck work: they land in the
 * separate recurring collection with next_run and full-history last-run linkage,
 * stay out of the blocked band and counts the same way, and render in one calm
 * Recurring section that disappears entirely when empty. A hold whose --until
 * date has arrived is inactive (tasks-axi semantics), so the item re-enters
 * normal readiness classification.
 * Run --help for the exact inherited snapshot bounds, environment-probe budget,
 * bottleneck order, CAP-01 through CAP-10 meanings, wait-progress honesty
 * rules, and output replacement rules.
 *
 * The producer is read-mostly. It writes only the selected dashboard path,
 * the data/capacity-wait-history.json observed-duration record it owns for
 * honest wait-progress estimates, plus the opt-in --refs identity sidecar it
 * owns for the authenticated dashboard service, and never dispatches, merges,
 * tears down, changes backlog/task state, or opens a service. Inline dashboard
 * JavaScript copies prompts only and cannot run actions.
 * Live environment probes share one 30-second fleet-wide deadline and preserve
 * unavailable evidence for homes that cannot be inspected within that bound.
 */

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadWaitHistory, observeWaits, estimateWait, deadlineWait, progressLabel } from "./fm-wait-progress.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const HOME_PROBE_BUDGET_MS = 30000;
const PR_PROBE_BUDGET_MS = 15000;
const PR_PROBE_TIMEOUT_MS = 5000;
const PR_PROBE_MAX = 12;
const VERIFIED_HARNESSES = new Set(["claude", "codex", "opencode", "pi", "grok"]);
const STAGES = [
  "queued",
  "ready",
  "building",
  "validating_fixing",
  "pr_ci_approval",
  "blocked",
  "recently_landed",
];
const STAGE_LABELS = {
  queued: "Queued",
  ready: "Ready",
  building: "Building",
  validating_fixing: "Validating / fixing",
  pr_ci_approval: "PR / CI / approval",
  blocked: "Blocked",
  recently_landed: "Recently landed",
};

function usage(exitCode = 0) {
  const out = exitCode === 0 ? process.stdout : process.stderr;
  out.write(`usage: fm-capacity.mjs [--json] [--output <path>] [--snapshot <json>] [--environment <json>] [--refs <path>]

Gather a fresh bounded fleet snapshot, classify meaningful capacity, and atomically
replace a self-contained offline dashboard. The default destination is
data/capacity-dashboard.html under the effective FM_HOME. The destination must stay
inside the canonical data root, may traverse legitimate system symlink ancestors,
must not traverse a symlink below FM_HOME or replace a symlink leaf, and is mode 0600.
--json prints the complete model after writing the dashboard. --snapshot and
--environment are deterministic fixture inputs for tests/offline review and must not
be used for a normal /capacity run. A snapshot fixture's optional pr_reconciliation
object maps owner/repo#number to deterministic gh-axi-shaped exit_status, stdout,
and stderr fields; missing entries stay unavailable and never trigger live reads.

--refs additionally writes the fm-capacity-refs.v1 sidecar this producer owns: the
private mode-0600 mapping from every opaque dashboard reference (item-NN, project-NN,
home-NN) to its real identity, plus bounded structured detail or a concrete
unavailability reason for supervisor-home decisions. The dashboard itself stays
identity-opaque; the sidecar exists so the captain-authenticated tailnet dashboard
service (bin/fm-dash-serve.mjs) can enrich the page and serve rich detail views
without weakening the offline file.
The sidecar path must stay inside the effective state or data directory.

MODEL fm-capacity.v1
  generated, dashboard_path, provenance, measures, primary_bottleneck, pipeline,
  parked, recurring, live_agents, lanes, readiness, aging, recommendations,
  omissions. live_agents owns the generated time and a bounded worker/supervisor
  roll call sourced from the same current-state snapshot. Pipeline owns queued,
  ready, building, validating_fixing, pr_ci_approval, blocked, and recently_landed
  arrays. Each recommendation owns id, classification, priority, evidence,
  expected_throughput_consequence, safety_authority_boundary,
  recommended_next_action, and prompt.

PARKING LOT
  A backlog item whose active structured hold has kind=parked is captain-parked:
  deliberately dormant, not stuck. It is classified into the top-level parked
  array instead of the blocked stage and is excluded from blocked counts,
  waiting measures, attention summaries, aging, and wait/blocker treatments.
  Park reasons are withheld from this privacy-bounded artifact like every other
  hold reason; the authenticated dashboard service enriches them. The dashboard
  renders parked items only inside one collapsed low-key parking-lot section at
  the bottom, and renders no parking-lot section at all when nothing is parked.
  Holds that match neither the parking nor recurring keys keep their normal
  treatment.

RECURRING
  The backlog schema has no first-class recurrence marker, so the honest v1
  recurrence key is a date-gated schedule hold: an active structured hold with
  kind=future and an explicit --until date still in the future
  ("(hold-kind: future) (hold-until: YYYY-MM-DD)"). Such an item is scheduled
  cadence work - healthy and on schedule, not stuck. It is classified into the
  top-level recurring array instead of the blocked stage and is excluded from
  blocked counts, waiting measures, attention summaries, aging, and wait
  treatments. Each entry carries next_run (the gate date), scheduled_since,
  and last_run: the most recent same-home Done record whose id shares the
  item's cadence stem (the id after removing exactly one trailing counter or
  date token, e.g. research-w4 matches done research-w3), with its completion
  date, an opaque ref, and whether a delivered artifact is on the books.
  Schedule hold reasons are withheld from this privacy-bounded artifact like
  every other hold reason. The dashboard renders one calm bottom Recurring
  section with a "next: <date>" chip per item, renders no section at all when
  nothing recurs, and leaves enrichment plus the RUN NOW control to the
  authenticated dashboard service. Any hold whose --until date has arrived is
  inactive (tasks-axi date-gate semantics), so the item re-enters normal
  readiness classification instead of staying recurring or blocked, and a
  future-dated hold that also has an explicit dependency keeps the blocked
  treatment so its blocker chain stays visible.

BOUNDS AND PROBES
  The canonical fm-fleet-snapshot.v1 producer owns snapshot completion; this wrapper
  does not impose a shorter aggregate timeout. Its normal defaults inspect at most 20
  secondmate homes sequentially, request each included home's complete landed record
  for recurring-history lookup, bound each structured-home read to 8 seconds and
  262144 bytes, and emit explicit per-home unavailable/truncated evidence instead of
  aborting the fleet result. A complete landed record that exceeds the time or byte
  bound makes that home unavailable rather than silently shortening history.
  FM_SNAPSHOT_SECONDMATES,
  FM_SNAPSHOT_SECONDMATE_TIMEOUT, and FM_SNAPSHOT_SECONDMATE_MAX_BYTES are the
  canonical overrides; fm-fleet-snapshot.sh --help owns its remaining exact bounds.
  Backend, bootstrap credential, and dispatch probes share one 30-second fleet-wide
  deadline. Per-home steps are capped at 5, 15, and 3 seconds respectively, reduced
  by remaining aggregate time; unvisited or incomplete homes become unavailable.
  Current GitHub delivery gates are reconciled through gh-axi before rendering.
  At most 12 unique pull requests are read, each read is capped at 5 seconds, and
  all reads share a 15-second deadline. A failed, malformed, or skipped read stays
  visibly unavailable instead of being presented as verified current state.

WAIT TREATMENT AND PROGRESS
  Every blocked card carries wait.class: "self_clearing" for a wait expected to
  clear with no actor (its own test suite or validation, CI checks, a declared
  external delay, or a future time gate), or "needs_actor", where the blocker
  chain and what-you-can-do line stay authoritative. Working validation and CI
  cards carry the same self-clearing treatment. A declared pause whose recorded
  evidence shows the wait is on the captain (a pause reason naming the captain
  or addressing them directly, or an open PR plus a merge/review/approval-shaped
  reason) is a captain gate: it classifies as needs_actor with captain_gate=true,
  renders in the needs-you band with a what-you-can-do line, and never gets a
  progress bar or ETA, because a human decision has no duration model. A PR wait
  is claimed only when an open PR is honestly evidenced (recorded pr= plus no
  merged signal, or equivalent positive open evidence such as the pause reason
  affirmatively saying the pull request is open or awaiting review/merge); a stale pr= from an already-merged delivery
  never invents "open pull request" copy - the pause's own declared reason is
  the wait description instead. A queued hold with hold-kind=captain (including
  ship/scout prioritization holds, not only kind=captain decision rows) is the
  same needs-your-go treatment rather than a stuck structured hold. Self-clearing
  waits carry plain-language copy
  and, where measurable, wait.progress with basis "history" (elapsed vs the
  recorded typical duration), "deadline" (exact time-gate math), or "none".
  Percent and remaining-time estimates are reserved for measurable machine
  waits (validation and CI); an ambiguous declared external delay shows elapsed
  time and "time unknown" rather than a figure borrowed from unrelated past
  waits. Progress never fabricates precision: with no recorded history it shows
  elapsed time and "time unknown", an exceeded estimate shows "running longer
  than usual" instead of a frozen percentage, and history-based figures are
  labeled as estimates from past runs. bin/fm-wait-progress.mjs owns the
  estimator and the fm-capacity-wait-history.v1 schema of
  data/capacity-wait-history.json, the private (mode 0600, gitignored)
  rolling observed-duration record this producer reads and replaces on every
  run alongside the dashboard.

BOTTLENECK ORDER AND STABLE ACTIONS
  Lower numeric priority wins; ties sort by stable ID:
   10 CAP-02 credentials             20 CAP-03 unavailable state
   25 CAP-09 lane mismatch           30 CAP-01 captain-held decisions
   35 CAP-10 aging flow              40 CAP-07 validation, CI, or approval
   50 CAP-05 dependencies/overlap    60 CAP-04 definition shortage
   70 CAP-06 execution shortage      80 CAP-08 demand shortage
  CAP IDs are discussion handles only. Their copyable prompts re-enter normal
  Firstmate lifecycles; neither the model nor dashboard executes an action.
`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const opts = { json: false, output: null, snapshot: null, environment: null, refs: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") opts.json = true;
    else if (arg === "--output") opts.output = argv[++i];
    else if (arg.startsWith("--output=")) opts.output = arg.slice(9);
    else if (arg === "--snapshot") opts.snapshot = argv[++i];
    else if (arg.startsWith("--snapshot=")) opts.snapshot = arg.slice(11);
    else if (arg === "--environment") opts.environment = argv[++i];
    else if (arg.startsWith("--environment=")) opts.environment = arg.slice(14);
    else if (arg === "--refs") opts.refs = argv[++i];
    else if (arg.startsWith("--refs=")) opts.refs = arg.slice(7);
    else if (arg === "-h" || arg === "--help") usage(0);
    else usage(2);
    if ((arg === "--output" || arg === "--snapshot" || arg === "--environment" || arg === "--refs") && !argv[i]) usage(2);
  }
  return opts;
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`${label} is not readable JSON: ${error.message}`);
  }
}

function run(command, args, options = {}) {
  const spawnOptions = {
    encoding: "utf8",
    env: options.env ?? process.env,
    maxBuffer: options.maxBuffer ?? 4 * 1024 * 1024,
  };
  if (options.timeout !== null) spawnOptions.timeout = options.timeout ?? 12000;
  return spawnSync(command, args, spawnOptions);
}

function gatherSnapshot(file) {
  if (file) return readJson(file, "snapshot fixture");
  const result = run(path.join(SCRIPT_DIR, "fm-fleet-snapshot.sh"), ["--json"], {
    timeout: null,
    env: { ...process.env, FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME: "0" },
  });
  if (result.status !== 0) {
    throw new Error(`fresh fleet snapshot failed: ${(result.stderr || result.stdout || "unknown error").trim()}`);
  }
  return JSON.parse(result.stdout);
}

function githubPullRequest(url) {
  const match = String(url || "").match(/^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/([1-9][0-9]*)\/?$/);
  return match ? { repo: `${match[1]}/${match[2]}`, number: match[3] } : null;
}

function pullRequestState(output) {
  const state = String(output || "").match(/^\s*state:\s*(open|closed|merged)\s*$/im)?.[1]?.toLowerCase();
  return state || null;
}

function pullRequestReconciliation(result) {
  const state = result.status === 0 ? pullRequestState(result.stdout) : null;
  return state
    ? { status: state, reason: null }
    : {
        status: "unavailable",
        reason: result.error?.code === "ETIMEDOUT"
          ? "pull request lookup timed out"
          : result.status === 0
            ? "pull request lookup returned an unrecognized state"
            : "pull request lookup failed",
      };
}

function reconcilePullRequests(snapshot, fixture = null) {
  const candidates = new Map();
  for (const task of snapshot.tasks || []) {
    if (task.kind === "secondmate") continue;
    const coordinates = githubPullRequest(task.pr?.url);
    if (!coordinates) continue;
    const key = `${coordinates.repo}#${coordinates.number}`;
    if (!candidates.has(key)) candidates.set(key, { ...coordinates, tasks: [] });
    candidates.get(key).tasks.push(task);
  }
  const deadline = Date.now() + PR_PROBE_BUDGET_MS;
  let readCount = 0;
  for (const candidate of [...candidates.values()].sort((a, b) =>
    `${a.repo}#${a.number}`.localeCompare(`${b.repo}#${b.number}`)
  )) {
    let reconciliation;
    const key = `${candidate.repo}#${candidate.number}`;
    if (fixture !== null) {
      const result = fixture[key];
      reconciliation = result && Number.isInteger(result.exit_status)
        ? pullRequestReconciliation({
            status: result.exit_status,
            stdout: String(result.stdout || ""),
            stderr: String(result.stderr || ""),
          })
        : { status: "unavailable", reason: "pull request reconciliation fixture missing" };
    } else if (readCount >= PR_PROBE_MAX) {
      reconciliation = { status: "unavailable", reason: "pull request lookup limit reached" };
    } else if (Date.now() >= deadline) {
      reconciliation = { status: "unavailable", reason: "pull request lookup deadline exhausted" };
    } else {
      readCount += 1;
      const result = run("gh-axi", ["pr", "view", candidate.number, "-R", candidate.repo, "--full"], {
        timeout: Math.max(1, Math.min(PR_PROBE_TIMEOUT_MS, deadline - Date.now())),
        maxBuffer: 512 * 1024,
      });
      reconciliation = pullRequestReconciliation(result);
    }
    for (const task of candidate.tasks) {
      task.pr = { ...task.pr, reconciliation };
    }
  }
}

function executableOnPath(name) {
  if (!name || name.includes("/") || !VERIFIED_HARNESSES.has(name)) return false;
  for (const directory of (process.env.PATH || "").split(path.delimiter)) {
    if (!directory) continue;
    try {
      fs.accessSync(path.join(directory, name), fs.constants.X_OK);
      return true;
    } catch {
      // Continue through PATH.
    }
  }
  return false;
}

function configuredDispatch(configDir, fmHome, timeout = 3000) {
  const dispatchPath = path.join(configDir, "crew-dispatch.json");
  const lanes = [];
  let configPresent = false;
  let valid = true;
  let reason = null;
  if (fs.existsSync(dispatchPath)) {
    configPresent = true;
    try {
      const config = JSON.parse(fs.readFileSync(dispatchPath, "utf8"));
      const profiles = [];
      for (const rule of Array.isArray(config.rules) ? config.rules : []) {
        const uses = Array.isArray(rule.use) ? rule.use : [rule.use];
        for (const profile of uses) profiles.push({ ...profile, when: rule.when || "configured rule" });
      }
      if (config.default) profiles.push({ ...config.default, when: "default" });
      for (const profile of profiles) {
        if (!profile || !VERIFIED_HARNESSES.has(profile.harness)) {
          valid = false;
          reason = "dispatch profile contains an unverified or missing harness";
          continue;
        }
        lanes.push({
          harness: profile.harness,
          model: profile.model || null,
          effort: profile.effort || null,
          when: profile.when,
          available: executableOnPath(profile.harness),
          availability_evidence: executableOnPath(profile.harness) ? "executable present" : "configured harness executable missing",
          quota: "not observed - capacity never guesses quota",
        });
      }
    } catch (error) {
      valid = false;
      reason = `dispatch profile is invalid JSON: ${error.message}`;
    }
  } else {
    const result = run(path.join(SCRIPT_DIR, "fm-harness.sh"), ["crew"], {
      env: { ...process.env, FM_HOME: fmHome, FM_CONFIG_OVERRIDE: configDir },
      timeout,
    });
    const harness = (result.stdout || "").trim() || "unknown";
    lanes.push({
      harness,
      model: null,
      effort: null,
      when: "static crewmate harness fallback",
      available: VERIFIED_HARNESSES.has(harness) && executableOnPath(harness),
      availability_evidence: VERIFIED_HARNESSES.has(harness)
        ? (executableOnPath(harness) ? "executable present" : "resolved harness executable missing")
        : "effective harness could not be resolved",
      quota: "not observed - capacity never guesses quota",
    });
  }
  const unique = new Map();
  for (const lane of lanes) {
    const key = [lane.harness, lane.model || "", lane.effort || "", lane.when].join("|");
    unique.set(key, lane);
  }
  return { config_present: configPresent, valid, reason, lanes: [...unique.values()] };
}

function unavailableHomeEnvironment(evidence) {
  return {
    backend: { name: "unknown", available: false, evidence, owner: "bin/fm-backend.sh" },
    github_auth: { status: "unknown", evidence, owner: "bin/fm-bootstrap.sh startup credential check" },
    dispatch: { config_present: false, valid: false, reason: evidence, lanes: [] },
  };
}

function remainingProbeTimeout(deadline, maximum) {
  return Math.max(1, Math.min(maximum, deadline - Date.now()));
}

function probeHomeEnvironment(fmHome, configDir, deadline = Number.POSITIVE_INFINITY) {
  if (Date.now() >= deadline) return unavailableHomeEnvironment("aggregate home probe deadline exhausted");
  const backendProbe = run("bash", ["-c", `
    . "$1" || exit 4
    backend=$(fm_backend_name) || exit 5
    if ! fm_backend_validate_spawn "$backend" >/dev/null 2>&1; then
      printf '%s|false|invalid backend or backend cannot spawn\n' "$backend"
      exit 0
    fi
    missing=
    tools=$(fm_backend_required_tools "$backend") || tools=
    for tool in $tools; do
      fm_backend_required_tool_available "$backend" "$tool" || missing="\${missing}\${missing:+, }$tool"
    done
    if [ -n "$missing" ]; then
      printf '%s|false|missing: %s\n' "$backend" "$missing"
    else
      printf '%s|true|required runtime tools present\n' "$backend"
    fi
  `, "fm-capacity-backend", path.join(SCRIPT_DIR, "fm-backend.sh")], {
    env: { ...process.env, FM_HOME: fmHome, FM_CONFIG_OVERRIDE: configDir },
    timeout: remainingProbeTimeout(deadline, 5000),
  });
  const backendFields = (backendProbe.stdout || "unknown|false|backend probe failed").trim().split("|");
  if (Date.now() >= deadline) {
    const unavailable = unavailableHomeEnvironment("aggregate home probe deadline exhausted");
    unavailable.backend = {
      name: backendFields[0] || "unknown",
      available: backendFields[1] === "true",
      evidence: backendFields.slice(2).join("|") || "backend probe failed",
      owner: "bin/fm-backend.sh",
    };
    return unavailable;
  }
  const bootstrap = run(path.join(SCRIPT_DIR, "fm-bootstrap.sh"), [], {
    env: { ...process.env, FM_HOME: fmHome, FM_CONFIG_OVERRIDE: configDir, FM_BOOTSTRAP_DETECT_ONLY: "1" },
    timeout: remainingProbeTimeout(deadline, 15000),
  });
  const diagnostics = `${bootstrap.stdout || ""}\n${bootstrap.stderr || ""}`;
  const dispatch = Date.now() < deadline
    ? configuredDispatch(configDir, fmHome, remainingProbeTimeout(deadline, 3000))
    : unavailableHomeEnvironment("aggregate home probe deadline exhausted").dispatch;
  const dispatchDiagnostic = diagnostics.match(/CREW_DISPATCH: invalid config\/crew-dispatch\.json - ([^\n]+)/);
  if (dispatchDiagnostic) {
    dispatch.valid = false;
    dispatch.reason = dispatchDiagnostic[1].trim();
  }
  return {
    backend: {
      name: backendFields[0] || "unknown",
      available: backendFields[1] === "true",
      evidence: backendFields.slice(2).join("|") || "backend probe failed",
      owner: "bin/fm-backend.sh",
    },
    github_auth: {
      status: diagnostics.includes("NEEDS_GH_AUTH") || bootstrap.status !== 0 ? "unavailable" : "available",
      evidence: diagnostics.includes("NEEDS_GH_AUTH")
        ? "bootstrap credential check reported NEEDS_GH_AUTH"
        : bootstrap.status === 0
          ? "bootstrap credential check passed"
          : "bootstrap detect-only probe failed",
      owner: "bin/fm-bootstrap.sh startup credential check",
    },
    dispatch,
  };
}

function liveEnvironment(snapshot) {
  const roots = snapshot.roots || {};
  const fmHome = snapshot.fm_home || ROOT;
  const deadline = Date.now() + HOME_PROBE_BUDGET_MS;
  const main = probeHomeEnvironment(fmHome, roots.config || path.join(fmHome, "config"), deadline);
  const secondmates = {};
  for (const mate of snapshot.secondmate_current?.records || []) {
    if (typeof mate.id !== "string" || typeof mate.home !== "string" || !mate.home) continue;
    secondmates[mate.id] = probeHomeEnvironment(mate.home, path.join(mate.home, "config"), deadline);
  }
  return { ...main, secondmates };
}

function normalizeHomeEnvironment(environment = {}) {
  const backendName = typeof environment.backend?.name === "string" && /^[a-z0-9-]+$/.test(environment.backend.name)
    ? environment.backend.name
    : "unknown";
  const authStatus = ["available", "unavailable", "unknown"].includes(environment.github_auth?.status)
    ? environment.github_auth.status
    : "unknown";
  const dispatchValid = environment.dispatch?.valid === true;
  return {
    backend: {
      name: backendName,
      available: environment.backend?.available === true,
      evidence: environment.backend?.available === true ? "required runtime surface available" : "required runtime surface unavailable",
      owner: "bin/fm-backend.sh",
    },
    github_auth: {
      status: authStatus,
      evidence: authStatus === "available" ? "credential check passed" : "credential check unavailable",
      owner: "bin/fm-bootstrap.sh",
    },
    dispatch: {
      config_present: environment.dispatch?.config_present === true,
      valid: dispatchValid,
      reason: dispatchValid ? null : "dispatch configuration unavailable",
      lanes: (environment.dispatch?.lanes || []).map((lane) => ({
        harness: VERIFIED_HARNESSES.has(lane.harness) ? lane.harness : "unknown",
        model: null,
        effort: ["low", "medium", "high", "xhigh", "max"].includes(lane.effort) ? lane.effort : null,
        when: lane.when === "default" ? "configured default" : "configured dispatch rule",
        available: lane.available === true,
        availability_evidence: lane.available === true ? "configured executable present" : "configured executable unavailable",
        quota: "not observed - capacity never guesses quota",
      })),
    },
  };
}

function normalizeEnvironment(environment) {
  const main = normalizeHomeEnvironment(environment);
  const secondmates = Object.fromEntries(
    Object.entries(environment.secondmates || {}).map(([id, homeEnvironment]) => [id, normalizeHomeEnvironment(homeEnvironment)])
  );
  return { ...main, secondmates };
}

const opaqueRefs = new Map();
const opaqueRefLabels = new Map();
const opaqueRefMetadata = new Map();

function opaqueRef(kind, value) {
  const key = `${kind}\0${String(value ?? "")}`;
  if (!opaqueRefs.has(key)) {
    const count = [...opaqueRefs.keys()].filter((entry) => entry.startsWith(`${kind}\0`)).length + 1;
    opaqueRefs.set(key, `${kind}-${String(count).padStart(2, "0")}`);
  }
  return opaqueRefs.get(key);
}

function itemRef(owner, id) {
  return opaqueRef("item", `${owner}/${id}`);
}

function labeledItemRef(owner, id, label) {
  const ref = itemRef(owner, id);
  if (typeof label === "string" && label.trim()) opaqueRefLabels.set(ref, label.trim().slice(0, 200));
  return ref;
}

function decisionRef(owner, origin, key) {
  return opaqueRef("item", `decision/${owner}/${origin}/${key}`);
}

function rememberDecisionDetail(ref, detail) {
  const normalized = detail?.available === true
    && typeof detail.title === "string"
    && typeof detail.context === "string"
    && Array.isArray(detail.options)
    ? {
        available: true,
        title: detail.title,
        context: detail.context,
        options: detail.options,
      }
    : {
        available: false,
        reason: typeof detail?.reason === "string" && detail.reason
          ? detail.reason
          : "structured decision detail was not included in the bounded snapshot",
      };
  const current = opaqueRefMetadata.get(ref)?.decision_detail;
  if (current?.available === true && normalized.available !== true) return;
  opaqueRefMetadata.set(ref, { decision_detail: normalized });
}

function backlogDecisionIdentity(record) {
  const body = String(record.body_excerpt || "");
  const origin = body.match(/(?:^|\n)Origin:\s*([A-Za-z0-9._-]+)/)?.[1] || record.id;
  const key = body.match(/(?:^|\n)Decision key:\s*([A-Za-z0-9._-]+)/)?.[1] || record.id;
  return { origin, key };
}

function ownerRef(owner) {
  if (owner === "main" || owner === "ephemeral worker") return owner;
  return `persistent ${opaqueRef("home", String(owner).replace(/^secondmate\s+/, ""))}`;
}

function projectRef(repo) {
  return repo ? opaqueRef("project", repo) : null;
}

function safeState(state) {
  return ["working", "parked", "blocked", "paused", "done", "failed", "unknown", "no_active_work", "active_child_work", "captain_decision", "externally_held"].includes(state)
    ? state
    : "unknown";
}

function safeSource(source) {
  return ["pane", "run-step", "status-fold", "backlog", "child-state", "structured-home"].includes(source)
    ? source
    : "authoritative current-state owner";
}

function agentActivity(state, detail, decisions = 0, stage = null, captainApproval = false) {
  const normalized = safeState(state);
  const doing = String(detail || "");
  if (normalized === "unknown") {
    return { activity: "unavailable", label: "Unavailable", detail: "Current activity could not be read." };
  }
  if (decisions > 0) {
    return { activity: "waiting_on_decision", label: "Waiting on a decision", detail: "A decision is needed before work can continue." };
  }
  if (normalized === "captain_decision") {
    return { activity: "waiting_on_decision", label: "Waiting on a decision", detail: "Work in this home needs a decision." };
  }
  if (normalized === "no_active_work") {
    return { activity: "idle", label: "Idle", detail: "No active work is assigned in this home." };
  }
  if (/(?:running).{0,20}(?:ci|checks)|(?:ci|checks).{0,20}(?:running)/i.test(doing)) {
    return { activity: "waiting_on_ci", label: "Waiting on checks", detail: "Automated checks are running." };
  }
  if (/(?:waiting|awaiting|pending).{0,20}(?:ci|checks)|(?:ci|checks).{0,20}(?:waiting|awaiting|pending)/i.test(doing)) {
    return { activity: "waiting_on_ci", label: "Waiting on checks", detail: "Automated checks are pending." };
  }
  if (/(?:waiting|awaiting|pending|ready).{0,30}(?:captain|review|approvals?|merge)|(?:captain|review|approvals?|merge).{0,30}(?:waiting|awaiting|pending|ready)/i.test(doing)) {
    return captainApproval
      ? { activity: "waiting_on_review", label: "Waiting for your review or merge", detail: "Your review or merge is needed before work can continue." }
      : { activity: "waiting", label: "Waiting", detail: "Review or merge is pending." };
  }
  if (stage === "validating_fixing" || /validat|fixing|review|\btest(?:ing)?\b|lint|document|rebase|pre-push/i.test(doing)) {
    return { activity: "validating", label: "Validating", detail: "Review and checks are under way." };
  }
  if (normalized === "working" || normalized === "active_child_work") {
    return { activity: "working", label: "Working", detail: "Actively working on the task." };
  }
  return { activity: "waiting", label: "Waiting", detail: "Waiting for the recorded condition to clear." };
}

function liveAgentRollCall(snapshot) {
  const records = [];
  let workerNumber = 0;
  const addWorker = (owner, task, observedAt) => {
    const state = task.current_state?.state || task.state || "unknown";
    if (["done", "failed"].includes(state) || task.endpoint?.exists === false) return;
    workerNumber += 1;
    const title = task.backlog?.title || task.title || task.id || "Current task";
    const decisions = Array.isArray(task.hints?.open_decisions)
      ? task.hints.open_decisions.length
      : Number(task.decisions || 0);
    const stage = task.current_state ? taskStage(task) : null;
    const captainApproval = task.approval_authority === "captain"
      || task.captain_approval_required === true
      || (task.yolo === "off" && task.approval_authority !== "firstmate" && task.captain_approval_required !== false);
    const activity = agentActivity(state, task.current_state?.detail || task.doing, decisions, stage, captainApproval);
    records.push({
      agent: `Worker ${workerNumber}`,
      role: "worker",
      home: owner === "main" ? "Main home" : `Domain ${opaqueRef("home", owner)}`,
      task: labeledItemRef(owner, task.id, title),
      ...activity,
      as_of: task.current_state?.observed_at || task.observed_at || observedAt,
    });
  };

  for (const task of snapshot.tasks || []) {
    if (task.kind !== "secondmate") addWorker("main", task, snapshot.generated);
  }

  for (const mate of snapshot.secondmate_current?.records || []) {
    const home = `Domain ${opaqueRef("home", mate.id)}`;
    const agentsOmitted = (mate.omitted || []).some((entry) => entry.surface === "agents")
      || (Number.isInteger(mate.counts?.agents) && Array.isArray(mate.agents) && mate.counts.agents !== mate.agents.length);
    const supervisorActivity = agentsOmitted
      ? { activity: "unavailable", label: "Unavailable", detail: "Some worker details were outside this bounded reading." }
      : agentActivity(mate.current?.state, mate.current?.reason);
    records.push({
      agent: "Supervisor",
      role: "supervisor",
      home,
      task: mate.current?.state === "unknown" || agentsOmitted ? "Current home details unavailable" : "Coordinate this home's work",
      ...supervisorActivity,
      as_of: mate.freshness?.observed_at || snapshot.generated,
    });
    if (mate.provenance?.selected !== "structured-home") continue;
    const projected = Array.isArray(mate.agents) ? mate.agents : [
      ...(mate.active_children || []),
      ...(mate.holds || []).filter((hold) => hold.source === "child-state"),
    ];
    const byId = new Map();
    for (const task of projected) if (task?.id && !byId.has(task.id)) byId.set(task.id, task);
    for (const task of byId.values()) addWorker(mate.id, task, mate.freshness?.observed_at || snapshot.generated);
  }
  const observedHomes = new Set((snapshot.secondmate_current?.records || []).map((mate) => mate.id));
  for (const mate of snapshot.secondmate_current?.registry?.records || []) {
    if (!mate?.id || observedHomes.has(mate.id)) continue;
    records.push({
      agent: "Supervisor",
      role: "supervisor",
      home: `Domain ${opaqueRef("home", mate.id)}`,
      task: "Current home details unavailable",
      activity: "unavailable",
      label: "Unavailable",
      detail: "This registered home was outside the bounded reading.",
      as_of: snapshot.generated,
    });
  }
  const registry = snapshot.secondmate_current?.registry;
  if (registry?.available === false || registry?.input_truncated === true || registry?.records_truncated === true) {
    const unavailable = registry.available === false;
    const retained = Array.isArray(registry.records) ? registry.records.length : 0;
    const inWindow = Number.isInteger(registry.records_in_window) ? registry.records_in_window : null;
    const omitted = !unavailable && registry.input_truncated === false && inWindow !== null && inWindow > retained
      ? inWindow - retained
      : null;
    records.push({
      agent: omitted === null ? "Additional supervisors" : `${omitted} additional supervisor${omitted === 1 ? "" : "s"}`,
      role: "supervisor",
      home: "Registered homes outside reading",
      task: "Current home details unavailable",
      activity: "unavailable",
      label: "Unavailable",
      detail: unavailable
        ? "The registered supervisor table could not be read; supervisor count is unavailable."
        : omitted === null
          ? "The bounded registry reading omitted additional identities; their count is unavailable."
          : `${omitted} registered home ${omitted === 1 ? "identity was" : "identities were"} outside the bounded registry reading.`,
      as_of: registry.freshness?.observed_at || snapshot.generated,
    });
  }
  return { generated: snapshot.generated, records };
}

function safeDeliveryMode(mode) {
  return ["no-mistakes", "direct-PR", "local-only"].includes(mode) ? mode : null;
}

function requiresGithubAuth(mode) {
  return ["no-mistakes", "direct-PR"].includes(safeDeliveryMode(mode));
}

function dateAgeDays(value, now) {
  if (!value) return null;
  const parsed = Date.parse(`${value}T00:00:00Z`);
  if (!Number.isFinite(parsed)) return null;
  return Math.max(0, Math.floor((now - parsed) / 86400000));
}

function bodyHasAcceptance(record) {
  const text = String(record.body_excerpt || "").trim();
  const namedMarkers = "acceptance criteria|done when|definition of done|success criteria";
  if (!text || new RegExp(`\\bno\\s+(?:${namedMarkers})\\b`, "i").test(text)) return false;
  const lines = text.split(/\r?\n/).map((line) => line.trim());
  const inlineMarker = new RegExp(`^(?:#{1,6}\\s*)?(?:${namedMarkers})\\s*[:\\-]\\s*(.+)$`, "i");
  const headingMarker = new RegExp(`^(?:#{1,6}\\s*)?(?:${namedMarkers})\\s*:?\\s*$`, "i");
  let criteria = null;
  for (let index = 0; index < lines.length; index += 1) {
    const inline = lines[index].match(inlineMarker)
      || lines[index].match(/^(?:acceptance|verify|verification|tests?)\s*:\s*(.+)$/i);
    if (inline) {
      criteria = inline[1].trim();
      break;
    }
    if (headingMarker.test(lines[index])) {
      const listed = lines[index + 1]?.match(/^[-*]\s+(.+)$/);
      if (listed) criteria = listed[1].trim();
      break;
    }
  }
  if (!criteria) return false;
  criteria = criteria.replace(/^[*-]\s*/, "");
  if (criteria.length < 8) return false;
  const placeholder = /^(?:(?:todo|tbd|fixme|wip|placeholder|draft|pending|forthcoming|undefined|unknown|undecided|unresolved|none|n\/?a|not applicable|not defined)\b|(?:to be|will be|not yet)\s+(?:defined|determined|written|added|confirmed|finalized)\b)/i;
  return !placeholder.test(criteria) && (criteria.match(/[a-z0-9][\w-]*/gi) || []).length >= 2;
}

function isSuperseded(record) {
  return /\b(?:SUPERSEDED|DEFERRED)\b|\bNOT(?:\s+|-)REQUIRED\b/i.test(record.body_excerpt || "");
}

function definitionGaps(record, crossHome = false) {
  const gaps = [];
  if (!record.repo || record.project_resolved !== true) gaps.push("project unresolved");
  if (!record.kind || !["ship", "scout"].includes(record.kind)) gaps.push("deliverable kind missing");
  if (!record.title || record.title.trim().length < 12 || /^(todo|tbd|fix|investigate|work item)$/i.test(record.title.trim())) gaps.push("scope is insufficient");
  if (!bodyHasAcceptance(record)) gaps.push(crossHome && record.body_excerpt === undefined ? "acceptance evidence unavailable" : "acceptance criteria missing");
  if (/\b(?:depends?\s+on|blocked\s+by)\b|\bdependency\s*:/i.test(`${record.title || ""} ${record.body_excerpt || ""}`) && !record.blocked_by) gaps.push("dependency definition missing");
  return gaps;
}

function futureTimeGate(record, now) {
  const until = isoDate(record.hold_until);
  if (until && record.hold_reason != null) {
    const holdGate = Date.parse(`${until}T00:00:00Z`);
    if (Number.isFinite(holdGate) && holdGate > now) return until;
  }
  const text = `${record.title || ""} ${record.blocked_reason || ""} ${record.body_excerpt || ""}`;
  const match = text.match(/\b(?:after|until|not before)\s+(20\d{2}-\d{2}-\d{2})/i);
  if (!match) return null;
  const gate = Date.parse(`${match[1]}T00:00:00Z`);
  return Number.isFinite(gate) && gate > now ? match[1] : null;
}

function priorityRank(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (/^p?\d+$/.test(normalized)) return Number(normalized.replace(/^p/, ""));
  return {
    critical: 0,
    urgent: 0,
    highest: 0,
    high: 1,
    medium: 2,
    normal: 2,
    low: 3,
    lowest: 4,
  }[normalized] ?? Number.MAX_SAFE_INTEGER;
}

function localCandidateOrder(a, b) {
  const priorityDifference = priorityRank(a.record.priority) - priorityRank(b.record.priority);
  if (priorityDifference !== 0) return priorityDifference;
  const aOrder = Number.isInteger(a.record.order) ? a.record.order : Number.MAX_SAFE_INTEGER;
  const bOrder = Number.isInteger(b.record.order) ? b.record.order : Number.MAX_SAFE_INTEGER;
  return aOrder - bOrder || `${a.owner}/${a.record.id}`.localeCompare(`${b.owner}/${b.record.id}`);
}

function taskStage(task) {
  const state = task.current_state?.state || "unknown";
  const detail = task.current_state?.detail || "";
  const decision = (task.hints?.open_decisions || []).length > 0;
  const prState = task.pr?.reconciliation?.status || null;
  if (decision || ["blocked", "paused", "unknown", "failed"].includes(state)) return "blocked";
  if (prState === "merged" && ["done", "parked"].includes(state)) return null;
  if (task.endpoint?.exists === false) return "blocked";
  if (prState === "closed") return "blocked";
  if (task.pr?.url && prState !== "merged" && (state === "done" || state === "parked")) return "pr_ci_approval";
  if (/validat|fixing|ci |ci running|parked at/i.test(detail) || state === "parked") return "validating_fixing";
  if (task.pr?.url && prState !== "merged") return "pr_ci_approval";
  if (state === "done") return "pr_ci_approval";
  return "building";
}

function taskApprovalReady(task) {
  if (task.pr?.reconciliation?.status === "unavailable") return false;
  if (task.current_state?.state !== "done") return false;
  const detail = task.current_state?.detail || "";
  if (task.mode === "direct-PR") return Boolean(task.pr?.url);
  if (task.mode === "local-only") return /\bready\s+in\s+branch\b/i.test(detail);
  return Boolean(task.pr?.url)
    && /\b(?:checks?|ci)(?:\s+(?:are|is))?\s+green\b|\bready\s+for\s+(?:approval|merge)\b|\bawaiting\s+(?:captain\s+)?approval\b/i.test(detail);
}

function cardFromBacklog(record, owner, stage, reason = null) {
  return {
    id: itemRef(owner, record.id || "unstructured"),
    title: `${STAGE_LABELS[stage]} work item`,
    owner: ownerRef(owner),
    repo: projectRef(record.repo),
    kind: ["ship", "scout", "captain"].includes(record.kind) ? record.kind : null,
    delivery_mode: safeDeliveryMode(record.delivery_mode),
    stage,
    reason: reason || "Structured operational detail withheld",
    artifact: null,
    provenance: owner === "main" ? "main structured backlog" : "validated structured-home backlog",
  };
}

// Captain-parked work (active hold kind=parked) is deliberately dormant: it
// never joins a pipeline stage, count, attention summary, or wait treatment,
// and the park reason stays out of this privacy-bounded artifact.
function parkedCard(record, owner) {
  return {
    id: itemRef(owner, record.id || "unstructured"),
    owner: ownerRef(owner),
    repo: projectRef(record.repo),
    kind: ["ship", "scout"].includes(record.kind) ? record.kind : null,
    delivery_mode: safeDeliveryMode(record.delivery_mode),
    parked_since: /^\d{4}-\d{2}-\d{2}$/.test(record.since || "") ? record.since : null,
    reason: "Parked at your request - deliberately resting, not stuck",
    provenance: owner === "main" ? "main structured backlog" : "validated structured-home backlog",
  };
}

// Scheduled cadence work (an active hold with kind=future and a --until date
// still in the future) is healthy, not stuck: it waits for its next run date
// in the recurring collection, never a pipeline stage, count, attention
// summary, aging signal, or wait treatment, and its hold reason stays out of
// this privacy-bounded artifact. The backlog schema has no first-class
// recurrence marker, so the date-gated future hold is the honest v1
// recurrence key; see --help RECURRING.
function isoDate(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value ?? "")) ? value : null;
}

// tasks-axi date-gate semantics: a hold with --until is inactive on and after
// that date, whatever its kind.
function holdExpired(record, now) {
  const until = isoDate(record.hold_until);
  if (!until) return false;
  const gate = Date.parse(`${until}T00:00:00Z`);
  return Number.isFinite(gate) && gate <= now;
}

function activeHold(record, now) {
  return record.hold_reason != null && !holdExpired(record, now);
}

function recurringNextRun(record, now) {
  if (record.blocked_by || !activeHold(record, now) || record.hold_kind !== "future") return null;
  const until = isoDate(record.hold_until);
  if (!until) return null;
  const gate = Date.parse(`${until}T00:00:00Z`);
  return Number.isFinite(gate) && gate > now ? until : null;
}

// Deterministic cadence stem: the id with exactly one trailing date or counter
// token stripped ("research-w4" and "research-w3" share "research"), so
// successive runs of one recurring item match while unrelated ids do not.
function recurringStem(id) {
  const text = String(id || "");
  const stem = text.replace(/(?:[-_.]\d{4}-\d{2}-\d{2}|[-_.][a-z]{0,4}\d+)$/i, "");
  return stem !== text && stem.length >= 3 ? stem : null;
}

function lastCompletedRun(record, owner, doneRecords) {
  const stem = recurringStem(record.id);
  if (!stem) return null;
  const latest = doneRecords
    .filter((done) => done.id !== record.id && recurringStem(done.id) === stem)
    .sort((a, b) => `${a.completion?.date || ""}/${a.id}`.localeCompare(`${b.completion?.date || ""}/${b.id}`))
    .at(-1);
  if (!latest) return null;
  return {
    ref: itemRef(owner, latest.id),
    date: isoDate(latest.completion?.date),
    artifact_recorded: Boolean(latest.pr_url || latest.report_path || (latest.links || []).length > 0),
  };
}

function recurringCard(record, owner, nextRun, lastRun) {
  return {
    id: itemRef(owner, record.id || "unstructured"),
    owner: ownerRef(owner),
    repo: projectRef(record.repo),
    kind: ["ship", "scout"].includes(record.kind) ? record.kind : null,
    delivery_mode: safeDeliveryMode(record.delivery_mode),
    next_run: nextRun,
    scheduled_since: isoDate(record.since),
    last_run: lastRun,
    reason: "Scheduled cadence work - healthy and waiting for its next run",
    provenance: owner === "main" ? "main structured backlog" : "validated structured-home backlog",
  };
}

// Wait treatment: root kinds that clear with no actor at all, the captain
// copy per measurable wait kind, and the observation plumbing that feeds
// bin/fm-wait-progress.mjs. Only validation and CI are history-measurable;
// time gates get exact deadline math, and a declared external delay shows
// elapsed time with "time unknown" because one pause's length says nothing
// about another's.
const SELF_CLEARING_ROOTS = new Set(["gate", "paused", "finish"]);
const WAIT_COPY = {
  validation: "Waiting on its test suite and validation - resumes by itself",
  ci: "Waiting on CI checks - resumes by itself",
  paused: "Waiting on a declared external delay - resumes by itself",
};

function waitKindFromDetail(detail) {
  return /\bci\b/i.test(detail || "") ? "ci" : "validation";
}

// A declared pause is a captain gate when its recorded evidence shows the wait
// is on the captain, not an external process: the pause reason names the
// captain or addresses the captain directly, or an honestly open PR is present
// and the reason names a merge/review/approval-shaped gate. A captain gate is
// needs-your-action work and never gets a progress bar or ETA - there is no
// duration model for a human decision. An ambiguous pause with no captain
// signal stays self-clearing with elapsed-only, time-unknown progress.
//
// Open-PR evidence: a recorded pr= (or pr_present) is necessary but never
// sufficient on its own - meta keeps pr= after merge. Claim a PR wait only
// when that record is still open: no explicit merged/not-open signal, and a
// positive open signal (explicit open flag, armed merge poll, or the pause
// reason affirmatively saying the pull request is open or awaiting its
// review/merge). Otherwise render the pause's own declared reason and never
// invent open-PR language.
const CAPTAIN_GATE_REASON = /\bcaptain\b|\byour\s+(?:review|approval|decision|merge|order|sign-?off)\b/i;
const PR_GATE_REASON = /\b(?:merge|merging|review|approvals?|approve|decision|sign-?off)\b/i;
const PR_TERMINAL_REASON = /(?:\b(?:pull\s+requests?|PRs?)\b[^\n.!?;]{0,80}\b(?:merged|closed)\b|\b(?:merged|closed)\b[^\n.!?;]{0,80}\b(?:pull\s+requests?|PRs?)\b)/i;
const PR_OPEN_REASON = /(?:\bopen\s+(?:pull\s+requests?|PRs?)\b|\b(?:pull\s+requests?|PRs?)(?:\s*#?\d+)?\s+(?:is\s+)?(?:open|pending|awaiting|ready\s+for)\b|\b(?:awaiting|pending)\b[^\n.!?;]{0,60}\b(?:review|approval|merge)\b[^\n.!?;]{0,30}\b(?:pull\s+requests?|PRs?)\b)/i;

function pauseReasonText(task) {
  return String(task.current_state?.detail ?? task.reason ?? task.doing ?? "").trim();
}

function prRecorded(task) {
  const prUrl = typeof task.pr?.url === "string" && task.pr.url !== "" ? task.pr.url : null;
  return prUrl !== null || task.pr_present === true;
}

function hasOpenPrEvidence(task) {
  if (!prRecorded(task)) return false;
  const reconciledState = task.pr?.reconciliation?.status || null;
  if (reconciledState !== null) return reconciledState === "open";
  const reason = pauseReasonText(task);
  if (task.pr?.merged === true || task.pr_merged === true || task.pr?.open === false || task.pr_open === false) {
    return false;
  }
  if (task.pr?.merge_poll === "merged" || task.pr_merge_poll === "merged") return false;
  if (PR_TERMINAL_REASON.test(reason)) return false;
  if (task.pr?.open === true || task.pr_open === true) return true;
  if (task.pr?.merge_poll_armed === true || task.pr_merge_poll_armed === true) return true;
  return PR_OPEN_REASON.test(reason);
}

function captainGatedPause(task) {
  const reason = pauseReasonText(task);
  const openPr = hasOpenPrEvidence(task);
  const gated = CAPTAIN_GATE_REASON.test(reason) || (openPr && PR_GATE_REASON.test(reason));
  if (!gated) return null;
  if (openPr) {
    return {
      wait: "paused for your decision on its open pull request",
      action: "Review and merge its open pull request - this wait is on you, not an automatic process.",
    };
  }
  // Captain-gated but no open PR: keep the declared pause reason as the wait
  // description and derive a go/decision CTA from it - never invent a PR.
  const declared = reason || "your review or decision";
  return {
    wait: reason ? `paused: ${reason}` : "paused for your review or decision",
    action: `Give your go or decision on: ${declared} - this wait is on you, not an automatic process.`,
  };
}

// Queued backlog hold-kind=captain is captain prioritization / go-ahead work,
// whether the row is kind=captain (a keyed decision) or ship/scout (e.g. an
// audit feature idea held for the captain's prioritization). Never treat it as
// a stuck structured hold with "Nothing yet".
function captainPrioritizationHold(record, now) {
  return activeHold(record, now) && record.hold_kind === "captain";
}

function captainPrioritizationCopy(record, owner, projectedDecision = null) {
  if (record.kind === "captain") {
    const decision = projectedDecision || backlogDecisionIdentity(record);
    const ref = decisionRef(owner, decision.origin, decision.key);
    return {
      reason: "Captain hold",
      waits_on: [`waiting on your decision ${ref}`],
      what_you_can_do: `Answer decision ${ref} - it is the root cause.`,
      decision_ref: ref,
      decision,
    };
  }
  const ref = itemRef(owner, record.id || "unstructured");
  return {
    reason: "Waiting on your go",
    waits_on: ["held for your prioritization"],
    what_you_can_do: `Prioritize or give your go on ${ref} - this wait is on you, not an automatic process.`,
    decision_ref: null,
    decision: null,
  };
}

function classify(snapshot, environment, waitHistory = { schema: "fm-capacity-wait-history.v1", active: {}, durations: {} }) {
  if (snapshot.schema !== "fm-fleet-snapshot.v1") throw new Error(`unsupported snapshot schema: ${snapshot.schema || "missing"}`);
  const now = Date.parse(snapshot.generated) || Date.now();
  const observedWaits = new Map();
  const measurableWaits = [];
  const authoritativeWaitOwners = new Set();
  // Self-clearing card with a history-measurable wait: record the observation
  // (real identities stay in the private history file only) and fill progress
  // once every observation this run is known.
  const attachMeasurable = (card, owner, id, kind) => {
    const key = `${owner}/${id}:${kind}`;
    observedWaits.set(key, kind);
    card.wait = { class: "self_clearing", kind, copy: WAIT_COPY[kind], progress: null };
    measurableWaits.push({ card, key, kind });
  };
  // Self-clearing card whose end is a known future date: exact math, no history.
  const attachTimeGate = (card, gateDate, sinceDate = null) => {
    const gateEpoch = Date.parse(`${gateDate}T00:00:00Z`);
    const sinceEpoch = sinceDate ? Date.parse(`${sinceDate}T00:00:00Z`) : NaN;
    const elapsed = Number.isFinite(sinceEpoch) && sinceEpoch < now ? Math.floor((now - sinceEpoch) / 1000) : null;
    const progress = deadlineWait(Math.floor((gateEpoch - now) / 1000), elapsed);
    card.wait = {
      class: "self_clearing",
      kind: "time_gate",
      copy: `Scheduled wait - resumes automatically after ${gateDate}`,
      progress: { ...progress, label: progressLabel(progress) },
    };
  };
  const pipeline = Object.fromEntries(STAGES.map((stage) => [stage, []]));
  const parked = [];
  const recurring = [];
  const recurringIds = new Set();
  const mainRecords = snapshot.backlog?.records || [];
  const mainDone = mainRecords.filter((record) => record.state === "done" && record.structured);
  const taskById = new Map((snapshot.tasks || []).map((task) => [task.id, task]));
  const activeProjects = new Set();
  const decisions = [];
  const unavailable = [];
  const aging = [];
  const readinessRows = [];
  const blockedRows = [];
  const overlapRows = [];
  const mates = [];
  const mateAvailability = new Map();
  const mateRuntimeCapabilities = new Map();
  const activeRuntimeBlockedMates = new Set();
  const secondmateGithubBoundActive = new Set();
  const secondmateGithubBoundDelivery = new Set();
  const projectedRemoteDecisionRefs = new Set();
  let secondmateQueuedConsidered = 0;
  let readinessComplete = true;

  function markUnavailable(id, owner, evidence) {
    unavailable.push({ id, owner, evidence });
    readinessComplete = false;
  }

  let mainInventoryComplete = snapshot.backlog?.present === true
    && Array.isArray(snapshot.backlog?.records)
    && Array.isArray(snapshot.tasks);
  if (snapshot.backlog?.present !== true || !Array.isArray(snapshot.backlog?.records)) {
    markUnavailable("main-backlog", "main", "main structured backlog unavailable");
  }
  if (!Array.isArray(snapshot.tasks)) {
    markUnavailable("main-tasks", "main", "main current-task inventory unavailable");
  }
  const registry = snapshot.secondmate_current?.registry;
  const secondmateInventoryComplete = Boolean(snapshot.secondmate_current
    && Array.isArray(snapshot.secondmate_current.records)
    && Number.isInteger(snapshot.secondmate_current.truncated)
    && snapshot.secondmate_current.truncated === 0
    && registry?.available !== false
    && registry?.complete !== false);
  if (!snapshot.secondmate_current
    || !Array.isArray(snapshot.secondmate_current.records)
    || !Number.isInteger(snapshot.secondmate_current.truncated)
    || snapshot.secondmate_current.truncated > 0) {
    markUnavailable("secondmate-inventory", "main", "bounded secondmate inventory incomplete");
  }
  if (registry?.available === false || registry?.complete === false) {
    markUnavailable("secondmate-registry", "main", "registry projection incomplete");
  }
  const taskRootContexts = (task, owner, dependency = false) => {
    const open = task.hints?.open_decisions || [];
    const state = safeState(task.current_state?.state || task.state);
    const chatQuestion = open.some((decision) => !decision.key || decision.key === "default");
    const keyedDecisions = open.filter((decision) => decision.key && decision.key !== "default");
    if (dependency && ["done", "failed"].includes(state)) {
      return [{
        kind: "stale",
        key: `stale:${task.id}`,
        wait: `it is already ${state}; the dependency edge is stale`,
        action: "Nothing yet - firstmate reconciles this stale dependency",
      }];
    }
    const contexts = [];
    if (chatQuestion) {
      contexts.push({
        kind: "chat",
        key: `chat:${task.id}`,
        wait: "a worker question is being handled in chat",
        action: "Nothing - firstmate is handling the worker's question in chat.",
      });
    }
    for (const keyedDecision of keyedDecisions) {
      const ref = decisionRef(owner, keyedDecision.origin || task.id, keyedDecision.key);
      contexts.push({
        kind: "decision",
        key: `decision:${ref}`,
        wait: `waiting on your decision ${ref}`,
        action: `Answer decision ${ref} - it is the root cause.`,
      });
    }
    if (contexts.length > 0) return [...new Map(contexts.map((context) => [context.key, context])).values()];
    if (state === "paused") {
      const captainGate = captainGatedPause(task);
      if (captainGate) {
        return [{
          kind: "captain_gate",
          key: `captain-gate:${task.id}`,
          wait: captainGate.wait,
          action: captainGate.action,
        }];
      }
      return [{
        kind: "paused",
        key: `paused:${task.id}`,
        wait: "waiting on a declared external delay expected to clear on its own",
        action: "Nothing - this unblocks itself when the external wait clears.",
        self_clearing: true,
      }];
    }
    if (state === "unknown") {
      return [{
        kind: "unknown",
        key: `unknown:${task.id}`,
        wait: "its current state could not be read",
        action: "Nothing yet - firstmate reconciles the unavailable state and escalates if your input is needed.",
      }];
    }
    return [{
      kind: "worker",
      key: `worker:${task.id}`,
      wait: `the worker reports state: ${state}`,
      action: "Nothing yet - firstmate is on it and will escalate if your input is needed.",
    }];
  };
  for (const record of mainRecords.filter((item) => item.state === "in_flight" && item.structured)) {
    const task = taskById.get(record.id);
    const repo = record.repo || task?.project || null;
    if (repo) activeProjects.add(repo);
    if (!task || !repo) {
      markUnavailable(itemRef("main", record.id), "main", "in-flight work lacks current task or project provenance");
    }
    if (!task) mainInventoryComplete = false;
  }

  for (const task of snapshot.tasks || []) {
    if (task.kind === "secondmate") continue;
    const backlog = task.backlog || mainRecords.find((record) => record.structured && record.id === task.id) || {};
    const stage = taskStage(task);
    if (stage === null) continue;
    const ageDays = dateAgeDays(backlog.since, now);
    const taskRepo = backlog.repo || task.project || null;
    if (taskRepo) {
      activeProjects.add(taskRepo);
    } else {
      markUnavailable(itemRef("main", task.id), "main", "in-flight work lacks project provenance");
    }
    const open = task.hints?.open_decisions || [];
    // A keyless fold entry (key "default") is a worker question firstmate is
    // handling in chat, never a fabricated captain decision: it gets no
    // decision identity, no Decide row, and no dead-end detail view. Event
    // summaries stay out of this privacy-bounded artifact; the authenticated
    // dashboard service surfaces the concrete text in its detail views.
    const chatQuestionCount = open.filter((decision) => !decision.key || decision.key === "default").length;
    for (const decision of open) {
      if (!decision.key || decision.key === "default") continue;
      decisions.push({
        owner: "main",
        task: itemRef("main", task.id),
        key: decisionRef("main", task.id, decision.key),
        reason: "Open decision raised by work already under way.",
      });
    }
    const currentUnavailable = (task.current_state?.state || "unknown") === "unknown" || task.endpoint?.exists === false;
    const prReconciliationUnavailable = task.pr?.reconciliation?.status === "unavailable";
    if (currentUnavailable) {
      markUnavailable(itemRef("main", task.id), "main", "current task state unavailable");
      mainInventoryComplete = false;
    }
    if (prReconciliationUnavailable) {
      markUnavailable(
        itemRef("main", task.id),
        "main",
        `pull request state unavailable: ${task.pr.reconciliation.reason}`
      );
      mainInventoryComplete = false;
    }
    if (ageDays !== null && ageDays >= 7 && ["building", "validating_fixing", "pr_ci_approval", "blocked"].includes(stage)) {
      aging.push({ id: itemRef("main", task.id), owner: "main", age_days: ageDays, state: safeState(task.current_state?.state), evidence: `structured backlog age; current source ${safeSource(task.current_state?.source)}` });
    }
    const approvalReady = !currentUnavailable && taskApprovalReady(task);
    let taskWaits = null;
    let taskCanDo = null;
    let taskContexts = null;
    if (stage === "blocked") {
      taskContexts = currentUnavailable
        ? [{
            kind: "unknown",
            key: `unknown:${task.id}`,
            wait: "its current state could not be read",
            action: "Nothing yet - firstmate reconciles the unavailable state and escalates if your input is needed.",
          }]
        : prReconciliationUnavailable
          ? [{
              kind: "unknown",
              key: `unknown-pr:${task.id}`,
              wait: "its recorded pull request state could not be verified",
              action: "Nothing yet - firstmate reconciles the unavailable forge state and escalates if your input is needed.",
            }]
        : task.pr?.reconciliation?.status === "closed" && task.current_state?.state !== "paused"
          ? [{
              kind: "closed_pr",
              key: `closed-pr:${task.id}`,
              wait: "its recorded pull request is closed and is not a current approval gate",
              action: "Nothing yet - firstmate reconciles the closed delivery path.",
            }]
          : taskRootContexts(task, "main");
      taskWaits = taskContexts.map((context) => context.wait);
      taskCanDo = [...new Set(taskContexts.map((context) => context.action))].join(" ");
    }
    const taskCard = {
      id: itemRef("main", task.id),
      title: `${STAGE_LABELS[stage]} work item`,
      owner: "ephemeral worker",
      repo: projectRef(taskRepo),
      kind: ["ship", "scout"].includes(task.kind) ? task.kind : null,
      stage,
      reason: currentUnavailable
        ? "Current state unavailable - no authoritative detail or ETA is shown"
        : prReconciliationUnavailable
          ? "Pull request state unavailable - the recorded delivery gate could not be verified"
          : task.pr?.reconciliation?.status === "open" && stage === "pr_ci_approval"
            ? "Forge-verified current state: open pull request"
            : task.pr?.reconciliation?.status === "closed"
              ? "Forge-verified pull request is closed - delivery reconciliation is required"
              : chatQuestionCount > 0
                ? "Worker question being handled in chat"
                : `Authoritative current state: ${safeState(task.current_state?.state)}`,
      artifact: null,
      provenance: `current state from ${safeSource(task.current_state?.source)}`,
      age_days: ageDays,
      approval_ready: approvalReady,
      approval_authority: approvalReady ? (task.yolo === "on" ? "firstmate" : "captain") : null,
      captain_approval_required: approvalReady && task.yolo !== "on",
      waits_on: taskWaits,
      what_you_can_do: taskCanDo,
    };
    pipeline[stage].push(taskCard);
    if (taskContexts) {
      if (taskContexts.every((context) => context.kind === "paused")) {
        attachMeasurable(taskCard, "main", task.id, "paused");
      } else {
        taskCard.wait = { class: taskContexts.every((context) => context.self_clearing === true) ? "self_clearing" : "needs_actor" };
        if (taskContexts.some((context) => context.kind === "captain_gate")) taskCard.captain_gate = true;
      }
    } else if (stage === "validating_fixing" && (task.current_state?.state || "") === "working") {
      attachMeasurable(taskCard, "main", task.id, waitKindFromDetail(task.current_state?.detail));
    }
  }
  if (mainInventoryComplete) authoritativeWaitOwners.add("main");

  const blockedByIds = (record) => (Array.isArray(record.blocked_by_all)
    ? record.blocked_by_all
    : String(record.blocked_by || "").split(",")).map((id) => String(id).trim()).filter(Boolean);
  const describeBlockedRecord = (startRecord, owner, records, tasks = []) => {
    const recordById = new Map(records.filter((record) => record.structured !== false).map((record) => [record.id, record]));
    const blockerTaskById = new Map(tasks.map((task) => [task.id, task]));
    const roots = new Map();
    const expandedEdges = new Set();
    const stack = [];
    const addRoot = (key, segments, suffix, action, kind, until = null) => {
      if (roots.has(key)) return;
      roots.set(key, {
        wait: [...segments, ...(suffix ? [suffix] : [])].join("; then "),
        action,
        kind,
        until,
      });
    };
    const blockerIds = blockedByIds(startRecord);
    const startTask = blockerTaskById.get(startRecord.id);
    if (blockerIds.length === 0 && startTask) {
      const contexts = taskRootContexts(startTask, owner, true);
      return {
        waits: contexts.map((context) => context.wait),
        action: [...new Set(contexts.map((context) => context.action))].join(" "),
        root_kinds: contexts.map((context) => context.kind),
        gate_until: null,
      };
    }
    for (const blockerId of [...blockerIds].reverse()) {
      stack.push({ blockerId, segments: [], ancestors: new Set() });
    }
    while (stack.length > 0) {
      const { blockerId, segments, ancestors } = stack.pop();
      const blockerRef = itemRef(owner, blockerId);
      const blockerRecord = recordById.get(blockerId) || null;
      const blockerTask = blockerTaskById.get(blockerId) || null;
      const currentState = blockerTask ? safeState(blockerTask.current_state?.state || blockerTask.state) : null;
      if (!blockerRecord && !blockerTask) {
        addRoot(`missing:${blockerId}`, [...segments, `blocked by ${blockerRef}, whose current state is unavailable`], null, "Nothing yet - firstmate reconciles that unavailable blocker and escalates if your input is needed.", "missing");
        continue;
      }
      const terminalState = ["done", "failed"].includes(currentState)
        ? currentState
        : (["done", "failed"].includes(blockerRecord?.state) ? blockerRecord.state : null);
      if (terminalState) {
        addRoot(`stale:${blockerId}`, [...segments, `blocked by ${blockerRef}, but it is already ${terminalState}; the dependency edge is stale`], null, "Nothing yet - firstmate reconciles this stale dependency", "stale");
        continue;
      }
      const prefix = currentState
        ? `blocked by ${blockerRef}, which is currently ${safeState(currentState)}`
        : `blocked by ${blockerRef}, which is ${blockerRecord.state === "in_flight" ? "under way" : "queued and not started"}`;
      const nextSegments = [...segments, prefix];
      const taskContexts = blockerTask ? taskRootContexts(blockerTask, owner, true) : [];
      const applicableContexts = taskContexts.filter((context) => ["chat", "decision", "paused", "captain_gate", "unknown"].includes(context.kind));
      if (applicableContexts.length > 0) {
        for (const context of applicableContexts) addRoot(context.key, nextSegments, context.wait, context.action, context.kind);
        continue;
      }
      if (blockerRecord && captainPrioritizationHold(blockerRecord, now)) {
        const copy = captainPrioritizationCopy(blockerRecord, owner);
        if (copy.decision_ref) {
          addRoot(`decision:${copy.decision_ref}`, nextSegments, copy.waits_on[0], copy.what_you_can_do, "decision");
        } else {
          addRoot(`captain-go:${blockerId}`, nextSegments, copy.waits_on[0], copy.what_you_can_do, "captain_gate");
        }
        continue;
      }
      const gate = blockerRecord && futureTimeGate(blockerRecord, now);
      if (gate) {
        addRoot(`gate:${blockerId}`, nextSegments, `waiting until ${gate}`, `Nothing - this unblocks itself when the ${gate} time gate passes.`, "gate", gate);
        continue;
      }
      const nestedIds = blockerRecord ? blockedByIds(blockerRecord) : [];
      if (nestedIds.length > 0) {
        const nextAncestors = new Set(ancestors).add(blockerId);
        for (const nestedId of [...nestedIds].reverse()) {
          if (nextAncestors.has(nestedId)) {
            addRoot(`cycle:${[...nextAncestors, nestedId].sort().join(":")}`, nextSegments, `circular dependency through ${itemRef(owner, nestedId)}`, "Nothing yet - firstmate reconciles this circular dependency.", "cycle");
          } else {
            const edgeKey = `${blockerId}\0${nestedId}`;
            if (!expandedEdges.has(edgeKey)) {
              expandedEdges.add(edgeKey);
              stack.push({ blockerId: nestedId, segments: nextSegments, ancestors: nextAncestors });
            }
          }
        }
        continue;
      }
      if (blockerRecord && activeHold(blockerRecord, now)) {
        addRoot(`hold:${blockerId}`, nextSegments, "held by a structured hold", "Nothing yet - firstmate watches this hold and escalates if your input is needed.", "hold");
        continue;
      }
      const workerContext = taskContexts.find((context) => context.kind === "worker");
      if (workerContext && currentState === "blocked") {
        addRoot(workerContext.key, nextSegments, workerContext.wait, workerContext.action, "worker");
        continue;
      }
      const activelyRunning = currentState === "working" || (!blockerTask && blockerRecord?.state === "in_flight");
      if (activelyRunning) {
        addRoot(`finish:${blockerId}`, nextSegments, null, `Nothing - this unblocks itself when ${blockerRef} finishes.`, "finish");
      } else if (blockerRecord?.state === "queued") {
        addRoot(`queued:${blockerId}`, nextSegments, null, `Dispatch ${blockerRef} through the normal workflow - it is queued and not started.`, "queued");
      } else {
        addRoot(`resume:${blockerId}`, nextSegments, null, `Resume ${blockerRef} through the normal workflow - it is not actively running.`, "resume");
      }
    }
    if (blockerIds.length === 0) {
      const gate = futureTimeGate(startRecord, now);
      if (gate) return { waits: [`waiting until ${gate}`], action: `Nothing - this unblocks itself when the ${gate} time gate passes.`, root_kinds: ["gate"], gate_until: gate };
      if (captainPrioritizationHold(startRecord, now)) {
        const copy = captainPrioritizationCopy(startRecord, owner);
        return {
          waits: copy.waits_on,
          action: copy.what_you_can_do,
          root_kinds: [copy.decision_ref ? "decision" : "captain_gate"],
          gate_until: null,
        };
      }
      return { waits: ["held by a structured wait gate"], action: "Nothing yet - firstmate watches this hold and escalates if your input is needed.", root_kinds: ["hold"], gate_until: null };
    }
    const resolvedRoots = [...roots.values()];
    if (resolvedRoots.length === 0) {
      return {
        waits: ["circular dependency could not be resolved from the blocker graph"],
        action: "Nothing yet - firstmate reconciles this circular dependency.",
        root_kinds: ["cycle"],
        gate_until: null,
      };
    }
    return {
      waits: resolvedRoots.map((root) => root.wait),
      action: [...new Set(resolvedRoots.map((root) => root.action))].join(" "),
      root_kinds: resolvedRoots.map((root) => root.kind),
      gate_until: resolvedRoots.every((root) => root.kind === "gate")
        ? resolvedRoots.map((root) => root.until).sort().at(-1)
        : null,
    };
  };

  // Wait treatment for a chain-derived blocked card. An all-gate chain gets
  // exact deadline math; a declared external delay on the record's own state
  // shows elapsed-only, time-unknown progress; other all-self-clearing chains
  // are classed calm without invented numbers; a chain rooted entirely in a
  // captain gate marks the card as waiting on the captain; everything else
  // keeps the needs-actor treatment.
  const attachChainWait = (card, chain, owner, record) => {
    if (chain.gate_until) {
      attachTimeGate(card, chain.gate_until, record.since || null);
      return;
    }
    const kinds = chain.root_kinds || [];
    const selfClearing = kinds.length > 0 && kinds.every((kind) => SELF_CLEARING_ROOTS.has(kind));
    if (selfClearing && kinds.every((kind) => kind === "paused") && blockedByIds(record).length === 0) {
      attachMeasurable(card, owner, record.id, "paused");
      return;
    }
    card.wait = selfClearing
      ? { class: "self_clearing", kind: "dependency", copy: "Waiting on work already under way - resumes by itself", progress: null }
      : { class: "needs_actor" };
    if (kinds.length > 0 && kinds.every((kind) => kind === "captain_gate") && blockedByIds(record).length === 0) {
      card.captain_gate = true;
    }
  };

  const queue = mainRecords.filter((record) => record.state === "queued" && !taskById.has(record.id));
  const candidates = [];
  for (const record of queue) {
    if (!record.structured) {
      readinessRows.push({ id: itemRef("main", "unstructured"), owner: "main", status: "definition_gap", gaps: ["unstructured backlog row"] });
      pipeline.queued.push(cardFromBacklog(record, "main", "queued", "Unstructured backlog entry"));
      continue;
    }
    if (isSuperseded(record)) continue;
    const holdIsActive = activeHold(record, now);
    if (holdIsActive && record.hold_kind === "parked") {
      parked.push(parkedCard(record, "main"));
      continue;
    }
    const nextRun = recurringNextRun(record, now);
    if (nextRun) {
      recurring.push(recurringCard(record, "main", nextRun, lastCompletedRun(record, "main", mainDone)));
      recurringIds.add(`main/${record.id}`);
      continue;
    }
    if (captainPrioritizationHold(record, now)) {
      const copy = captainPrioritizationCopy(record, "main");
      if (copy.decision_ref) {
        decisions.push({
          owner: "main",
          task: itemRef("main", record.id),
          key: copy.decision_ref,
          reason: "A queued choice is held for your decision.",
        });
      }
      blockedRows.push({ id: itemRef("main", record.id), owner: "main", reason: "captain hold" });
      const holdCard = Object.assign(cardFromBacklog(record, "main", "blocked", copy.reason), {
        waits_on: copy.waits_on,
        what_you_can_do: copy.what_you_can_do,
        wait: { class: "needs_actor" },
      });
      if (!copy.decision_ref) holdCard.captain_gate = true;
      pipeline.blocked.push(holdCard);
      continue;
    }
    if (record.blocked_by || holdIsActive) {
      const reason = record.blocked_by
        ? `Blocked by ${blockedByIds(record).map((id) => itemRef("main", id)).join(", ")}`
        : "Structured hold";
      const chain = describeBlockedRecord(record, "main", mainRecords, snapshot.tasks || []);
      blockedRows.push({ id: itemRef("main", record.id), owner: "main", reason });
      const chainCard = Object.assign(cardFromBacklog(record, "main", "blocked", reason), {
        waits_on: chain.waits,
        what_you_can_do: chain.action,
      });
      pipeline.blocked.push(chainCard);
      attachChainWait(chainCard, chain, "main", record);
      continue;
    }
    const timeGate = futureTimeGate(record, now);
    if (timeGate) {
      const reason = `time gate until ${timeGate}`;
      blockedRows.push({ id: itemRef("main", record.id), owner: "main", reason });
      const gateCard = Object.assign(cardFromBacklog(record, "main", "blocked", reason), {
        waits_on: [`waiting until ${timeGate}`],
        what_you_can_do: `Nothing - this unblocks itself when the ${timeGate} time gate passes.`,
      });
      pipeline.blocked.push(gateCard);
      attachTimeGate(gateCard, timeGate, record.since || null);
      continue;
    }
    const gaps = definitionGaps(record);
    if (gaps.length > 0) {
      readinessRows.push({ id: itemRef("main", record.id), owner: "main", status: "definition_gap", gaps });
      pipeline.queued.push(cardFromBacklog(record, "main", "queued", gaps.join("; ")));
    } else {
      candidates.push({ record, owner: "main" });
      readinessRows.push({ id: itemRef("main", record.id), owner: "main", status: "grounded_candidate", gaps: [] });
    }
  }

  for (const mate of snapshot.secondmate_current?.records || []) {
    const route = (snapshot.secondmate_current?.registry?.records || []).find((record) => record.id === mate.id) || {};
    const runtime = environment.secondmates?.[mate.id] || null;
    const executionLaneAvailable = Boolean(
      runtime
      && runtime.backend.available
      && runtime.dispatch.valid
      && runtime.dispatch.lanes.some((lane) => lane.available)
    );
    const scopeAvailable = typeof route.scope === "string" && route.scope.trim().length > 0;
    const mateUnknown = mate.current?.state === "unknown" || mate.provenance?.selected !== "structured-home";
    const omittedSurfaces = new Set((mate.omitted || []).map((entry) => entry.surface));
    const mateIncomplete = mateUnknown
      || !Array.isArray(mate.active_children)
      || !Array.isArray(mate.decisions_open)
      || !Array.isArray(mate.holds)
      || !Array.isArray(mate.queued)
      || omittedSurfaces.has("active_children")
      || omittedSurfaces.has("decisions_open")
      || omittedSurfaces.has("queued")
      || omittedSurfaces.has("agents")
      || !Number.isInteger(mate.counts?.active_children)
      || !Number.isInteger(mate.counts?.decisions_open)
      || !Number.isInteger(mate.counts?.holds)
      || !Number.isInteger(mate.counts?.queued)
      || mate.counts.active_children !== (mate.active_children || []).length
      || mate.counts.decisions_open !== (mate.decisions_open || []).length
      || mate.counts.holds !== (mate.holds || []).length
      || mate.counts.queued !== (mate.queued || []).length
      || (Array.isArray(mate.agents)
          && (!Number.isInteger(mate.counts?.agents) || mate.counts.agents !== mate.agents.length));
    if (mateIncomplete) markUnavailable(opaqueRef("home", mate.id), "persistent secondmate", "structured home inventory incomplete");
    if (secondmateInventoryComplete && !mateIncomplete) authoritativeWaitOwners.add(mate.id);
    if (!scopeAvailable) markUnavailable(opaqueRef("home", mate.id), "persistent secondmate", "registered routing scope unavailable");
    if (!runtime) markUnavailable(opaqueRef("home", mate.id), "persistent secondmate", "home-owned runtime lane evidence unavailable");
    const mateDecisionById = new Map((mate.decisions_open || [])
      .filter((decision) => decision.id)
      .map((decision) => [decision.id, decision]));
    for (const decision of mate.decisions_open || []) {
      if (!decision.key || decision.key === "default") continue;
      const origin = decision.origin || decision.id || mate.id;
      const ref = decisionRef(mate.id, origin, decision.key);
      rememberDecisionDetail(ref, decision.detail);
      projectedRemoteDecisionRefs.add(ref);
      decisions.push({
        owner: ownerRef(mate.id),
        task: itemRef(mate.id, decision.id || mate.id),
        key: ref,
        reason: "Open decision raised by work already under way.",
      });
    }
    const mateTaskEvidence = [...(mate.active_children || []), ...(mate.holds || []).filter((hold) => hold.source === "child-state" && hold.state)]
      .map((child) => ({
        ...child,
        hints: {
          ...(child.hints || {}),
          open_decisions: (mate.decisions_open || []).filter((decision) => decision.id === child.id),
        },
      }));
    const parkedQueuedIds = new Set((mate.queued || []).filter((record) => activeHold(record, now) && record.hold_kind === "parked").map((record) => record.id));
    const recurringQueuedIds = new Set((mate.queued || []).filter((record) => recurringNextRun(record, now)).map((record) => record.id));
    const inactiveHoldQueuedIds = new Set((mate.queued || []).filter((record) => !record.blocked_by && record.hold_reason != null && holdExpired(record, now)).map((record) => record.id));
    const mateQueuedById = new Map((mate.queued || []).map((record) => [record.id, record]));
    const activeChildIds = new Set((mate.active_children || []).map((child) => child.id));
    const endpointById = new Map((mate.endpoints || []).filter((entry) => entry?.id).map((entry) => [entry.id, entry]));
    const heldIds = new Set();
    for (const hold of mate.holds || []) {
      // A parked, recurring, or expired-hold queued record can also project
      // into holds through its hold or dependency edge; the queued-loop
      // classification below wins for those (an expired hold is inactive and
      // re-enters normal readiness classification).
      if (parkedQueuedIds.has(hold.id) || recurringQueuedIds.has(hold.id) || inactiveHoldQueuedIds.has(hold.id)) continue;
      heldIds.add(hold.id);
      const queuedHold = mateQueuedById.get(hold.id);
      const holdRecord = queuedHold && captainPrioritizationHold(queuedHold, now) ? queuedHold : hold;
      if (hold.source === "child-state") {
        if (requiresGithubAuth(hold.delivery_mode)) secondmateGithubBoundDelivery.add(mate.id);
        if (hold.repo) {
          activeProjects.add(hold.repo);
        } else {
          markUnavailable(itemRef(mate.id, hold.id), ownerRef(mate.id), "in-flight held work lacks project provenance");
        }
      }
      const ageDays = dateAgeDays(hold.since, now);
      const captainHold = captainPrioritizationHold(holdRecord, now);
      const copy = captainHold ? captainPrioritizationCopy(holdRecord, mate.id, mateDecisionById.get(holdRecord.id)) : null;
      blockedRows.push({ id: itemRef(mate.id, hold.id), owner: ownerRef(mate.id), reason: captainHold ? "captain hold" : "structured wait gate" });
      const chain = captainHold ? null : describeBlockedRecord(hold, mate.id, [...(mate.holds || []), ...(mate.queued || [])], mateTaskEvidence);
      const holdCard = Object.assign(cardFromBacklog(holdRecord, mate.id, "blocked", copy?.reason || "Structured wait gate"), {
        waits_on: copy?.waits_on || chain.waits,
        what_you_can_do: copy?.what_you_can_do || chain.action,
      });
      if (copy?.decision_ref) holdCard.id = copy.decision_ref;
      pipeline.blocked.push(holdCard);
      if (captainHold) {
        holdCard.wait = { class: "needs_actor" };
        if (!copy.decision_ref) holdCard.captain_gate = true;
      } else {
        attachChainWait(holdCard, chain, mate.id, hold);
      }
      if (ageDays !== null && ageDays >= 7) {
        aging.push({ id: itemRef(mate.id, hold.id), owner: ownerRef(mate.id), age_days: ageDays, state: "held", evidence: "structured backlog age; structured wait gate" });
      }
    }
    for (const child of mate.active_children || []) {
      if (requiresGithubAuth(child.delivery_mode)) {
        secondmateGithubBoundActive.add(mate.id);
        secondmateGithubBoundDelivery.add(mate.id);
      }
      const detail = child.doing || child.state || "working";
      const endpointUnavailable = endpointById.get(child.id)?.endpoint?.exists === false;
      const currentUnavailable = child.state === "unknown" || endpointUnavailable;
      const stage = currentUnavailable
        ? "blocked"
        : /validat|fixing|ci /i.test(detail) ? "validating_fixing" : "building";
      if (child.repo) {
        activeProjects.add(child.repo);
      } else {
        markUnavailable(itemRef(mate.id, child.id), ownerRef(mate.id), "active child work lacks project provenance");
      }
      if (currentUnavailable) {
        markUnavailable(itemRef(mate.id, child.id), ownerRef(mate.id), "current child state unavailable");
      }
      const ageDays = dateAgeDays(child.since, now);
      const childCard = {
        id: itemRef(mate.id, child.id),
        title: `${STAGE_LABELS[stage]} work item`,
        owner: ownerRef(mate.id),
        repo: projectRef(child.repo),
        kind: ["ship", "scout"].includes(child.kind) ? child.kind : "ship",
        delivery_mode: safeDeliveryMode(child.delivery_mode),
        stage,
        reason: currentUnavailable
          ? "Current state unavailable - no authoritative detail or ETA is shown"
          : `Authoritative current state: ${safeState(child.state || "working")}`,
        artifact: null,
        provenance: "validated structured-home summary",
        age_days: ageDays,
        waits_on: currentUnavailable ? ["its current state could not be read"] : null,
        what_you_can_do: currentUnavailable
          ? "Nothing yet - firstmate reconciles the unavailable state and escalates if your input is needed."
          : null,
      };
      pipeline[stage].push(childCard);
      if (currentUnavailable) {
        childCard.wait = { class: "needs_actor" };
      } else if (stage === "validating_fixing" && (child.state || "working") === "working") {
        attachMeasurable(childCard, mate.id, child.id, waitKindFromDetail(detail));
      }
      if (ageDays !== null && ageDays >= 7) {
        aging.push({ id: itemRef(mate.id, child.id), owner: ownerRef(mate.id), age_days: ageDays, state: safeState(child.state), evidence: "structured backlog age; structured-home current state" });
      }
    }
    for (const record of mate.queued || []) {
      if (isSuperseded(record) || heldIds.has(record.id) || activeChildIds.has(record.id)) continue;
      const holdIsActive = activeHold(record, now);
      if (holdIsActive && record.hold_kind === "parked") {
        parked.push(parkedCard(record, mate.id));
        continue;
      }
      const nextRun = recurringNextRun(record, now);
      if (nextRun) {
        recurring.push(recurringCard(record, mate.id, nextRun, lastCompletedRun(record, mate.id, mate.landed || [])));
        recurringIds.add(`${mate.id}/${record.id}`);
        continue;
      }
      secondmateQueuedConsidered += 1;
      if (captainPrioritizationHold(record, now)) {
        // Secondmate decisions_open already supplies CAP-01 Decide rows for
        // kind=captain holds; do not double-count them here. Ship/scout
        // prioritization holds become captain_gate Review rows instead.
        const copy = captainPrioritizationCopy(record, mate.id, mateDecisionById.get(record.id));
        blockedRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), reason: "captain hold" });
        const mateHoldCard = Object.assign(cardFromBacklog(record, mate.id, "blocked", copy.reason), {
          waits_on: copy.waits_on,
          what_you_can_do: copy.what_you_can_do,
          wait: { class: "needs_actor" },
        });
        if (copy.decision_ref) mateHoldCard.id = copy.decision_ref;
        if (!copy.decision_ref) mateHoldCard.captain_gate = true;
        pipeline.blocked.push(mateHoldCard);
        continue;
      }
      if (record.blocked_by || holdIsActive) {
        const reason = record.blocked_by
          ? `Blocked by ${blockedByIds(record).map((id) => itemRef(mate.id, id)).join(", ")}`
          : "Structured hold";
        const chain = describeBlockedRecord(record, mate.id, [...(mate.holds || []), ...(mate.queued || [])], mateTaskEvidence);
        blockedRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), reason });
        const mateChainCard = Object.assign(cardFromBacklog(record, mate.id, "blocked", reason), {
          waits_on: chain.waits,
          what_you_can_do: chain.action,
        });
        pipeline.blocked.push(mateChainCard);
        attachChainWait(mateChainCard, chain, mate.id, record);
        continue;
      }
      const timeGate = futureTimeGate(record, now);
      if (timeGate) {
        const reason = `time gate until ${timeGate}`;
        blockedRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), reason });
        const mateGateCard = Object.assign(cardFromBacklog(record, mate.id, "blocked", reason), {
          waits_on: [`waiting until ${timeGate}`],
          what_you_can_do: `Nothing - this unblocks itself when the ${timeGate} time gate passes.`,
        });
        pipeline.blocked.push(mateGateCard);
        attachTimeGate(mateGateCard, timeGate, record.since || null);
        continue;
      }
      const gaps = definitionGaps(record, true);
      if (gaps.length > 0) {
        readinessRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), status: "definition_gap", gaps });
        pipeline.queued.push(cardFromBacklog(record, mate.id, "queued", gaps.join("; ")));
      } else {
        candidates.push({ record, owner: mate.id });
        readinessRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), status: "grounded_candidate", gaps: [] });
      }
    }
    const activeCount = mate.active_children?.length || 0;
    const mateId = opaqueRef("home", mate.id);
    mateAvailability.set(mateId, !mateIncomplete && scopeAvailable);
    mateRuntimeCapabilities.set(mate.id, {
      execution_lane_available: executionLaneAvailable,
      github_auth_available: runtime?.github_auth.status === "available",
    });
    mates.push({
      id: mateId,
      scope: scopeAvailable ? "Registered routing scope recorded; text withheld" : "Registered routing scope unavailable",
      projects: route.projects?.length ? [`${route.projects.length} registered project route(s); names withheld`] : [],
      current: safeState(mate.current?.state),
      provenance: mate.provenance?.selected === "structured-home" ? "validated structured-home summary" : "unavailable",
      active_children: activeCount,
      grounded_ready_in_scope: 0,
      ready_in_scope: 0,
      utilization: "unavailable",
      runtime: runtime || {
        backend: { name: "unknown", available: false, evidence: "required runtime surface unavailable" },
        github_auth: { status: "unknown", evidence: "credential check unavailable" },
        dispatch: { valid: false, lanes: [] },
      },
    });
  }

  // A registered home can fall outside the bounded secondmate-home reading.
  // Preserve any keyed parent-side decision fold as an explicitly unavailable
  // captain row instead of silently dropping it or pretending its detail was
  // read. This is fallback provenance only; readable structured-home rows win.
  const mateById = new Map((snapshot.secondmate_current?.records || [])
    .filter((mate) => mate?.id)
    .map((mate) => [mate.id, mate]));
  for (const route of snapshot.secondmate_current?.registry?.records || []) {
    if (!route?.id) continue;
    const mate = mateById.get(route.id);
    if (mate?.provenance?.selected === "structured-home") continue;
    const detailReason = typeof mate?.current?.reason === "string" && mate.current.reason
      ? mate.current.reason
      : mate
        ? "owning home did not report why its structured snapshot was unavailable"
        : "owning home was outside the bounded snapshot reading";
    const parent = taskById.get(route.id);
    for (const decision of parent?.hints?.open_decisions || []) {
      if (!decision.key || decision.key === "default") continue;
      const origin = decision.origin || route.id;
      const ref = decisionRef(route.id, origin, decision.key);
      if (projectedRemoteDecisionRefs.has(ref)) continue;
      rememberDecisionDetail(ref, {
        available: false,
        reason: detailReason,
      });
      projectedRemoteDecisionRefs.add(ref);
      decisions.push({
        owner: ownerRef(route.id),
        task: itemRef(route.id, origin),
        key: ref,
        reason: mate
          ? "Decision details unavailable because the owning home snapshot was unavailable."
          : "Decision details unavailable because the owning home was outside the bounded reading.",
      });
    }
  }

  const chosenProjects = new Set(activeProjects);
  const ready = [];
  const ownerOrder = new Map();
  for (const candidate of candidates) {
    if (!ownerOrder.has(candidate.owner)) ownerOrder.set(candidate.owner, ownerOrder.size);
  }
  candidates.sort((a, b) => a.owner === b.owner
    ? localCandidateOrder(a, b)
    : ownerOrder.get(a.owner) - ownerOrder.get(b.owner));
  const candidateOwnersByProject = new Map();
  for (const candidate of candidates) {
    if (!candidate.record.repo) continue;
    if (!candidateOwnersByProject.has(candidate.record.repo)) candidateOwnersByProject.set(candidate.record.repo, new Set());
    candidateOwnersByProject.get(candidate.record.repo).add(candidate.owner);
  }
  const crossHomeProjects = new Set(
    [...candidateOwnersByProject.entries()]
      .filter(([, owners]) => owners.size > 1)
      .map(([project]) => project)
  );
  for (const candidate of candidates) {
    const projectKey = candidate.record.repo || null;
    const activeConflict = projectKey && activeProjects.has(projectKey);
    const crossHomeConflict = projectKey && crossHomeProjects.has(projectKey);
    if (activeConflict || crossHomeConflict || (projectKey && chosenProjects.has(projectKey))) {
      overlapRows.push({
        id: itemRef(candidate.owner, candidate.record.id),
        owner: ownerRef(candidate.owner),
        reason: activeConflict
          ? "coarse project overlap with active work"
          : crossHomeConflict
            ? "cross-home project overlap requires routing decision"
            : "coarse project overlap with another ready item",
      });
      pipeline.queued.push(cardFromBacklog(
        candidate.record,
        candidate.owner,
        "queued",
        activeConflict
          ? "Potential coarse overlap with active project work"
          : crossHomeConflict
            ? "Cross-home project overlap requires an authoritative routing decision"
            : "Serialized conservatively with another ready project item",
      ));
    } else if (!readinessComplete) {
      pipeline.queued.push(cardFromBacklog(candidate.record, candidate.owner, "queued", "Readiness unavailable because the fleet snapshot is incomplete"));
    } else {
      if (projectKey) chosenProjects.add(projectKey);
      ready.push(candidate);
      pipeline.ready.push(cardFromBacklog(candidate.record, candidate.owner, "ready", "Grounded, unblocked, and conservatively independent"));
    }
  }
  const candidateExecutionAvailable = (candidate) => {
    const authRequired = requiresGithubAuth(candidate.record.delivery_mode);
    if (candidate.owner === "main") {
      const mainLaneAvailable = environment.dispatch.valid
        && environment.backend.available
        && environment.dispatch.lanes.some((lane) => lane.available);
      return mainLaneAvailable && (!authRequired || environment.github_auth.status === "available");
    }
    const runtime = mateRuntimeCapabilities.get(candidate.owner);
    return runtime?.execution_lane_available === true
      && (!authRequired || runtime.github_auth_available === true);
  };
  for (const mate of mates) {
    const mateCandidates = ready.filter((candidate) => candidate.owner !== "main" && opaqueRef("home", candidate.owner) === mate.id);
    const mateReady = mateCandidates.length;
    const mateExecutable = mateCandidates.filter(candidateExecutionAvailable).length;
    const available = readinessComplete && mateAvailability.get(mate.id);
    const runtimeEntry = [...mateRuntimeCapabilities.entries()].find(([owner]) => opaqueRef("home", owner) === mate.id);
    const [runtimeOwner, runtime] = runtimeEntry || [];
    const activeCredentialBlocked = secondmateGithubBoundActive.has(runtimeOwner)
      && runtime?.github_auth_available !== true;
    const activeRuntimeBlocked = mate.active_children > 0
      && runtime?.execution_lane_available !== true;
    if (activeRuntimeBlocked) activeRuntimeBlockedMates.add(mate.id);
    mate.grounded_ready_in_scope = available ? mateReady : 0;
    mate.ready_in_scope = available ? mateExecutable : 0;
    mate.utilization = !available
      ? "unavailable"
      : activeCredentialBlocked
        ? "active with unavailable delivery credentials"
      : activeRuntimeBlocked
        ? "active with unavailable execution lane"
      : mateReady > 0 && mateExecutable === 0
        ? "unavailable lane with grounded in-scope work"
      : mate.active_children > 0
        ? "active on useful in-scope work"
        : mateExecutable > 0
          ? "idle with grounded ready in-scope work"
          : "healthy idle - no grounded ready in-scope work";
  }

  const secondmateLanded = snapshot.secondmate_landed;
  const mainLandingsComplete = snapshot.backlog?.present === true
    && Array.isArray(snapshot.backlog?.records)
    && !snapshot.backlog.records.some((record) => record.state === "done" && record.structured !== true);
  const secondmateLandingsComplete = Boolean(
    secondmateLanded
    && Array.isArray(secondmateLanded.records)
    && Array.isArray(secondmateLanded.truncated)
    && secondmateLanded.truncated.length === 0
    && Array.isArray(secondmateLanded.unreadable)
    && secondmateLanded.unreadable.length === 0
  );
  const recentLandingsComplete = mainLandingsComplete && secondmateLandingsComplete;
  const incompleteLandingSources = [
    ...(mainLandingsComplete ? [] : ["Main backlog completion evidence"]),
    ...(secondmateLandingsComplete ? [] : ["Bounded secondmate landing projections"]),
  ];
  const recentLandingsProvenance = recentLandingsComplete
    ? "Main backlog completions and bounded secondmate landing projections are complete."
    : `${incompleteLandingSources.join(" and ")} ${incompleteLandingSources.length === 1 ? "is" : "are"} incomplete; the displayed count is an observed lower bound.`;
  const landed = [
    ...mainRecords.filter((record) => record.state === "done" && record.structured && record.kind !== "captain").map((record) => ({ ...record, owner: "main" })),
    ...(secondmateLanded?.records || []).map((record) => ({ ...record, owner: record.home_id || "secondmate" })),
  ].sort((a, b) => `${b.completion?.date || ""}/${b.id}`.localeCompare(`${a.completion?.date || ""}/${a.id}`)).slice(0, 12);
  for (const record of landed) {
    const completionDate = /^\d{4}-\d{2}-\d{2}$/.test(record.completion?.date || "") ? record.completion.date : "recent completion";
    pipeline.recently_landed.push(cardFromBacklog(record, record.owner, "recently_landed", completionDate));
  }

  const validationCards = [...pipeline.validating_fixing, ...pipeline.pr_ci_approval];
  const definitionRows = readinessRows.filter((row) => row.status === "definition_gap");
  const availableLanes = environment.dispatch.lanes?.filter((lane) => lane.available) || [];
  const laneMismatch = !environment.dispatch.valid || availableLanes.length === 0 || !environment.backend.available;
  const approvalReadyCards = pipeline.pr_ci_approval.filter((card) => card.approval_ready === true);
  const captainApprovalCards = approvalReadyCards.filter((card) => card.captain_approval_required === true);
  const captainGateCards = pipeline.blocked.filter((card) => card.captain_gate === true);
  const activeCount = pipeline.building.length + pipeline.validating_fixing.length + pipeline.pr_ci_approval.length;
  const ephemeralActiveCount = (snapshot.tasks || []).filter((task) =>
    task.kind !== "secondmate" && ["working", "parked", "blocked", "paused"].includes(task.current_state?.state)
  ).length;
  const mainGithubBoundWork = ready.some((candidate) =>
    candidate.owner === "main"
    && requiresGithubAuth(candidate.record.delivery_mode)
  ) || (snapshot.tasks || []).some((task) => {
    if (task.kind === "secondmate") return false;
    const backlog = mainRecords.find((record) => record.structured && record.id === task.id) || task.backlog || {};
    return backlog.state !== "done"
      && (Boolean(task.pr?.url) || requiresGithubAuth(task.mode))
      && ["working", "parked", "blocked", "paused", "done"].includes(task.current_state?.state);
  });
  const credentialBlockers = [];
  if (mainGithubBoundWork && environment.github_auth.status !== "available") {
    credentialBlockers.push({ owner: "main", status: environment.github_auth.status });
  }
  const blockedSecondmateCredentials = new Set();
  for (const owner of secondmateGithubBoundDelivery) {
    const status = environment.secondmates?.[owner]?.github_auth.status || "unknown";
    if (status === "available") continue;
    blockedSecondmateCredentials.add(owner);
    credentialBlockers.push({ owner: ownerRef(owner), status });
  }
  for (const candidate of ready) {
    if (candidate.owner === "main" || !requiresGithubAuth(candidate.record.delivery_mode)) continue;
    const status = environment.secondmates?.[candidate.owner]?.github_auth.status || "unknown";
    if (status === "available" || blockedSecondmateCredentials.has(candidate.owner)) continue;
    blockedSecondmateCredentials.add(candidate.owner);
    credentialBlockers.push({ owner: ownerRef(candidate.owner), status });
  }
  const executableReady = ready.filter(candidateExecutionAvailable);
  const recommendations = [];

  function recommend(id, classification, priority, evidence, consequence, boundary, nextAction, prompt) {
    recommendations.push({ id, classification, priority, evidence, expected_throughput_consequence: consequence, safety_authority_boundary: boundary, recommended_next_action: nextAction, prompt });
  }

  if (decisions.length > 0) recommend(
    "CAP-01", "captain-held decisions", 30,
    `${decisions.length} structured captain decision or hold${decisions.length === 1 ? "" : "s"} ${decisions.length === 1 ? "is" : "are"} open: ${decisions.slice(0, 4).map((item) => `${item.owner}/${item.key}`).join(", ")}.`,
    "Resolving the highest-dependency decision may release blocked work without adding execution load.",
    "Approval in chat re-enters decision-hold-lifecycle; the dashboard neither records nor applies an answer.",
    "Discuss or decide the listed holds, starting with the one that releases the most downstream work.",
    "Approve CAP-01: walk me through the open captain decisions in dependency order and route each answer through the normal decision lifecycle."
  );
  if (credentialBlockers.length > 0) recommend(
    "CAP-02", "credentials", 10,
    `${credentialBlockers.length} home-owned GitHub credential lane${credentialBlockers.length === 1 ? " is" : "s are"} blocking PR-bound work: ${credentialBlockers.map((blocker) => `${blocker.owner} (${blocker.status})`).join(", ")}.`,
    "PR discovery, push, and CI handoff may stop even when implementation capacity exists.",
    "Credential material must stay outside the dashboard; authentication is restored through the normal bootstrap flow.",
    "Restore GitHub authentication in the affected owning homes, then refresh /capacity before dispatching their PR-bound work.",
    "Approve CAP-02: guide me through restoring GitHub authentication in the listed owning homes, then refresh the capacity snapshot."
  );
  if (unavailable.length > 0) recommend(
    "CAP-03", "unavailable state", 20,
    `${unavailable.length} current-state surface${unavailable.length === 1 ? " is" : "s are"} unavailable: ${unavailable.slice(0, 5).map((item) => `${item.owner}/${item.id}`).join(", ")}.`,
    "Unknown state prevents safe overlap and dispatch decisions, reducing knowable throughput.",
    "Recovery must use the normal backend and stuck-crewmate or secondmate lifecycle; no endpoint is restarted here.",
    "Reconcile the unavailable state owners before treating apparent idle capacity as real.",
    "Approve CAP-03: reconcile the unavailable fleet state through the normal recovery lifecycle, then rerun /capacity."
  );
  if (definitionRows.length > 0) recommend(
    "CAP-04", "definition shortage", 60,
    `${definitionRows.length} queued item${definitionRows.length === 1 ? " lacks" : "s lack"} dispatch-grade definition; common gaps: ${[...new Set(definitionRows.flatMap((row) => row.gaps))].slice(0, 5).join(", ")}.`,
    "Clarifying scope, acceptance, project, and dependencies converts nominal backlog depth into meaningful ready supply.",
    "Clarification updates the normal backlog contract and does not authorize implementation or dispatch.",
    "Refine the highest-value underspecified items before adding more work or workers.",
    "Approve CAP-04: refine the highest-value definition gaps into dispatch-ready backlog items without starting implementation."
  );
  if (pipeline.blocked.length > 0 || overlapRows.length > 0) recommend(
    "CAP-05", overlapRows.length > 0 ? "overlap serialization" : "task dependencies and gates", 50,
    `${pipeline.blocked.length} item${pipeline.blocked.length === 1 ? " is" : "s are"} explicitly gated and ${overlapRows.length} item${overlapRows.length === 1 ? " is" : "s are"} conservatively serialized for coarse project overlap.`,
    "Landing dependencies or confirming non-overlapping subsystem boundaries can release independent starts safely.",
    "No overlap rule, dependency, time gate, approval, or safety boundary is weakened automatically.",
    "Review the highest-impact gate and only mark work independent when evidence supports it.",
    "Approve CAP-05: review the dependency and coarse-overlap gates, preserving safety, and identify any work that is truly independent."
  );
  if (executableReady.length > 0) recommend(
    "CAP-06", "execution shortage", 70,
    `${executableReady.length} useful item${executableReady.length === 1 ? " is" : "s are"} grounded, independently startable, and supported by an available execution lane: ${executableReady.slice(0, 5).map((item) => `${ownerRef(item.owner)}/${itemRef(item.owner, item.record.id)}`).join(", ")}.`,
    "Starting selected work increases meaningful flow without inventing work or targeting a utilization percentage.",
    "Chat approval re-enters project resolution, dispatch-profile selection, overlap checks, approval, and supervision; this run dispatches nothing.",
    "Choose one or more ready items to dispatch through the normal lifecycle.",
    "Approve CAP-06: dispatch the listed independently ready work through normal project resolution, profile selection, and supervision."
  );
  if (validationCards.length > 0 && (pipeline.validating_fixing.length > 0 || approvalReadyCards.length > 0)) recommend(
    "CAP-07", "validation, CI, or approval", 40,
    `${pipeline.validating_fixing.length} item${pipeline.validating_fixing.length === 1 ? " is" : "s are"} validating/fixing; ${approvalReadyCards.length} item${approvalReadyCards.length === 1 ? " is" : "s are"} approval-ready, and ${captainApprovalCards.length} require${captainApprovalCards.length === 1 ? "s" : ""} captain approval.`,
    "Clearing a terminal delivery stage returns finished value and removes overlap pressure before more starts.",
    "Never merge a red PR; merge and local-only authority remain unchanged, and no gate response is issued by the dashboard.",
    "Prioritize genuinely parked validation gates, failing CI, or authority-approved merge and local landing actions over adding overlapping work.",
    "Handle CAP-07: inspect the validation and PR/CI gates and advance only actions already authorized by the normal delivery lifecycle."
  );
  if (readinessComplete && ready.length === 0 && activeCount === 0 && definitionRows.length === 0 && pipeline.blocked.length === 0 && decisions.length === 0) recommend(
    "CAP-08", "demand shortage", 80,
    "No grounded ready work, active delivery, definition gaps, explicit gates, or captain decisions are visible in the bounded snapshot.",
    "Throughput is demand-limited; adding agents or keeping lanes busy would create artificial utilization, not value.",
    "New work must come from a captain-grounded goal or normal planning intake, never speculative busywork.",
    "Name the next valuable outcome or leave the fleet healthy and idle.",
    "Approve CAP-08: help me turn the next captain-grounded outcome into normal scoped backlog work; do not invent busywork."
  );
  const idleUsefulMates = mates.filter((mate) => mate.ready_in_scope > 0 && mate.active_children === 0 && mate.current !== "unknown");
  const blockedUsefulMates = mates.filter((mate) => mate.grounded_ready_in_scope > mate.ready_in_scope);
  const activeBlockedMates = mates.filter((mate) => activeRuntimeBlockedMates.has(mate.id));
  const laneRepairRelevant = laneMismatch && (ready.some((candidate) => candidate.owner === "main") || ephemeralActiveCount > 0);
  if (laneRepairRelevant || idleUsefulMates.length > 0 || blockedUsefulMates.length > 0 || activeBlockedMates.length > 0) recommend(
    "CAP-09", "lane mismatch", 25,
    `${availableLanes.length} configured ephemeral dispatch lane${availableLanes.length === 1 ? " is" : "s are"} executable; backend ${environment.backend.name} is ${environment.backend.available ? "available" : "unavailable"}; ${idleUsefulMates.length} idle secondmate${idleUsefulMates.length === 1 ? " has" : "s have"} executable in-scope work, ${blockedUsefulMates.length} ${blockedUsefulMates.length === 1 ? "has" : "have"} grounded work on an unavailable home-owned lane, and ${activeBlockedMates.length} active secondmate${activeBlockedMates.length === 1 ? " has" : "s have"} an unavailable home-owned runtime lane.`,
    "Correcting a real lane mismatch can release existing supply; idle secondmates with no matching work remain healthy.",
    "Quota is explicitly unobserved, scope routing still requires judgment, and no harness fallback or dispatch happens here.",
    "Repair unavailable configured lanes or route already-grounded in-scope work through the normal dispatcher.",
    "Approve CAP-09: inspect the configured lane mismatch and idle secondmate scope alignment without guessing quota or creating work."
  );
  if (aging.length > 0) recommend(
    "CAP-10", "aging flow", 35,
    `${aging.length} active, held, or approval-stage item${aging.length === 1 ? " has" : "s have"} been open at least seven days: ${aging.slice(0, 5).map((item) => `${item.owner}/${item.id} (${item.age_days}d)`).join(", ")}.`,
    "A targeted current-state check can distinguish healthy long work from a stalled flow before more overlapping starts.",
    "Age is a review signal, not proof of a stall; recovery or interruption requires normal evidence and lifecycle rules.",
    "Inspect current authoritative state and validation evidence for the oldest item first.",
    "Approve CAP-10: investigate the oldest active flow using current-state evidence, without interrupting healthy work by age alone."
  );

  // One observation per run: completed waits roll into the per-kind duration
  // history, live ones get an honest elapsed-vs-typical estimate (or "time
  // unknown" when no history exists for that kind yet).
  const waitElapsed = observeWaits(waitHistory, observedWaits, Math.floor(now / 1000), authoritativeWaitOwners);
  for (const { card, key, kind } of measurableWaits) {
    const estimate = estimateWait(waitElapsed.get(key) ?? 0, waitHistory.durations[kind]);
    card.wait.progress = { ...estimate, label: progressLabel(estimate) };
  }

  parked.sort((a, b) => `${a.owner}/${a.id}`.localeCompare(`${b.owner}/${b.id}`));
  recurring.sort((a, b) => (a.next_run || "").localeCompare(b.next_run || "") || `${a.owner}/${a.id}`.localeCompare(`${b.owner}/${b.id}`));
  recommendations.sort((a, b) => a.priority - b.priority || a.id.localeCompare(b.id));
  const primary = recommendations[0] || {
    id: null,
    classification: activeCount > 0 ? "healthy active flow" : "healthy idle",
    evidence: activeCount > 0 ? `${activeCount} active delivery item(s) and no stronger bottleneck signal.` : "No actionable capacity bottleneck is visible.",
  };
  for (const stage of STAGES) pipeline[stage].sort((a, b) => `${a.owner}/${a.id}`.localeCompare(`${b.owner}/${b.id}`));
  const activeIndependentKeys = new Set(
    [...pipeline.building, ...pipeline.validating_fixing, ...pipeline.pr_ci_approval].map((card) =>
      card.repo ? `project:${card.repo}` : `item:${card.id}`
    )
  );
  const liveAgents = liveAgentRollCall(snapshot);

  const model = {
    schema: "fm-capacity.v1",
    generated: snapshot.generated,
    dashboard_path: "private data/capacity-dashboard.html",
    provenance: {
      fleet: "bin/fm-fleet-snapshot.sh fm-fleet-snapshot.v1",
      freshness: "Fresh command observation on each normal invocation; status-log tails are historical only and never current-state authority.",
      secondmates: "Validated structured-home summaries with registered-table route metadata; fallback parent events never override readable home state.",
      decisions: "Structured backlog captain holds and keyed open-decision folds only; scout reports and visual artifacts are not scraped.",
      environment: "Authoritative backend functions, configured dispatch profiles, executable presence, and bootstrap-equivalent GitHub auth status; quota is not observed or guessed.",
      recent_landings: recentLandingsProvenance,
    },
    measures: {
      useful_ready_work: ready.length,
      independent_tasks_safe_to_start_now: executableReady.length,
      active_independent_work: activeIndependentKeys.size,
      waiting_work: pipeline.queued.length + pipeline.blocked.length + pipeline.pr_ci_approval.length,
      open_captain_actions: decisions.length + captainApprovalCards.length + captainGateCards.length,
      recently_landed: pipeline.recently_landed.length,
      recently_landed_complete: recentLandingsComplete,
    },
    primary_bottleneck: { id: primary.id, classification: primary.classification, evidence: primary.evidence },
    pipeline,
    parked,
    recurring,
    live_agents: liveAgents,
    lanes: {
      ephemeral_workers: {
        active: (snapshot.tasks || []).filter((task) => task.kind !== "secondmate" && ["working", "parked", "blocked", "paused"].includes(task.current_state?.state)).length,
        pool: "unbounded on demand - Firstmate has no fixed ephemeral pool or concurrency target",
        backend: environment.backend,
        github_auth: environment.github_auth,
        configured_dispatch: environment.dispatch,
      },
      persistent_secondmates: mates,
    },
    readiness: {
      queued_considered: queue.filter((record) => !isSuperseded(record) && !(activeHold(record, now) && record.hold_kind === "parked") && !recurringIds.has(`main/${record.id}`)).length + secondmateQueuedConsidered,
      grounded_candidates: readinessComplete ? candidates.length : 0,
      independent_start_count: executableReady.length,
      available: readinessComplete,
      definition_gaps: definitionRows,
      explicit_gates: blockedRows,
      conservative_overlap_gates: overlapRows,
    },
    aging,
    recommendations,
    omissions: [
      "No quota inference or utilization target is computed.",
      "Natural-language secondmate scopes and project names are withheld and not machine-guessed against main-home work.",
      "Backlog bodies are used only for bounded definition checks and are never rendered.",
      "Park reasons are withheld like every other hold reason; the authenticated dashboard service enriches them.",
      "Recurring schedule reasons are withheld like every other hold reason; the authenticated dashboard service enriches them and owns the run-now control.",
      "Status tails, terminal chat, scout report contents, and visual artifacts are not consulted.",
      ...(recentLandingsComplete ? [] : [recentLandingsProvenance]),
    ],
  };
  return {
    model: sanitizeDeep(model),
    captainActions: sanitizeDeep(decisions),
  };
}

function redact(value) {
  return String(value ?? "")
    .replace(/\b(?:sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,})\b/g, "[redacted secret]")
    .replace(/\b(?:Bearer\s+)[A-Za-z0-9._~+\/-]{8,}/gi, "Bearer [redacted]")
    .replace(/\b(?:token|api[_-]?key|password|secret)\s*[=:]\s*[^\s,;]+/gi, "$1=[redacted]")
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, "[redacted email]");
}

function sanitizeDeep(value) {
  if (typeof value === "string") return redact(value);
  if (Array.isArray(value)) return value.map(sanitizeDeep);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, sanitizeDeep(item)]));
  }
  return value;
}

function assertSafeParentPath(parent, protectedRoot = null) {
  const resolvedParent = path.resolve(parent);
  const resolvedRoot = path.resolve(protectedRoot || resolvedParent);
  const relative = path.relative(resolvedRoot, resolvedParent);
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error("dashboard parent must remain under the protected root");
  }
  const canonicalRoot = fs.realpathSync(resolvedRoot);
  const targets = relative.split(path.sep)
    .filter(Boolean)
    .reduce((paths, segment) => [...paths, path.join(paths.at(-1), segment)], [resolvedRoot])
    .slice(1);
  for (const target of targets) {
    try {
      if (fs.lstatSync(target).isSymbolicLink()) throw new Error("dashboard parent path must not contain a symlink");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  try {
    const canonicalParent = fs.realpathSync(resolvedParent);
    const canonicalRelative = path.relative(canonicalRoot, canonicalParent);
    if (canonicalRelative === ".." || canonicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(canonicalRelative)) {
      throw new Error("dashboard parent must remain under the canonical protected root");
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function writePrivateAtomic(destination, content, protectedRoot = null) {
  const parent = path.dirname(destination);
  assertSafeParentPath(parent, protectedRoot);
  fs.mkdirSync(parent, { recursive: true });
  assertSafeParentPath(parent, protectedRoot);
  try {
    if (fs.lstatSync(destination).isSymbolicLink()) throw new Error("dashboard destination must not be a symlink");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary = path.join(parent, `.${path.basename(destination)}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`);
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
    fs.writeFileSync(descriptor, content, "utf8");
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, destination);
    fs.chmodSync(destination, 0o600);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try {
      fs.unlinkSync(temporary);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
}

function h(value) {
  return redact(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}

function artifact(value) {
  if (!value) return "";
  const safe = redact(value);
  if (!/^(https:\/\/|\/|\.\/|data\/)/.test(safe)) return `<span class="path">${h(safe)}</span>`;
  return `<a href="${h(safe)}">${h(safe)}</a>`;
}

// Plain-language blocker context: the recursive chain plus the explicit
// captain action (or explicit nothing-to-do), rendered under a blocked row.
function blockedContext(card) {
  if (!card.waits_on || card.waits_on.length === 0) return "";
  const chain = card.waits_on.map((wait) => h(wait)).join("; ");
  const action = card.what_you_can_do ? `<small class="cando">What you can do: ${h(card.what_you_can_do)}</small>` : "";
  return `<small class="chain">${chain}.</small>${action}`;
}

// Honest progress affordance for a measurable wait. The visible text always
// carries the whole message, so the bar is never color-only information; the
// bar itself is exposed as a labeled progressbar (indeterminate when no honest
// percentage exists). Element sizes are fixed so a refresh never jumps layout.
function renderProgress(progress) {
  if (!progress || !progress.label) return "";
  const percent = progress.overrun ? 100 : progress.percent;
  const known = Number.isFinite(percent);
  const fill = known ? `<span class="wfill${progress.overrun ? " wfill-over" : ""}" style="width:${h(percent)}%"></span>` : "";
  const aria = Number.isFinite(progress.percent) ? ` aria-valuenow="${h(progress.percent)}"` : "";
  return `<span class="wprog"><span class="wbar${known ? "" : " wbar-unknown"}" role="progressbar" aria-valuemin="0" aria-valuemax="100"${aria} aria-label="${h(progress.label)}">${fill}</span><span class="wtext">${h(progress.label)}</span></span>`;
}

// Calm treatment for a self-clearing wait: plain-language copy, the honest
// progress affordance where one exists, and the chain retained as context.
function selfClearingContext(card) {
  const copy = card.wait?.copy || "Waiting on an automatic process - resumes by itself";
  const chain = card.waits_on?.length ? `<small class="chain">${card.waits_on.map((wait) => h(wait)).join("; ")}.</small>` : "";
  return `<small class="wait-self">${h(copy)}.</small>${renderProgress(card.wait?.progress)}${chain}`;
}

function waitContext(card) {
  return card.wait?.class === "self_clearing" ? selfClearingContext(card) : blockedContext(card);
}

function manifestRow(card) {
  const meta = [card.kind, card.age_days !== null && card.age_days !== undefined ? `${card.age_days}d` : null]
    .filter(Boolean).map((part) => h(part)).join(" · ");
  return `<li class="mrow">
    <span class="mid"><span class="item-id">${h(card.id)}</span><span class="mowner">${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span></span>
    <span class="mreason">${h(card.reason || "No additional gate detail.")}${card.artifact ? ` ${artifact(card.artifact)}` : ""}${waitContext(card)}</span>
    <span class="mmeta">${meta}</span>
  </li>`;
}

function severityFor(model) {
  if (!model.primary_bottleneck.id) return "good";
  const priority = model.recommendations.find((rec) => rec.id === model.primary_bottleneck.id)?.priority;
  if (priority === undefined) return "info";
  if (priority <= 20) return "critical";
  if (priority <= 40) return "serious";
  if (priority <= 70) return "info";
  return "neutral";
}

function copyPrompt(rec) {
  return `<div class="prompt"><code>${h(rec.prompt)}</code><button type="button" data-copy="${h(rec.prompt)}" aria-label="Copy ${h(rec.id)} follow-up prompt">Copy prompt</button></div>`;
}

function renderHtml(model, captainActions) {
  const severity = severityFor(model);
  const primaryRec = model.recommendations.find((rec) => rec.id === model.primary_bottleneck.id) || null;
  const working = model.pipeline.building.length + model.pipeline.validating_fixing.length;
  const gatesCount = model.pipeline.pr_ci_approval.length;
  const readyCount = model.pipeline.ready.length;
  const queuedCount = model.pipeline.queued.length;
  const blockedCount = model.pipeline.blocked.length;
  const waiting = queuedCount + readyCount + gatesCount + blockedCount;
  const total = working + waiting;
  const liveAgentRows = (model.live_agents?.records || []).map((record) => {
    const task = /^item-\d{2,}$/.test(record.task)
      ? `<span class="item-id">${h(record.task)}</span>`
      : h(record.task);
    return `<li class="agent-row">
      <span class="agent-name"><strong>${h(record.agent)}</strong><small>${h(record.home)}</small></span>
      <span class="agent-task">${task}</span>
      <span class="agent-activity activity-${h(record.activity)}"><strong>${h(record.label)}</strong><small>${h(record.detail)}</small></span>
      <time datetime="${h(record.as_of)}">${h(record.as_of)}</time>
    </li>`;
  }).join("") || `<li class="empty">No live workers or supervisors are recorded.</li>`;

  const captainDecisionCards = model.pipeline.blocked.filter((card) => card.reason === "Captain hold");
  const captainApprovalCards = model.pipeline.pr_ci_approval.filter((card) => card.captain_approval_required === true);
  const captainGateCards = model.pipeline.blocked.filter((card) => card.captain_gate === true);
  const otherBlockedCards = model.pipeline.blocked.filter((card) => card.reason !== "Captain hold" && card.wait?.class !== "self_clearing" && card.captain_gate !== true);
  const selfClearingBlocked = model.pipeline.blocked.filter((card) => card.wait?.class === "self_clearing");
  const selfWaitCards = [
    ...model.pipeline.validating_fixing.filter((card) => card.wait?.class === "self_clearing"),
    ...selfClearingBlocked,
  ];
  const needsYouCount = model.measures.open_captain_actions;
  // Every needs-you row carries a data-your-go-ref validation anchor (with its
  // row flavor in data-your-go-kind), like data-parked-ref and
  // data-recurring-ref: rows stay identity-opaque here, and the authenticated
  // dashboard service resolves the anchors to render real interaction
  // controls for every item awaiting the captain.
  const needsYouRows = [
    ...captainApprovalCards.map((card) => `<li data-your-go-ref="${h(card.id)}" data-your-go-kind="approval"><span class="verb verb-approve">Approve</span><span class="who"><span class="item-id">${h(card.id)}</span> ${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span><span class="why">Finished work is ready for your approval.</span></li>`),
    ...captainGateCards.map((card) => `<li data-your-go-ref="${h(card.id)}" data-your-go-kind="review"><span class="verb verb-review">Review</span><span class="who"><span class="item-id">${h(card.id)}</span> ${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span><span class="why">Paused work is waiting on you, not an automatic process.${blockedContext(card)}</span></li>`),
    ...captainActions.map((action) => `<li data-your-go-ref="${h(action.key)}" data-your-go-kind="decision"><span class="verb verb-decide">Decide</span><span class="who"><span class="item-id">${h(action.key)}</span> ${h(action.owner)} · work ${h(action.task)}</span><span class="why">${h(action.reason)}</span></li>`),
  ].join("");
  const blockedRows = otherBlockedCards.map((card) => `<li><span class="verb verb-blocked">Stuck</span><span class="who"><span class="item-id">${h(card.id)}</span> ${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span><span class="why">${h(card.reason || "Unspecified gate")}${blockedContext(card)}</span></li>`).join("");
  const blockedShownElsewhere = blockedCount - otherBlockedCards.length;
  const blockedSummary = `${blockedRows}${blockedShownElsewhere > 0
    ? `<li class="empty">${h(blockedShownElsewhere)} blocked item${blockedShownElsewhere === 1 ? " is" : "s are"} already shown under Needs You or automatic waits.</li>`
    : blockedRows ? "" : `<li class="empty">No current work is blocked.</li>`}`;

  const blockedReasonCounts = new Map();
  for (const card of otherBlockedCards) {
    const reason = (card.reason || "unspecified gate").toLowerCase();
    blockedReasonCounts.set(reason, (blockedReasonCounts.get(reason) || 0) + 1);
  }
  const captainHeldWaiting = captainDecisionCards.length + captainGateCards.length;
  const approvalReadyCount = model.pipeline.pr_ci_approval.filter((card) => card.approval_ready === true).length;
  const whys = [
    ...(captainHeldWaiting ? [{ tone: "decide", count: captainHeldWaiting, label: "held for your decision", detail: "" }] : []),
    { tone: "blocked", count: otherBlockedCards.length, label: "blocked", detail: [...blockedReasonCounts.entries()].map(([reason, count]) => `${count} ${reason}`).join(" · ") },
    { tone: "self", count: selfClearingBlocked.length, label: "waiting on their own", detail: "resume automatically - no action needed" },
    { tone: "gates", count: gatesCount, label: "at delivery gates", detail: approvalReadyCount ? `${approvalReadyCount} ready for approval` : "validation or CI under way" },
    { tone: "ready", count: readyCount, label: "ready, not yet started", detail: "waiting on dispatch" },
    { tone: "queued", count: queuedCount, label: "not ready", detail: [model.readiness.definition_gaps.length ? `${model.readiness.definition_gaps.length} definition gap${model.readiness.definition_gaps.length === 1 ? "" : "s"}` : "", model.readiness.conservative_overlap_gates.length ? `${model.readiness.conservative_overlap_gates.length} serialized for overlap` : ""].filter(Boolean).join(" · ") },
  ].filter((why) => why.count > 0);
  const whyHtml = whys.length
    ? `<div class="whys"><h3>Why it waits</h3><ul>${whys.map((why) => `<li><span class="why-n why-${why.tone}">${h(why.count)}</span><span class="why-l">${h(why.label)}${why.detail ? `<small>${h(why.detail)}</small>` : ""}</span></li>`).join("")}</ul></div>`
    : "";
  const meterBar = total === 0
    ? `<p class="empty">No current work items are in the pipeline.</p>`
    : `<div class="meterbar" role="img" aria-label="${h(`${working} working and ${waiting} waiting of ${total} current items`)}">${working ? `<span class="m-working" style="flex-grow:${working}"></span>` : ""}${waiting ? `<span class="m-waiting" style="flex-grow:${waiting}"></span>` : ""}</div>`;

  const selfWaitRows = selfWaitCards.map((card) => `<li><span class="verb verb-waiting">Waiting</span><span class="who"><span class="item-id">${h(card.id)}</span> ${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span><span class="why">${selfClearingContext(card)}</span></li>`).join("");
  const selfWaitBand = selfWaitCards.length ? `<section class="band band-selfwait" aria-labelledby="selfwait-title"><div class="wrap">
      <p class="kicker">Waiting on automatic processes</p>
      <div class="rollcall selfwait-items" id="selfwait-items">
        <h2 id="selfwait-title"><span class="n">${h(selfWaitCards.length)}</span> running or waiting on their own - no action needed</h2>
        <ul>${selfWaitRows}</ul>
      </div>
    </div></section>` : "";

  const manifest = STAGES.map((stage) => `<section class="stage-group" aria-labelledby="stage-${stage}">
    <h3 id="stage-${stage}" class="stage-h"><span class="stage-n${stage === "blocked" && model.pipeline.blocked.length ? " stage-n-alarm" : ""}">${model.pipeline[stage].length}</span>${h(STAGE_LABELS[stage])}</h3>
    ${model.pipeline[stage].length ? `<ul class="mlist">${model.pipeline[stage].map(manifestRow).join("")}</ul>` : `<p class="empty">None.</p>`}
  </section>`).join("");

  const mateRows = model.lanes.persistent_secondmates.map((mate) => {
    const laneCount = (mate.runtime.dispatch.lanes || []).filter((lane) => lane.available).length;
    const tone = mate.utilization.startsWith("healthy") || mate.utilization.startsWith("active on") ? "ok"
      : mate.utilization.includes("unavailable") ? "bad" : "warn";
    return `<li class="lane-row"><span class="dot dot-${tone}" aria-hidden="true"></span><span><strong>${h(mate.id)}</strong> · ${h(mate.utilization)} · ${h(mate.active_children)} active, ${h(mate.ready_in_scope)} startable now · backend ${h(mate.runtime.backend.name)} ${mate.runtime.backend.available ? "up" : "down"}, auth ${h(mate.runtime.github_auth.status)}, ${h(laneCount)} lane${laneCount === 1 ? "" : "s"} · ${h(mate.scope)}</span></li>`;
  }).join("") || `<li class="empty">No persistent secondmates are registered.</li>`;

  const dispatchRows = (model.lanes.ephemeral_workers.configured_dispatch.lanes || []).map((lane) => `<li class="lane-row"><span class="dot dot-${lane.available ? "ok" : "bad"}" aria-hidden="true"></span><span><strong>${h(lane.harness)}${lane.model ? ` / ${h(lane.model)}` : ""}${lane.effort ? ` (${h(lane.effort)})` : ""}</strong> · ${lane.available ? "available" : "unavailable"} · ${h(lane.when)} · ${h(lane.availability_evidence)}</span></li>`).join("") || `<li class="empty">No usable dispatch lanes were resolved.</li>`;

  const secondaryRecs = model.recommendations.filter((rec) => rec.id !== model.primary_bottleneck.id);
  const recs = secondaryRecs.map((rec) => `<article class="rec" id="${h(rec.id)}">
    <p class="rec-line"><span class="action-id">${h(rec.id)}</span><strong>${h(rec.classification)}</strong></p>
    <p class="rec-evidence">${h(rec.evidence)}</p>
    <p class="rec-next">&rarr; ${h(rec.recommended_next_action)}</p>
    <p class="rec-fine">${h(rec.expected_throughput_consequence)} ${h(rec.safety_authority_boundary)}</p>
    ${copyPrompt(rec)}
  </article>`).join("") || `<p class="empty">No further capacity action is recommended. Healthy idle is acceptable.</p>`;

  const gaps = model.readiness.definition_gaps.map((row) => `<li><strong>${h(`${row.owner}/${row.id}`)}</strong><span>${h(row.gaps.join("; "))}</span></li>`).join("") || `<li><strong>None</strong><span>No definition gaps detected in the bounded queue.</span></li>`;
  const landed = model.pipeline.recently_landed.map((card) => `<li><strong>${h(`${card.owner}/${card.id}`)}</strong><span>${h(card.reason)}</span>${card.artifact ? artifact(card.artifact) : ""}</li>`).join("") || `<li><strong>None</strong><span>No recent completions are in the bounded baseline.</span></li>`;

  // Recurring: scheduled cadence work rendered once in one calm section -
  // healthy and on schedule, never in the blocked band - and absent entirely
  // when nothing recurs. Rows stay identity-opaque here; the authenticated
  // service enriches them and adds the run-now control. data-recurring-ref is
  // the service's validation anchor, data-next-run carries the gate date, and
  // data-last-run-ref points at the prior completed run's record.
  const monthDay = (date) => {
    const parsed = new Date(`${date}T00:00:00Z`);
    return Number.isNaN(parsed.getTime())
      ? date
      : `${["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][parsed.getUTCMonth()]} ${parsed.getUTCDate()}`;
  };
  const recurringRows = model.recurring.map((card) => `<li class="mrow" data-recurring-ref="${h(card.id)}" data-next-run="${h(card.next_run)}"${card.last_run ? ` data-last-run-ref="${h(card.last_run.ref)}"` : ""}>
    <span class="mid"><span class="item-id">${h(card.id)}</span><span class="mowner">${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span></span>
    <span class="mreason"><span class="recurring-copy">${h(card.reason)}.</span>${card.last_run ? `<small class="chain">Last run ${h(card.last_run.ref)}${card.last_run.date ? ` completed ${h(card.last_run.date)}` : " completed"}${card.last_run.artifact_recorded ? "; its delivered artifact is on the books" : ""}.</small>` : ""}</span>
    <span class="mmeta"><span class="recurring-next">next: ${h(monthDay(card.next_run))}</span>${card.scheduled_since ? `<small class="recurring-since">on the books since ${h(card.scheduled_since)}</small>` : ""}</span>
  </li>`).join("");
  const recurringBand = model.recurring.length ? `<section class="band band-quiet band-recurring" aria-labelledby="recurring-title"><div class="wrap">
      <h2 class="qhead" id="recurring-title">Recurring (${h(model.recurring.length)}) · scheduled cadence work, healthy and on schedule</h2>
      <ul class="mlist">${recurringRows}</ul>
    </div></section>` : "";

  // Parking lot: captain-parked work rendered once, low-key, collapsed by
  // default, and entirely absent when nothing is parked. Rows stay
  // identity-opaque here; the authenticated service enriches them and adds the
  // unpark control. data-parked-ref is the service's validation anchor.
  const parkedRows = model.parked.map((card) => `<li class="mrow" data-parked-ref="${h(card.id)}">
    <span class="mid"><span class="item-id">${h(card.id)}</span><span class="mowner">${h(card.owner)}${card.repo ? ` · ${h(card.repo)}` : ""}</span></span>
    <span class="mreason"><span class="parked-copy">${h(card.reason)}.</span></span>
    <span class="mmeta">${card.parked_since ? `on the books since ${h(card.parked_since)}` : ""}</span>
  </li>`).join("");
  const parkingLot = model.parked.length ? `<section class="band band-quiet band-parking" aria-label="Parking lot"><div class="wrap">
      <details class="parking">
        <summary>Parking lot (${h(model.parked.length)}) · parked at your request, resting outside the active pipeline</summary>
        <ul class="mlist">${parkedRows}</ul>
      </details>
    </div></section>` : "";

  const alarmTail = primaryRec
    ? `<p class="next">&rarr; <strong>Next:</strong> ${h(primaryRec.recommended_next_action)}</p>
      ${copyPrompt(primaryRec)}
      <p class="fine">${h(primaryRec.expected_throughput_consequence)} ${h(primaryRec.safety_authority_boundary)}</p>`
    : "";

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark light">
  <title>Firstmate capacity dashboard</title>
  <style>
    :root{color-scheme:dark;--bg:#0d0d0d;--ink:#ffffff;--ink2:#c3c2b7;--muted:#898781;--hair:#2c2c2a;--line:rgba(255,255,255,.10);--blue:#3987e5;--good:#0ca30c;--warn:#fab219;--serious:#ec835a;--crit:#d03b3b;--gray:#52514e;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
    @media(prefers-color-scheme: light){:root{color-scheme:light;--bg:#f9f9f7;--ink:#0b0b0b;--ink2:#52514e;--muted:#66645f;--hair:#e1e0d9;--line:rgba(11,11,11,.10);--blue:#1b5fae;--good:#087708;--warn:#8a6200;--serious:#a54824;--crit:#ae2525;--gray:#c3c2b7}}
    .sev-critical{--sev:var(--crit)}.sev-serious{--sev:var(--serious)}.sev-info{--sev:var(--blue)}.sev-neutral{--sev:var(--muted)}.sev-good{--sev:var(--good)}
    *{box-sizing:border-box}html{background:var(--bg)}
    body{margin:0;color:var(--ink);background:var(--bg);line-height:1.45;overflow-wrap:anywhere}
    a{color:var(--blue);text-underline-offset:.18em}button,a{outline-offset:3px}button:focus-visible,a:focus-visible{outline:3px solid var(--blue)}
    .skip{position:absolute;left:-9999px}.skip:focus{left:1rem;top:1rem;z-index:10;background:var(--ink);color:var(--bg);padding:.7rem 1rem}
    h1,h2,h3,p,ul{margin:0}ul{padding:0;list-style:none}
    .sevbar{height:.7rem;background:var(--sev)}
    .band{padding:clamp(1.5rem,4vw,3.25rem) clamp(1rem,6vw,5rem)}
    .wrap{max-width:70rem;margin-left:auto;margin-right:auto}
    .band-alarm{background:color-mix(in srgb,var(--sev) 13%,var(--bg));border-bottom:1px solid var(--line)}
    .kicker{display:flex;justify-content:space-between;align-items:baseline;gap:1rem;flex-wrap:wrap;color:var(--sev);font-weight:800;letter-spacing:.16em;text-transform:uppercase;font-size:.76rem}
    .kicker .stamp{color:var(--muted);letter-spacing:.02em;text-transform:none;font-weight:400;font-size:.76rem;text-align:right}
    .band .kicker{margin-bottom:.6rem}
    .headline{font-size:clamp(2.4rem,7vw,4.6rem);font-weight:800;letter-spacing:-.03em;line-height:.98}
    .headline::first-letter{text-transform:uppercase}
    .evidence{font-size:clamp(1.02rem,2vw,1.3rem);color:var(--ink2);max-width:75ch;margin-top:1rem}
    .action-id{border:1px solid var(--sev,var(--muted));color:var(--sev,var(--ink));padding:.1rem .55rem;font:700 .72rem ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.04em;vertical-align:middle;margin-left:.5rem}
    .rollcall{margin-top:2.25rem}
    .rollcall h2{font-size:.76rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase;display:flex;align-items:baseline;gap:.6rem}
    .rollcall h2 .n{font-size:2.1rem;letter-spacing:0;line-height:1}
    .needs-you h2{color:var(--serious)}.blocked-items h2{color:var(--crit)}
    .rollcall ul{margin-top:.6rem}
    .rollcall li{display:grid;grid-template-columns:5.2rem minmax(0,.45fr) minmax(0,1fr);gap:.4rem 1.1rem;align-items:baseline;border-top:1px solid color-mix(in srgb,var(--sev) 30%,var(--hair));padding:.55rem 0;font-size:1.02rem;min-width:0}
    .rollcall li.empty{display:block}
    .verb{font-weight:800;text-transform:uppercase;letter-spacing:.08em;font-size:.72rem}
    .verb-approve{color:var(--blue)}.verb-decide{color:var(--serious)}.verb-review{color:var(--serious)}.verb-blocked{color:var(--crit)}
    .who{font-weight:650;min-width:0}.who .item-id{margin-right:.35rem}
    .why{color:var(--ink2);font-size:.92rem;min-width:0}
    .chain{display:block;color:var(--muted);font-size:.8rem;margin-top:.25rem}
    .cando{display:block;color:var(--ink);font-size:.8rem;font-weight:650;margin-top:.15rem}
    .band-selfwait{border-bottom:1px solid var(--line)}
    .band-selfwait .kicker{color:var(--good)}
    .selfwait-items{margin-top:0}
    .selfwait-items h2{color:var(--good)}
    .selfwait-items li{border-top:1px solid var(--hair)}
    .verb-waiting{color:var(--good)}
    .wait-self{display:block;color:var(--ink2);font-size:.85rem;margin-top:.25rem}
    .wprog{display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;margin-top:.35rem;min-height:1rem}
    .wbar{flex:0 1 9rem;min-width:4rem;height:.5rem;background:var(--hair);overflow:hidden}
    .wfill{display:block;height:100%;background:var(--good)}
    .wfill-over{background:var(--warn)}
    .wbar-unknown{background:repeating-linear-gradient(90deg,var(--hair) 0 .4rem,transparent .4rem .8rem)}
    .wtext{font-size:.78rem;color:var(--ink2);min-width:0}
    .item-id{font:700 .82rem ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink)}
    .next{margin-top:2rem;font-size:clamp(1.05rem,1.8vw,1.25rem)}
    .prompt{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:.7rem;align-items:center;margin-top:.9rem;border:1px solid var(--line);padding:.65rem .8rem;background:color-mix(in srgb,var(--bg) 55%,transparent)}
    .prompt code{font-size:.78rem;white-space:normal;color:var(--ink2);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    .prompt button{border:1px solid var(--ink);background:var(--ink);color:var(--bg);font-weight:700;padding:.5rem .9rem;cursor:pointer;font-size:.82rem}
    .fine{color:var(--muted);font-size:.76rem;margin-top:.8rem;max-width:100ch}
    .band-meter .kicker{color:var(--muted)}
    .split{display:flex;align-items:baseline;gap:1rem 2.75rem;flex-wrap:wrap;margin-top:.5rem}
    .split .pair{display:flex;align-items:baseline;gap:.75rem}
    .split .num{font-size:clamp(3rem,8vw,5.5rem);font-weight:850;line-height:1;letter-spacing:-.03em}
    .num-working{color:var(--good)}
    .split .lbl{font-size:1rem;color:var(--ink2);text-transform:uppercase;letter-spacing:.14em;font-weight:700}
    .split .of{color:var(--muted);font-size:.9rem}
    .meterbar{display:flex;gap:3px;height:2.9rem;margin-top:1.4rem}
    .m-working{background:var(--good)}.m-waiting{background:var(--gray)}
    .whys{margin-top:1.6rem}
    .whys h3{font-size:.76rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase;color:var(--muted)}
    .whys ul{display:flex;flex-wrap:wrap;gap:1.1rem 2.75rem;margin-top:.8rem}
    .whys li{display:flex;align-items:baseline;gap:.65rem;min-width:0}
    .why-n{font-size:1.9rem;font-weight:800;line-height:1}
    .why-decide{color:var(--serious)}.why-blocked{color:var(--crit)}.why-self{color:var(--good)}.why-gates{color:var(--warn)}.why-ready{color:var(--blue)}.why-queued{color:var(--muted)}
    .why-l{font-size:.92rem;color:var(--ink2)}.why-l small{display:block;color:var(--muted);font-size:.76rem}
    .band-agents{border-bottom:1px solid var(--line)}
    .band-agents .kicker{color:var(--good)}
    .agents-note{color:var(--ink2);font-size:.9rem;max-width:78ch;margin-top:.35rem}
    .agents-head,.agent-row{display:grid;grid-template-columns:minmax(8rem,.7fr) minmax(12rem,1.25fr) minmax(11rem,1fr) minmax(11rem,.8fr);gap:.5rem 1.25rem;align-items:baseline;min-width:0}
    .agents-head{margin-top:1.2rem;color:var(--muted);font-size:.7rem;font-weight:800;letter-spacing:.12em;text-transform:uppercase}
    .agent-row{border-top:1px solid var(--hair);padding:.65rem 0}
    .agent-row>*{min-width:0}
    .agent-name strong,.agent-activity strong{display:block}
    .agent-name small,.agent-activity small{display:block;color:var(--muted);font-size:.75rem;margin-top:.15rem}
    .agent-task{font-weight:650}
    .agent-activity strong{color:var(--ink2)}
    .activity-working strong{color:var(--good)}.activity-validating strong{color:var(--blue)}.activity-waiting_on_ci strong{color:var(--warn)}.activity-waiting_on_decision strong{color:var(--serious)}.activity-unavailable strong{color:var(--crit)}
    .agent-row time{color:var(--muted);font-size:.76rem}
    .band-quiet{border-top:1px solid var(--line);font-size:.88rem}
    .qhead{font-size:.76rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase;color:var(--muted);border-bottom:1px solid var(--hair);padding-bottom:.45rem;margin-top:2.4rem}
    .band-quiet>.qhead:first-child{margin-top:0}
    .rec{border-bottom:1px solid var(--hair);padding:1rem 0;max-width:70rem}
    .rec-line strong{font-size:1rem}.rec-line strong::first-letter{text-transform:uppercase}
    .rec-line .action-id{margin-left:0;margin-right:.6rem;--sev:var(--muted)}
    .rec-evidence{color:var(--ink2);margin-top:.35rem;max-width:90ch}
    .rec-next{margin-top:.35rem;font-weight:650}
    .rec-fine{color:var(--muted);font-size:.76rem;margin-top:.4rem;max-width:100ch}
    .stage-group{margin-top:1.4rem}
    .stage-h{display:flex;align-items:baseline;gap:.6rem;font-size:.74rem;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
    .stage-n{font-size:1.35rem;letter-spacing:0;color:var(--ink)}
    .stage-n-alarm{color:var(--crit)}
    .mlist{margin-top:.4rem}
    .mrow{display:grid;grid-template-columns:minmax(11rem,.4fr) minmax(0,1fr) auto;gap:.3rem 1.25rem;border-top:1px solid var(--hair);padding:.45rem 0;align-items:baseline;min-width:0}
    .mid{min-width:0}.mowner{color:var(--muted);font-size:.78rem;margin-left:.5rem}
    .mreason{color:var(--ink2);min-width:0}
    .mmeta{color:var(--muted);font-size:.76rem;text-align:right}
    .lanes-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:0 3rem}
    .lanes-grid h3{font-size:.8rem;color:var(--ink2);margin-top:1.1rem;text-transform:uppercase;letter-spacing:.1em}
    .lane-row{display:flex;gap:.6rem;align-items:baseline;border-top:1px solid var(--hair);padding:.5rem 0;color:var(--ink2);min-width:0;margin-top:.4rem}
    .dot{flex:none;width:.6rem;height:.6rem;border-radius:50%;align-self:center}
    .dot-ok{background:var(--good)}.dot-bad{background:var(--crit)}.dot-warn{background:var(--warn)}
    .appendix{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:0 3rem}
    .appendix h3{font-size:.8rem;color:var(--ink2);margin-top:1.1rem;text-transform:uppercase;letter-spacing:.1em}
    .clean-list{margin-top:.4rem}
    .clean-list li{display:grid;grid-template-columns:minmax(8rem,.4fr) minmax(0,1fr);gap:.75rem;border-top:1px solid var(--hair);padding:.45rem 0;min-width:0}
    .clean-list li>*{min-width:0}.clean-list span{color:var(--ink2)}
    .artifact,.path{font:500 .76rem ui-monospace,SFMono-Regular,Menlo,monospace;max-width:100%;overflow-wrap:anywhere}
    .empty{color:var(--muted);font-style:italic;border-top:1px solid var(--hair);padding-top:.45rem;margin-top:.4rem}
    .band-recurring{padding-bottom:1.4rem}
    .recurring-copy{color:var(--ink2)}
    .recurring-next{display:inline-block;color:var(--blue);font:700 .78rem ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.04em;border:1px solid color-mix(in srgb,var(--blue) 45%,var(--hair));padding:.1rem .5rem;white-space:nowrap}
    .recurring-since{display:block;color:var(--muted);font-size:.72rem;margin-top:.25rem}
    .band-parking{padding-top:0}
    .parking summary{cursor:pointer;color:var(--muted);font-size:.74rem;font-weight:800;letter-spacing:.12em;text-transform:uppercase;padding:.5rem 0;border-top:1px solid var(--hair)}
    .parking summary::marker{color:var(--muted)}
    .parking .mreason,.parked-copy{color:var(--muted)}
    footer{padding:1.4rem clamp(1rem,6vw,5rem) 2rem;color:var(--muted);border-top:1px solid var(--line);font-size:.76rem}
    footer p{max-width:70rem;margin:.3rem auto}
    @media(max-width:760px){.band{padding:1.25rem 1rem}.rollcall li{grid-template-columns:4.4rem minmax(0,1fr)}.rollcall li .why{grid-column:2}.split{gap:.75rem 1.5rem}.split .num{font-size:2.6rem}.whys ul{gap:.9rem 1.5rem}.agents-head{display:none}.agent-row{grid-template-columns:minmax(7rem,.55fr) minmax(0,1fr)}.agent-activity,.agent-row time{grid-column:2}.mrow{grid-template-columns:minmax(0,1fr)}.mmeta{text-align:left}.lanes-grid,.appendix{grid-template-columns:1fr}.prompt{grid-template-columns:1fr}.prompt button{width:100%}.kicker{display:block}.kicker .stamp{display:block;text-align:left;margin-top:.3rem}}
    @media print{body,html{background:#fff;color:#111}.band-alarm{background:#fff}.prompt button{display:none}a{color:#0645ad}}
  </style>
</head>
<body class="sev-${severity}">
  <a class="skip" href="#main">Skip to dashboard</a>
  <div class="sevbar" aria-hidden="true"></div>
  <main id="main">
    <section class="band band-alarm" aria-labelledby="headline"><div class="wrap">
      <p class="kicker"><span>Primary bottleneck${model.primary_bottleneck.id ? `<span class="action-id">${h(model.primary_bottleneck.id)}</span>` : ""}</span><span class="stamp">Fleet capacity · generated ${h(model.generated)}</span></p>
      <h1 class="headline" id="headline">${h(model.primary_bottleneck.classification)}</h1>
      <p class="evidence">${h(primaryRec ? primaryRec.evidence : model.primary_bottleneck.evidence)}</p>
      <div class="rollcall needs-you" id="needs-you">
        <h2><span class="n">${h(needsYouCount)}</span> need${needsYouCount === 1 ? "s" : ""} you</h2>
        <ul>${needsYouRows || `<li class="empty">Nothing is waiting on your decision or approval.</li>`}</ul>
      </div>
      <div class="rollcall blocked-items" id="blocked-items">
        <h2><span class="n">${h(blockedCount)}</span> blocked total</h2>
        <ul>${blockedSummary}</ul>
      </div>
      ${alarmTail}
    </div></section>
    ${selfWaitBand}
    <section class="band band-meter" aria-labelledby="meter-title"><div class="wrap">
      <p class="kicker">Working vs waiting</p>
      <h2 class="split" id="meter-title">
        <span class="pair"><span class="num num-working">${h(working)}</span><span class="lbl">working</span></span>
        <span class="pair"><span class="num">${h(waiting)}</span><span class="lbl">waiting</span></span>
        <span class="of">of ${h(total)} current item${total === 1 ? "" : "s"}</span>
      </h2>
      ${meterBar}
      ${whyHtml}
    </div></section>
    <section class="band band-agents" aria-labelledby="live-agents-title"><div class="wrap">
      <p class="kicker"><span>Live agents</span><span class="stamp">Reading generated ${h(model.live_agents?.generated || model.generated)}</span></p>
      <h2 id="live-agents-title">What every agent is doing now</h2>
      <p class="agents-note">Each row is a single bounded reading. Use Refresh capacity for a fresh reading; a file opened directly stays at the time shown here.</p>
      <div class="agents-head" aria-hidden="true"><span>Agent</span><span>Task</span><span>Current activity</span><span>As of</span></div>
      <ul class="agents-list">${liveAgentRows}</ul>
    </div></section>
    <section class="band band-quiet" aria-label="Reference detail"><div class="wrap">
      <h2 class="qhead">Also recommended · ranked by priority</h2>
      ${recs}
      <h2 class="qhead">Manifest · every current item by stage</h2>
      ${manifest}
      <h2 class="qhead">Lanes</h2>
      <div class="lanes-grid">
        <div><h3>Ephemeral dispatch lanes</h3><p class="fine">Created on demand: ${h(model.lanes.ephemeral_workers.pool)}. Runtime backend ${h(model.lanes.ephemeral_workers.backend.name)}: ${h(model.lanes.ephemeral_workers.backend.evidence)}. GitHub auth ${h(model.lanes.ephemeral_workers.github_auth.status)}.</p><ul>${dispatchRows}</ul></div>
        <div><h3>Persistent secondmates</h3><p class="fine">Healthy when idle unless grounded in-scope work is already ready.</p><ul>${mateRows}</ul></div>
      </div>
      <h2 class="qhead">Definition health and landed context</h2>
      <div class="appendix">
        <div><h3>Backlog definition gaps</h3><ul class="clean-list">${gaps}</ul></div>
        <div><h3>Recently landed${model.measures.recently_landed_complete ? "" : " (observed; incomplete)"}</h3><ul class="clean-list">${landed}</ul></div>
      </div>
    </div></section>
    ${recurringBand}
    ${parkingLot}
  </main>
  <footer><p>Provenance: ${h(model.provenance.fleet)}. ${h(model.provenance.decisions)} ${h(model.provenance.environment)}</p><p>This private dashboard contains bounded operational metadata only. It uses no CDN, remote asset, analytics, network service, or Lavish integration.</p></footer>
  <script>
    document.querySelectorAll('[data-copy]').forEach((button) => button.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(button.dataset.copy); button.textContent = 'Copied'; }
      catch { button.textContent = 'Select prompt'; }
    }));
  </script>
</body>
</html>`;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const snapshot = gatherSnapshot(opts.snapshot);
  reconcilePullRequests(snapshot, opts.snapshot ? (snapshot.pr_reconciliation || {}) : null);
  const environment = normalizeEnvironment(opts.environment ? readJson(opts.environment, "environment fixture") : liveEnvironment(snapshot));
  const defaultOutput = path.join(snapshot.roots?.data || path.join(snapshot.fm_home || ROOT, "data"), "capacity-dashboard.html");
  const output = path.resolve(opts.output || defaultOutput);
  const allowedData = path.resolve(snapshot.roots?.data || path.join(snapshot.fm_home || ROOT, "data"));
  const outputRelative = path.relative(allowedData, output);
  if (!outputRelative || outputRelative.startsWith(`..${path.sep}`) || path.isAbsolute(outputRelative)) {
    throw new Error("dashboard path must stay inside the effective data directory");
  }
  const waitHistoryPath = path.join(allowedData, "capacity-wait-history.json");
  if (output === waitHistoryPath) {
    throw new Error("dashboard path must not replace the capacity wait history");
  }
  let refsPath = null;
  if (opts.refs) {
    const allowedState = path.resolve(snapshot.roots?.state || path.join(snapshot.fm_home || ROOT, "state"));
    refsPath = path.resolve(opts.refs);
    const insideOf = (root) => {
      const relative = path.relative(root, refsPath);
      return relative && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
    };
    if (!insideOf(allowedState) && !insideOf(allowedData)) {
      throw new Error("refs sidecar path must stay inside the effective state or data directory");
    }
    if (refsPath === waitHistoryPath) {
      throw new Error("refs sidecar path must not replace the capacity wait history");
    }
  }
  const waitHistory = loadWaitHistory(waitHistoryPath);
  const { model, captainActions } = classify(snapshot, environment, waitHistory);
  writePrivateAtomic(output, renderHtml(model, captainActions), snapshot.fm_home || path.dirname(allowedData));
  writePrivateAtomic(waitHistoryPath, `${JSON.stringify(waitHistory, null, 2)}\n`, snapshot.fm_home || path.dirname(allowedData));
  if (refsPath) {
    const refs = {};
    for (const [key, ref] of opaqueRefs.entries()) {
      const separator = key.indexOf("\0");
      refs[ref] = {
        kind: key.slice(0, separator),
        value: key.slice(separator + 1),
        ...(opaqueRefLabels.has(ref) ? { label: opaqueRefLabels.get(ref) } : {}),
        ...(opaqueRefMetadata.get(ref) || {}),
      };
    }
    writePrivateAtomic(refsPath, `${JSON.stringify({ schema: "fm-capacity-refs.v1", generated: model.generated, refs }, null, 2)}\n`, snapshot.fm_home || path.dirname(allowedData));
  }
  if (opts.json) {
    process.stdout.write(`${JSON.stringify(model, null, 2)}\n`);
  } else {
    process.stdout.write(`capacity dashboard: ${output}\n`);
    process.stdout.write(`generated: ${model.generated}\n`);
    process.stdout.write(`primary bottleneck: ${model.primary_bottleneck.classification}${model.primary_bottleneck.id ? ` (${model.primary_bottleneck.id})` : ""}\n`);
    process.stdout.write(`useful ready: ${model.measures.useful_ready_work}; active: ${model.measures.active_independent_work}; waiting: ${model.measures.waiting_work}; captain actions: ${model.measures.open_captain_actions}\n`);
    process.stdout.write(`actions: ${model.recommendations.map((rec) => rec.id).join(", ") || "none"}\n`);
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`fm-capacity: ${error.message}\n`);
  process.exit(1);
}
