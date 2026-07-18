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
 * offline review; normal /capacity runs must not use them.
 *
 * fm-capacity.v1 fields:
 *   generated, dashboard_path, provenance, measures, primary_bottleneck,
 *   pipeline, lanes, readiness, aging, recommendations, and omissions.
 * Pipeline stages are queued, ready, building, validating_fixing,
 * pr_ci_approval, blocked, and recently_landed.
 *
 * The producer is read-mostly. It writes only the selected dashboard path and
 * never dispatches, merges, tears down, changes backlog/task state, or opens a
 * service. Inline dashboard JavaScript copies prompts only and cannot run actions.
 */

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
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
  out.write(`usage: fm-capacity.mjs [--json] [--output <path>] [--snapshot <json>] [--environment <json>]\n\n`);
  out.write(`Gather a fresh bounded fleet snapshot, classify meaningful capacity, and replace a\n`);
  out.write(`self-contained offline dashboard. The default output is data/capacity-dashboard.html\n`);
  out.write(`under the effective FM_HOME. --snapshot and --environment are deterministic fixture\n`);
  out.write(`inputs for tests/offline review and must not be used for a normal /capacity run.\n`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const opts = { json: false, output: null, snapshot: null, environment: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") opts.json = true;
    else if (arg === "--output") opts.output = argv[++i];
    else if (arg.startsWith("--output=")) opts.output = arg.slice(9);
    else if (arg === "--snapshot") opts.snapshot = argv[++i];
    else if (arg.startsWith("--snapshot=")) opts.snapshot = arg.slice(11);
    else if (arg === "--environment") opts.environment = argv[++i];
    else if (arg.startsWith("--environment=")) opts.environment = arg.slice(14);
    else if (arg === "-h" || arg === "--help") usage(0);
    else usage(2);
    if ((arg === "--output" || arg === "--snapshot" || arg === "--environment") && !argv[i]) usage(2);
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
  return spawnSync(command, args, {
    encoding: "utf8",
    timeout: options.timeout ?? 12000,
    env: options.env ?? process.env,
    maxBuffer: options.maxBuffer ?? 4 * 1024 * 1024,
  });
}

function gatherSnapshot(file) {
  if (file) return readJson(file, "snapshot fixture");
  const result = run(path.join(SCRIPT_DIR, "fm-fleet-snapshot.sh"), ["--json"], { timeout: 45000 });
  if (result.status !== 0) {
    throw new Error(`fresh fleet snapshot failed: ${(result.stderr || result.stdout || "unknown error").trim()}`);
  }
  return JSON.parse(result.stdout);
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

function configuredDispatch(configDir, fmHome) {
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
      timeout: 3000,
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

function liveEnvironment(snapshot) {
  const roots = snapshot.roots || {};
  const configDir = roots.config || path.join(snapshot.fm_home || ROOT, "config");
  const fmHome = snapshot.fm_home || ROOT;
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
    timeout: 5000,
  });
  const backendFields = (backendProbe.stdout || "unknown|false|backend probe failed").trim().split("|");
  const bootstrap = run(path.join(SCRIPT_DIR, "fm-bootstrap.sh"), [], {
    env: { ...process.env, FM_HOME: fmHome, FM_CONFIG_OVERRIDE: configDir, FM_BOOTSTRAP_DETECT_ONLY: "1" },
    timeout: 15000,
  });
  const diagnostics = `${bootstrap.stdout || ""}\n${bootstrap.stderr || ""}`;
  const dispatch = configuredDispatch(configDir, fmHome);
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

function normalizeEnvironment(environment) {
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

const opaqueRefs = new Map();

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

function dateAgeDays(value, now) {
  if (!value) return null;
  const parsed = Date.parse(`${value}T00:00:00Z`);
  if (!Number.isFinite(parsed)) return null;
  return Math.max(0, Math.floor((now - parsed) / 86400000));
}

function bodyHasAcceptance(record) {
  const text = String(record.body_excerpt || "").replace(/\s+/g, " ").trim();
  const namedMarkers = "acceptance criteria|done when|definition of done|success criteria";
  if (!text || new RegExp(`\\bno\\s+(?:${namedMarkers})\\b`, "i").test(text)) return false;
  const patterns = [
    new RegExp(`(?:^|\\s)(?:${namedMarkers})\\s*[:\\-]\\s*(.+)$`, "i"),
    new RegExp(`(?:^|\\s)#{1,6}\\s*(?:${namedMarkers})\\s+(.+)$`, "i"),
    /(?:^|\s)(?:acceptance|verify|verification|tests?)\s*:\s*(.+)$/i,
  ];
  const match = patterns.map((pattern) => text.match(pattern)).find(Boolean);
  if (!match) return false;
  const criteria = match[1].trim().replace(/^[*-]\s*/, "");
  if (criteria.length < 8) return false;
  const placeholder = /^(?:(?:todo|tbd|fixme|wip|placeholder|draft|pending|forthcoming|undefined|unknown|undecided|unresolved)\b|(?:to be|will be|not yet)\s+(?:defined|determined|written|added|confirmed|finalized)\b)/i;
  return !placeholder.test(criteria) && (criteria.match(/[a-z0-9][\w-]*/gi) || []).length >= 2;
}

function isSuperseded(record) {
  return /\b(?:SUPERSEDED|DEFERRED)\b|\bNOT(?:\s+|-)REQUIRED\b/i.test(record.body_excerpt || "");
}

function definitionGaps(record, crossHome = false) {
  const gaps = [];
  if (!record.repo) gaps.push("project unresolved");
  if (!record.kind || !["ship", "scout"].includes(record.kind)) gaps.push("deliverable kind missing");
  if (!record.title || record.title.trim().length < 12 || /^(todo|tbd|fix|investigate|work item)$/i.test(record.title.trim())) gaps.push("scope is insufficient");
  if (!bodyHasAcceptance(record)) gaps.push(crossHome && record.body_excerpt === undefined ? "acceptance evidence unavailable" : "acceptance criteria missing");
  if (/\b(?:depends?|after|blocked)\b/i.test(`${record.title || ""} ${record.body_excerpt || ""}`) && !record.blocked_by) gaps.push("dependency definition missing");
  return gaps;
}

function futureTimeGate(record, now) {
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
  if (decision || ["blocked", "paused", "unknown", "failed"].includes(state)) return "blocked";
  if (task.pr?.url && (state === "done" || state === "parked")) return "pr_ci_approval";
  if (/validat|fixing|ci |ci running|parked at/i.test(detail) || state === "parked") return "validating_fixing";
  if (task.pr?.url) return "pr_ci_approval";
  if (state === "done") return "pr_ci_approval";
  return "building";
}

function taskApprovalReady(task) {
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
    stage,
    reason: reason || "Structured operational detail withheld",
    artifact: null,
    provenance: owner === "main" ? "main structured backlog" : "validated structured-home backlog",
  };
}

function classify(snapshot, environment) {
  if (snapshot.schema !== "fm-fleet-snapshot.v1") throw new Error(`unsupported snapshot schema: ${snapshot.schema || "missing"}`);
  const now = Date.parse(snapshot.generated) || Date.now();
  const pipeline = Object.fromEntries(STAGES.map((stage) => [stage, []]));
  const mainRecords = snapshot.backlog?.records || [];
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
  let secondmateQueuedConsidered = 0;
  let readinessComplete = true;

  function markUnavailable(id, owner, evidence) {
    unavailable.push({ id, owner, evidence });
    readinessComplete = false;
  }

  if (snapshot.backlog?.present !== true || !Array.isArray(snapshot.backlog?.records)) {
    markUnavailable("main-backlog", "main", "main structured backlog unavailable");
  }
  if (!Array.isArray(snapshot.tasks)) {
    markUnavailable("main-tasks", "main", "main current-task inventory unavailable");
  }
  if (!snapshot.secondmate_current
    || !Array.isArray(snapshot.secondmate_current.records)
    || !Number.isInteger(snapshot.secondmate_current.truncated)
    || snapshot.secondmate_current.truncated > 0) {
    markUnavailable("secondmate-inventory", "main", "bounded secondmate inventory incomplete");
  }
  const registry = snapshot.secondmate_current?.registry;
  if (registry?.available === false || registry?.complete === false) {
    markUnavailable("secondmate-registry", "main", "registry projection incomplete");
  }
  for (const record of mainRecords.filter((item) => item.state === "in_flight" && item.structured)) {
    const task = taskById.get(record.id);
    const repo = record.repo || task?.project || null;
    if (repo) activeProjects.add(repo);
    if (!task || !repo) {
      markUnavailable(itemRef("main", record.id), "main", "in-flight work lacks current task or project provenance");
    }
  }

  for (const task of snapshot.tasks || []) {
    if (task.kind === "secondmate") continue;
    const backlog = task.backlog || mainRecords.find((record) => record.structured && record.id === task.id) || {};
    const stage = taskStage(task);
    const ageDays = dateAgeDays(backlog.since, now);
    const taskRepo = backlog.repo || task.project || null;
    if (taskRepo) {
      activeProjects.add(taskRepo);
    } else {
      markUnavailable(itemRef("main", task.id), "main", "in-flight work lacks project provenance");
    }
    const open = task.hints?.open_decisions || [];
    for (const decision of open) decisions.push({ owner: "main", task: itemRef("main", task.id), key: itemRef("decision", decision.key || task.id) });
    if ((task.current_state?.state || "unknown") === "unknown" || task.endpoint?.exists === false) {
      markUnavailable(itemRef("main", task.id), "main", "current task state unavailable");
    }
    if (ageDays !== null && ageDays >= 7 && ["building", "validating_fixing", "pr_ci_approval", "blocked"].includes(stage)) {
      aging.push({ id: itemRef("main", task.id), owner: "main", age_days: ageDays, state: safeState(task.current_state?.state), evidence: `structured backlog age; current source ${safeSource(task.current_state?.source)}` });
    }
    const approvalReady = taskApprovalReady(task);
    pipeline[stage].push({
      id: itemRef("main", task.id),
      title: `${STAGE_LABELS[stage]} work item`,
      owner: "ephemeral worker",
      repo: projectRef(taskRepo),
      kind: ["ship", "scout"].includes(task.kind) ? task.kind : null,
      stage,
      reason: `Authoritative current state: ${safeState(task.current_state?.state)}`,
      artifact: null,
      provenance: `current state from ${safeSource(task.current_state?.source)}`,
      age_days: ageDays,
      approval_ready: approvalReady,
      approval_authority: approvalReady ? (task.yolo === "on" ? "firstmate" : "captain") : null,
      captain_approval_required: approvalReady && task.yolo !== "on",
    });
  }

  const queue = mainRecords.filter((record) => record.state === "queued");
  const candidates = [];
  for (const record of queue) {
    if (!record.structured) {
      readinessRows.push({ id: itemRef("main", "unstructured"), owner: "main", status: "definition_gap", gaps: ["unstructured backlog row"] });
      pipeline.queued.push(cardFromBacklog(record, "main", "queued", "Unstructured backlog entry"));
      continue;
    }
    if (isSuperseded(record)) continue;
    if (record.kind === "captain" && record.hold_kind === "captain") {
      decisions.push({ owner: "main", task: itemRef("main", record.id), key: itemRef("decision", record.id) });
      blockedRows.push({ id: itemRef("main", record.id), owner: "main", reason: "captain hold" });
      pipeline.blocked.push(cardFromBacklog(record, "main", "blocked", "Captain hold"));
      continue;
    }
    if (record.blocked_by || record.hold_reason) {
      blockedRows.push({ id: itemRef("main", record.id), owner: "main", reason: "dependency or structured hold" });
      pipeline.blocked.push(cardFromBacklog(record, "main", "blocked", "Dependency or structured hold"));
      continue;
    }
    const timeGate = futureTimeGate(record, now);
    if (timeGate) {
      const reason = `time gate until ${timeGate}`;
      blockedRows.push({ id: itemRef("main", record.id), owner: "main", reason });
      pipeline.blocked.push(cardFromBacklog(record, "main", "blocked", reason));
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
      || !Number.isInteger(mate.counts?.active_children)
      || !Number.isInteger(mate.counts?.decisions_open)
      || !Number.isInteger(mate.counts?.holds)
      || !Number.isInteger(mate.counts?.queued)
      || mate.counts.active_children !== (mate.active_children || []).length
      || mate.counts.decisions_open !== (mate.decisions_open || []).length
      || mate.counts.holds !== (mate.holds || []).length
      || mate.counts.queued !== (mate.queued || []).length;
    if (mateIncomplete) markUnavailable(opaqueRef("home", mate.id), "persistent secondmate", "structured home inventory incomplete");
    if (!scopeAvailable) markUnavailable(opaqueRef("home", mate.id), "persistent secondmate", "registered routing scope unavailable");
    for (const decision of mate.decisions_open || []) {
      decisions.push({ owner: ownerRef(mate.id), task: itemRef(mate.id, decision.id || mate.id), key: itemRef("decision", decision.key || decision.id || mate.id) });
    }
    const heldIds = new Set();
    for (const hold of mate.holds || []) {
      heldIds.add(hold.id);
      if (hold.source === "child-state") {
        if (hold.repo) {
          activeProjects.add(hold.repo);
        } else {
          markUnavailable(itemRef(mate.id, hold.id), ownerRef(mate.id), "in-flight held work lacks project provenance");
        }
      }
      const ageDays = dateAgeDays(hold.since, now);
      blockedRows.push({ id: itemRef(mate.id, hold.id), owner: ownerRef(mate.id), reason: "structured wait gate" });
      pipeline.blocked.push(cardFromBacklog(hold, mate.id, "blocked", "Structured wait gate"));
      if (ageDays !== null && ageDays >= 7) {
        aging.push({ id: itemRef(mate.id, hold.id), owner: ownerRef(mate.id), age_days: ageDays, state: "held", evidence: "structured backlog age; structured wait gate" });
      }
    }
    for (const child of mate.active_children || []) {
      const detail = child.doing || child.state || "working";
      const stage = /validat|fixing|ci /i.test(detail) ? "validating_fixing" : "building";
      if (child.repo) {
        activeProjects.add(child.repo);
      } else {
        markUnavailable(itemRef(mate.id, child.id), ownerRef(mate.id), "active child work lacks project provenance");
      }
      const ageDays = dateAgeDays(child.since, now);
      pipeline[stage].push({
        id: itemRef(mate.id, child.id),
        title: `${STAGE_LABELS[stage]} work item`,
        owner: ownerRef(mate.id),
        repo: projectRef(child.repo),
        kind: ["ship", "scout"].includes(child.kind) ? child.kind : "ship",
        stage,
        reason: `Authoritative current state: ${safeState(child.state || "working")}`,
        artifact: null,
        provenance: "validated structured-home summary",
        age_days: ageDays,
      });
      if (ageDays !== null && ageDays >= 7) {
        aging.push({ id: itemRef(mate.id, child.id), owner: ownerRef(mate.id), age_days: ageDays, state: safeState(child.state), evidence: "structured backlog age; structured-home current state" });
      }
    }
    for (const record of mate.queued || []) {
      if (isSuperseded(record) || heldIds.has(record.id)) continue;
      secondmateQueuedConsidered += 1;
      if (record.kind === "captain" && record.hold_kind === "captain") {
        blockedRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), reason: "captain hold" });
        pipeline.blocked.push(cardFromBacklog(record, mate.id, "blocked", "Captain hold"));
        continue;
      }
      if (record.blocked_by || record.hold_reason) {
        blockedRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), reason: "dependency or structured hold" });
        pipeline.blocked.push(cardFromBacklog(record, mate.id, "blocked", "Dependency or structured hold"));
        continue;
      }
      const timeGate = futureTimeGate(record, now);
      if (timeGate) {
        const reason = `time gate until ${timeGate}`;
        blockedRows.push({ id: itemRef(mate.id, record.id), owner: ownerRef(mate.id), reason });
        pipeline.blocked.push(cardFromBacklog(record, mate.id, "blocked", reason));
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
    mates.push({
      id: mateId,
      scope: scopeAvailable ? "Registered routing scope recorded; text withheld" : "Registered routing scope unavailable",
      projects: route.projects?.length ? [`${route.projects.length} registered project route(s); names withheld`] : [],
      current: safeState(mate.current?.state),
      provenance: mate.provenance?.selected === "structured-home" ? "validated structured-home summary" : "unavailable",
      active_children: activeCount,
      ready_in_scope: 0,
      utilization: "unavailable",
    });
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
  for (const mate of mates) {
    const mateReady = ready.filter((candidate) => candidate.owner !== "main" && opaqueRef("home", candidate.owner) === mate.id).length;
    const available = readinessComplete && mateAvailability.get(mate.id);
    mate.ready_in_scope = available ? mateReady : 0;
    mate.utilization = !available
      ? "unavailable"
      : mate.active_children > 0
        ? "active on useful in-scope work"
        : mateReady > 0
          ? "idle with grounded ready in-scope work"
          : "healthy idle - no grounded ready in-scope work";
  }

  const secondmateLanded = snapshot.secondmate_landed;
  const recentLandingsComplete = Boolean(
    snapshot.backlog?.present === true
    && Array.isArray(snapshot.backlog?.records)
    && secondmateLanded
    && Array.isArray(secondmateLanded.records)
    && Array.isArray(secondmateLanded.truncated)
    && secondmateLanded.truncated.length === 0
    && Array.isArray(secondmateLanded.unreadable)
    && secondmateLanded.unreadable.length === 0
  );
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
  if (environment.github_auth.status !== "available") recommend(
    "CAP-02", "credentials", 10,
    `GitHub authentication is ${environment.github_auth.status}: ${environment.github_auth.evidence}.`,
    "PR discovery, push, and CI handoff may stop even when implementation capacity exists.",
    "Credential material must stay outside the dashboard; authentication is restored through the normal bootstrap flow.",
    "Restore GitHub authentication, then refresh /capacity before dispatching PR-bound work.",
    "Approve CAP-02: guide me through restoring the required GitHub authentication, then refresh the capacity snapshot."
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
  if (blockedRows.length > 0 || overlapRows.length > 0) recommend(
    "CAP-05", overlapRows.length > 0 ? "overlap serialization" : "task dependencies and gates", 50,
    `${blockedRows.length} item${blockedRows.length === 1 ? " is" : "s are"} explicitly gated and ${overlapRows.length} item${overlapRows.length === 1 ? " is" : "s are"} conservatively serialized for coarse project overlap.`,
    "Landing dependencies or confirming non-overlapping subsystem boundaries can release independent starts safely.",
    "No overlap rule, dependency, time gate, approval, or safety boundary is weakened automatically.",
    "Review the highest-impact gate and only mark work independent when evidence supports it.",
    "Approve CAP-05: review the dependency and coarse-overlap gates, preserving safety, and identify any work that is truly independent."
  );
  if (ready.length > 0) recommend(
    "CAP-06", "grounded ready supply", 70,
    `${ready.length} useful item${ready.length === 1 ? " is" : "s are"} grounded, unblocked, and conservatively independent: ${ready.slice(0, 5).map((item) => `${ownerRef(item.owner)}/${itemRef(item.owner, item.record.id)}`).join(", ")}.`,
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
  const activeCount = pipeline.building.length + pipeline.validating_fixing.length + pipeline.pr_ci_approval.length;
  if (readinessComplete && ready.length === 0 && activeCount === 0 && definitionRows.length === 0 && blockedRows.length === 0 && decisions.length === 0) recommend(
    "CAP-08", "demand shortage", 80,
    "No grounded ready work, active delivery, definition gaps, explicit gates, or captain decisions are visible in the bounded snapshot.",
    "Throughput is demand-limited; adding agents or keeping lanes busy would create artificial utilization, not value.",
    "New work must come from a captain-grounded goal or normal planning intake, never speculative busywork.",
    "Name the next valuable outcome or leave the fleet healthy and idle.",
    "Approve CAP-08: help me turn the next captain-grounded outcome into normal scoped backlog work; do not invent busywork."
  );
  const idleUsefulMates = mates.filter((mate) => mate.ready_in_scope > 0 && mate.active_children === 0 && mate.current !== "unknown");
  if (laneMismatch || idleUsefulMates.length > 0) recommend(
    "CAP-09", "lane mismatch", 25,
    `${availableLanes.length} configured ephemeral dispatch lane${availableLanes.length === 1 ? " is" : "s are"} executable; backend ${environment.backend.name} is ${environment.backend.available ? "available" : "unavailable"}; ${idleUsefulMates.length} idle secondmate${idleUsefulMates.length === 1 ? " has" : "s have"} grounded ready in-scope work.`,
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
      recent_landings: recentLandingsComplete
        ? "Main backlog completions and bounded secondmate landing projections are complete."
        : "Recent secondmate landing projections are incomplete; the displayed count is an observed lower bound.",
    },
    measures: {
      useful_ready_work: ready.length,
      independent_tasks_safe_to_start_now: ready.length,
      active_independent_work: activeIndependentKeys.size,
      waiting_work: pipeline.queued.length + pipeline.blocked.length + pipeline.pr_ci_approval.length,
      open_captain_actions: decisions.length + captainApprovalCards.length,
      recently_landed: pipeline.recently_landed.length,
      recently_landed_complete: recentLandingsComplete,
    },
    primary_bottleneck: { id: primary.id, classification: primary.classification, evidence: primary.evidence },
    pipeline,
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
      queued_considered: queue.filter((record) => !isSuperseded(record)).length + secondmateQueuedConsidered,
      grounded_candidates: readinessComplete ? candidates.length : 0,
      independent_start_count: ready.length,
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
      "Status tails, terminal chat, scout report contents, and visual artifacts are not consulted.",
      ...(recentLandingsComplete ? [] : ["Recent secondmate landings are incomplete; the displayed count is an observed lower bound."]),
    ],
  };
  return sanitizeDeep(model);
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

function writePrivateAtomic(destination, content) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  try {
    if (fs.lstatSync(destination).isSymbolicLink()) throw new Error("dashboard destination must not be a symlink");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`);
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

function pipelineCard(card) {
  return `<article class="work-card">
    <div class="card-top"><span class="item-id">${h(card.id)}</span><span class="owner">${h(card.owner)}</span></div>
    <h3>${h(card.title)}</h3>
    <p>${h(card.reason || "No additional gate detail.")}</p>
    <dl><div><dt>Evidence</dt><dd>${h(card.provenance)}</dd></div>${card.repo ? `<div><dt>Project</dt><dd>${h(card.repo)}</dd></div>` : ""}${card.age_days !== null && card.age_days !== undefined ? `<div><dt>Age</dt><dd>${h(card.age_days)} ${card.age_days === 1 ? "day" : "days"}</dd></div>` : ""}</dl>
    ${card.artifact ? `<div class="artifact">${artifact(card.artifact)}</div>` : ""}
  </article>`;
}

function renderHtml(model) {
  const measureCards = [
    ["Useful ready supply", model.measures.useful_ready_work, "Grounded and independently startable"],
    ["Active flow", model.measures.active_independent_work, "Ephemeral and secondmate child work"],
    ["Waiting work", model.measures.waiting_work, "Queued, gated, or at delivery gates"],
    ["Captain actions", model.measures.open_captain_actions, "Structured decisions and ready approvals"],
    ["Primary bottleneck", model.primary_bottleneck.classification, model.primary_bottleneck.id || "No action ID"],
  ].map(([label, value, note]) => `<article class="metric"><span>${h(label)}</span><strong>${h(value)}</strong><small>${h(note)}</small></article>`).join("");

  const stageHtml = STAGES.map((stage) => `<section class="stage" aria-labelledby="stage-${stage}">
    <header><h2 id="stage-${stage}">${h(STAGE_LABELS[stage])}</h2><span>${model.pipeline[stage].length}</span></header>
    <div class="stage-cards">${model.pipeline[stage].length ? model.pipeline[stage].map(pipelineCard).join("") : `<p class="empty">No current items.</p>`}</div>
  </section>`).join("");

  const mateRows = model.lanes.persistent_secondmates.map((mate) => `<article class="lane-card">
    <div class="card-top"><span class="item-id">${h(mate.id)}</span><span class="status ${mate.utilization.startsWith("healthy") ? "healthy" : ""}">${h(mate.current)}</span></div>
    <h3>${h(mate.utilization)}</h3>
    <p><strong>Scope:</strong> ${h(mate.scope)}</p>
    <p><strong>Projects:</strong> ${h((mate.projects || []).join(", ") || "None recorded")}</p>
    <p>${h(mate.active_children)} active child item(s), ${h(mate.ready_in_scope)} grounded ready in-scope item(s).</p>
    <small>${h(mate.provenance)}</small>
  </article>`).join("") || `<p class="empty">No persistent secondmates are registered.</p>`;

  const dispatchRows = (model.lanes.ephemeral_workers.configured_dispatch.lanes || []).map((lane) => `<article class="lane-card">
    <div class="card-top"><span class="item-id">${h(lane.harness)}${lane.model ? ` / ${h(lane.model)}` : ""}</span><span class="status ${lane.available ? "healthy" : "warning"}">${lane.available ? "available" : "unavailable"}</span></div>
    <h3>${h(lane.when)}</h3>
    <p>${h(lane.availability_evidence)}</p>
    <small>${h(lane.quota)}</small>
  </article>`).join("") || `<p class="empty">No usable dispatch lanes were resolved.</p>`;

  const recs = model.recommendations.map((rec) => `<article class="recommendation" id="${h(rec.id)}">
    <div class="rec-head"><span class="action-id">${h(rec.id)}</span><h3>${h(rec.classification)}</h3></div>
    <dl>
      <div><dt>Evidence</dt><dd>${h(rec.evidence)}</dd></div>
      <div><dt>Throughput consequence</dt><dd>${h(rec.expected_throughput_consequence)}</dd></div>
      <div><dt>Safety and authority</dt><dd>${h(rec.safety_authority_boundary)}</dd></div>
      <div><dt>Next action</dt><dd>${h(rec.recommended_next_action)}</dd></div>
    </dl>
    <div class="prompt"><code>${h(rec.prompt)}</code><button type="button" data-copy="${h(rec.prompt)}" aria-label="Copy ${h(rec.id)} follow-up prompt">Copy prompt</button></div>
  </article>`).join("") || `<p class="empty">No capacity action is currently recommended. Healthy idle is acceptable.</p>`;

  const gaps = model.readiness.definition_gaps.map((row) => `<li><strong>${h(`${row.owner}/${row.id}`)}</strong><span>${h(row.gaps.join("; "))}</span></li>`).join("") || `<li><strong>None</strong><span>No definition gaps detected in the bounded queue.</span></li>`;
  const landed = model.pipeline.recently_landed.map((card) => `<li><strong>${h(`${card.owner}/${card.id}`)}</strong><span>${h(card.title)}</span>${card.artifact ? artifact(card.artifact) : ""}</li>`).join("") || `<li><strong>None</strong><span>No recent completions are in the bounded baseline.</span></li>`;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark light">
  <title>Firstmate capacity dashboard</title>
  <style>
    :root{--ink:#e9eef8;--muted:#9cabbe;--panel:#111923;--panel2:#172231;--line:#2b3b50;--accent:#61d7c2;--accent2:#f1bd66;--danger:#ff8f8f;--bg:#081019;--shadow:0 16px 40px rgba(0,0,0,.24);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color-scheme:dark}
    *{box-sizing:border-box}html{background:var(--bg);scroll-behavior:smooth}body{margin:0;color:var(--ink);background:radial-gradient(circle at 15% 0%,#12303d 0,transparent 34rem),var(--bg);line-height:1.5;overflow-wrap:anywhere}a{color:#8ae6d6;text-underline-offset:.18em}button,a{outline-offset:3px}button:focus-visible,a:focus-visible{outline:3px solid var(--accent2)}.skip{position:absolute;left:-9999px}.skip:focus{left:1rem;top:1rem;z-index:10;background:#fff;color:#000;padding:.7rem 1rem;border-radius:.5rem}.shell{width:min(1560px,100%);margin:auto;padding:clamp(1rem,3vw,3rem)}.hero{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(18rem,.7fr);gap:1.5rem;align-items:end;padding:clamp(1.5rem,4vw,3.5rem) 0 2rem}.eyebrow{margin:0 0 .5rem;color:var(--accent);font-weight:800;letter-spacing:.12em;text-transform:uppercase;font-size:.78rem}.hero h1{font-size:clamp(2.2rem,6vw,5.4rem);line-height:.95;letter-spacing:-.055em;margin:0;max-width:12ch}.hero p{color:var(--muted);max-width:70ch}.freshness{border:1px solid var(--line);background:rgba(17,25,35,.82);padding:1rem;border-radius:1rem;box-shadow:var(--shadow)}.freshness strong,.freshness span{display:block}.freshness span{color:var(--muted);font-size:.9rem;margin-top:.35rem}.metrics{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:.85rem;margin:1rem 0 2.5rem}.metric{min-width:0;background:linear-gradient(145deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:1rem;padding:1rem}.metric span,.metric small{display:block;color:var(--muted)}.metric strong{display:block;font-size:clamp(1.4rem,2.6vw,2.4rem);line-height:1.1;margin:.4rem 0}.section-title{display:flex;justify-content:space-between;gap:1rem;align-items:end;margin:3.5rem 0 1rem}.section-title h2{font-size:clamp(1.6rem,3vw,2.5rem);margin:0}.section-title p{color:var(--muted);max-width:65ch;margin:0}.pipeline{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:1rem;align-items:start}.stage{min-width:0;border:1px solid var(--line);background:rgba(12,20,29,.78);border-radius:1rem;padding:.85rem}.stage>header{display:flex;align-items:center;justify-content:space-between;gap:.75rem;border-bottom:1px solid var(--line);padding:.25rem .2rem .75rem}.stage>header h2{font-size:1rem;margin:0}.stage>header span,.action-id{background:#21443f;color:#a9f7e8;border-radius:999px;padding:.16rem .58rem;font-weight:800;font-size:.78rem}.stage-cards{display:grid;gap:.7rem;margin-top:.7rem}.work-card,.lane-card,.recommendation{min-width:0;background:var(--panel);border:1px solid var(--line);border-radius:.8rem;padding:.85rem}.work-card h3,.lane-card h3,.recommendation h3{font-size:1rem;margin:.55rem 0}.work-card p,.lane-card p{font-size:.88rem;color:var(--muted);margin:.4rem 0}.card-top,.rec-head{display:flex;align-items:center;justify-content:space-between;gap:.6rem}.item-id{font:700 .76rem ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--accent)}.owner,.status{font-size:.72rem;color:var(--muted);text-align:right}.status{border:1px solid var(--line);padding:.14rem .45rem;border-radius:999px}.status.healthy{color:var(--accent);border-color:#2c675d}.status.warning{color:var(--danger);border-color:#70414a}.work-card dl,.recommendation dl{margin:.6rem 0 0}.work-card dl div,.recommendation dl div{margin-top:.45rem}.work-card dt,.recommendation dt{color:var(--muted);font-size:.72rem;text-transform:uppercase;letter-spacing:.06em}.work-card dd,.recommendation dd{margin:0;font-size:.86rem}.artifact,.path{font:500 .75rem ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:.65rem;max-width:100%;overflow-wrap:anywhere}.empty{color:var(--muted);font-style:italic}.lanes{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem}.lane-group{min-width:0;border:1px solid var(--line);border-radius:1rem;background:rgba(12,20,29,.75);padding:1rem}.lane-group>h3{margin:.2rem 0 1rem}.lane-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.75rem}.recommendations{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem}.recommendation{border-left:4px solid var(--accent2);padding:1.1rem}.rec-head{justify-content:flex-start}.rec-head h3{font-size:1.2rem}.recommendation dl div{display:grid;grid-template-columns:minmax(9rem,.34fr) minmax(0,1fr);gap:1rem;border-top:1px solid var(--line);padding-top:.65rem}.prompt{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:.6rem;align-items:center;margin-top:1rem;background:#09121b;border:1px solid var(--line);border-radius:.65rem;padding:.65rem}.prompt code{font-size:.78rem;white-space:normal}.prompt button{border:0;border-radius:.5rem;background:var(--accent);color:#06241f;font-weight:800;padding:.55rem .75rem;cursor:pointer}.health-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem}.list-panel{background:var(--panel);border:1px solid var(--line);border-radius:1rem;padding:1rem;min-width:0}.list-panel h3{margin-top:0}.clean-list{list-style:none;margin:0;padding:0;display:grid;gap:.7rem}.clean-list li{display:grid;grid-template-columns:minmax(8rem,.35fr) minmax(0,1fr);gap:.75rem;border-top:1px solid var(--line);padding-top:.65rem;min-width:0}.clean-list li>*{min-width:0}.clean-list span{color:var(--muted)}footer{margin-top:4rem;padding:1.5rem 0;color:var(--muted);border-top:1px solid var(--line);font-size:.85rem}
    @media(max-width:1100px){.metrics{grid-template-columns:repeat(3,minmax(0,1fr))}.pipeline{grid-template-columns:repeat(2,minmax(0,1fr))}.recommendations{grid-template-columns:1fr}}
    @media(max-width:760px){.shell{padding:1rem}.hero{grid-template-columns:1fr}.metrics,.pipeline,.lanes,.health-grid,.lane-grid{grid-template-columns:1fr}.section-title{display:block}.section-title p{margin-top:.4rem}.recommendation dl div,.clean-list li{grid-template-columns:1fr;gap:.15rem}.prompt{grid-template-columns:1fr}.prompt button{width:100%}.hero h1{font-size:clamp(2.4rem,15vw,4rem)}}
    @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
    @media print{body{background:#fff;color:#111}.shell{width:100%;padding:0}.work-card,.lane-card,.recommendation,.stage,.lane-group,.list-panel,.metric,.freshness{box-shadow:none;background:#fff;color:#111;border-color:#bbb}.pipeline{grid-template-columns:repeat(2,minmax(0,1fr))}.prompt button{display:none}a{color:#0645ad}}
  </style>
</head>
<body>
  <a class="skip" href="#main">Skip to dashboard</a>
  <div class="shell">
    <header class="hero">
      <div><p class="eyebrow">Firstmate / meaningful throughput</p><h1>Capacity, without busywork.</h1><p>This view identifies what can safely flow now, what is actually holding delivery back, and where healthy idle should stay idle.</p></div>
      <aside class="freshness" aria-label="Snapshot freshness"><strong>Generated ${h(model.generated)}</strong><span>${h(model.provenance.freshness)}</span><span>${h(model.provenance.secondmates)}</span></aside>
    </header>
    <main id="main">
      <section aria-label="Top capacity measures" class="metrics">${measureCards}</section>
      <div class="section-title"><h2>Delivery pipeline</h2><p>One current card per item, classified from authoritative current state and structured backlog evidence.</p></div>
      <div class="pipeline">${stageHtml}</div>
      <div class="section-title"><h2>Lane and scope alignment</h2><p>Ephemeral workers are created on demand. Persistent secondmates are healthy when idle unless grounded in-scope work is already ready.</p></div>
      <section class="lanes" aria-label="Lane utilization">
        <div class="lane-group"><h3>Ephemeral dispatch lanes</h3><p>${h(model.lanes.ephemeral_workers.pool)}</p><p>Runtime backend: <strong>${h(model.lanes.ephemeral_workers.backend.name)}</strong> - ${h(model.lanes.ephemeral_workers.backend.evidence)}. GitHub auth: ${h(model.lanes.ephemeral_workers.github_auth.status)}.</p><div class="lane-grid">${dispatchRows}</div></div>
        <div class="lane-group"><h3>Persistent secondmates</h3><div class="lane-grid">${mateRows}</div></div>
      </section>
      <div class="section-title"><h2>Capacity recommendations</h2><p>Stable action IDs are discussion handles. Copying or approving a prompt re-enters normal Firstmate lifecycles in chat; this page executes nothing.</p></div>
      <section class="recommendations" aria-label="Prioritized capacity recommendations">${recs}</section>
      <div class="section-title"><h2>Definition health and landed context</h2><p>Nominal queue depth is separated from dispatch-grade supply, with recent outcomes retained for context.</p></div>
      <section class="health-grid">
        <div class="list-panel"><h3>Backlog definition gaps</h3><ul class="clean-list">${gaps}</ul></div>
        <div class="list-panel"><h3>Recently landed${model.measures.recently_landed_complete ? "" : " (observed; incomplete)"}</h3><ul class="clean-list">${landed}</ul></div>
      </section>
    </main>
    <footer><p>Provenance: ${h(model.provenance.fleet)}. ${h(model.provenance.decisions)} ${h(model.provenance.environment)}</p><p>This private dashboard contains bounded operational metadata only. It uses no CDN, remote asset, analytics, network service, or Lavish integration.</p></footer>
  </div>
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
  const environment = normalizeEnvironment(opts.environment ? readJson(opts.environment, "environment fixture") : liveEnvironment(snapshot));
  const defaultOutput = path.join(snapshot.roots?.data || path.join(snapshot.fm_home || ROOT, "data"), "capacity-dashboard.html");
  const output = path.resolve(opts.output || defaultOutput);
  const allowedData = path.resolve(snapshot.roots?.data || path.join(snapshot.fm_home || ROOT, "data"));
  if (!opts.output && !output.startsWith(`${allowedData}${path.sep}`)) throw new Error("default dashboard path escaped the effective data directory");
  const model = classify(snapshot, environment);
  writePrivateAtomic(output, renderHtml(model));
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
