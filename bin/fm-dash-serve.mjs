#!/usr/bin/env node
/**
 * fm-dash-serve.mjs - persistent tailnet-only capacity dashboard service.
 *
 * This file is the single owner of the dashboard service's HTTP surface,
 * captain-identity enforcement, interactive layer injection, refresh
 * serialization, and durable command-inbox write mechanics. docs/dashboard-service.md
 * owns the architecture narrative and setup evidence; bin/fm-dash-install.sh owns
 * launchd persistence and tailscale serve wiring; bin/fm-dash-inbox.sh owns
 * firstmate-side consumption of the records this service writes.
 *
 * The service never executes fleet commands, calls only the read-mostly capacity
 * producer and quota probe, and mutates only state/dash-inbox/ plus the
 * producer-owned dashboard and private refs sidecar. A clicked
 * CAP action, decision answer, idea verdict, parking-lot unpark, or recurring
 * run-now becomes one durable fm-dash-command.v1 record in state/dash-inbox/;
 * the running firstmate consumes it through its registered fm-dash watcher check
 * (bin/fm-dash-inbox.sh claim). Delivery therefore rides the sanctioned wake
 * path and inherits its cadence rather than any direct control channel; an
 * unpark click only asks firstmate to lift the parked hold through the normal
 * backlog lifecycle, and a run-now click only asks firstmate to run the
 * scheduled recurring item early through the same normal lifecycle.
 *
 * Acknowledgeable actions and verdicts acknowledge instantly and durably: the
 * served page renders their state straight from the command channel (pending
 * record = sent, archived record = received with its claim time, recent
 * archived record behind a regenerated model = previously approved or denied),
 * so a recent action never looks undecided after a reload or a regeneration
 * re-emits the same stable action ID. Idea suggestions stay additive and never
 * acknowledge persistently, so they cannot disable a later verdict. The claim
 * helper touches state/dash-inbox/.model-stale after archiving; this service
 * polls that marker and reruns the producer promptly (when auto-render is
 * enabled) so the model catches up with handled clicks.
 *
 * Identity fails closed: every route except /healthz requires the
 * Tailscale-User-Login header injected by tailscale serve to match a login in
 * config/dash.json. Requests without a matching identity get 403 and cause no
 * writes. Dispatch accepts only known CAP-NN identifiers that are present in
 * the currently served dashboard AND in the fixed one-click allowlist below.
 * The only free text accepted anywhere is bounded captain-authored content: an
 * idea suggestion or decision custom answer delivered to firstmate as data,
 * never interpreted or executed by this service. Unknown or future action IDs
 * are refused (route those through captain chat). The server binds 127.0.0.1
 * only, so the only remote path in is the tailnet proxy.
 *
 * Environment: FM_HOME selects the home (defaults to this checkout);
 * FM_DASH_CAPACITY_ARGS appends producer fixture args for tests ONLY and must
 * stay unset in real deployments. Run --help for routes and config schema.
 */

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import process from "node:process";
import { createHash, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const FM_HOME = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const STATE = process.env.FM_STATE_OVERRIDE || path.join(FM_HOME, "state");
const DATA = path.join(FM_HOME, "data");
const CONFIG_PATH = path.join(FM_HOME, "config", "dash.json");
const DASHBOARD = path.join(DATA, "capacity-dashboard.html");
const INBOX = path.join(STATE, "dash-inbox");
const CAPACITY = path.join(ROOT, "bin", "fm-capacity.mjs");
const REFS = path.join(STATE, "dash-refs.json");
const BACKLOG = path.join(DATA, "backlog.md");
const IDEAS = path.join(DATA, "ideas", "idea-backlog.md");
const PITCHES = path.join(DATA, "ideas", "pitches");
const QUOTA_AXI = process.env.FM_DASH_QUOTA_AXI || "quota-axi";
const REFRESH_TIMEOUT_MS = 180000;
const QUOTA_TIMEOUT_MS = 8000;
const QUOTA_CACHE_MS = 60000;
const MAX_BODY_BYTES = 16384;
// A claimed command keeps acknowledging its action across regenerations for
// this long after the click. Within the window a re-emitted stable action ID
// (CAP-NN can legitimately reappear in a fresh snapshot) renders as previously
// approved instead of a bare Approve button; past it, a re-emitted action is a
// genuinely new decision context and renders fresh.
const ACK_PRIOR_WINDOW_MS = 6 * 60 * 60 * 1000;
// Claim-marker poll cadence for prompt post-claim regeneration.
// FM_DASH_STALE_POLL_MS is for tests ONLY and must stay unset in real deployments.
const STALE_POLL_MS = Number(process.env.FM_DASH_STALE_POLL_MS) > 0 ? Number(process.env.FM_DASH_STALE_POLL_MS) : 30000;
const STALE_MARKER = path.join(INBOX, ".model-stale");
const STALE_REFRESH_MARKER = path.join(INBOX, ".model-stale.refreshing");

// One-click eligible action IDs. Every current CAP action only requests
// lifecycle-safe guidance or work that re-enters normal authority checks
// (capacity skill section 4); none authorizes a merge, discard, or other
// destructive or irreversible act. A future action ID absent from this list is
// refused with guidance to raise it in captain chat, so new actions default to
// NOT one-click until deliberately reviewed and added here.
const ONE_CLICK_ACTIONS = new Set([
  "CAP-01", "CAP-02", "CAP-03", "CAP-04", "CAP-05",
  "CAP-06", "CAP-07", "CAP-08", "CAP-09", "CAP-10",
]);

function usage(exitCode = 0) {
  const out = exitCode === 0 ? process.stdout : process.stderr;
  out.write(`usage: fm-dash-serve.mjs [--port <n>]

Serve the FM_HOME capacity dashboard on 127.0.0.1 for a tailnet-only
tailscale serve proxy. Config lives in config/dash.json:
  {"port": 8847, "serve_port": 8443,
   "captain_logins": ["captain@example.com"],
   "read_only": false, "auto_refresh_seconds": 900}
--port overrides the configured port. read_only=true refuses dispatch and
serves the page without send buttons, for running the service before command
consumption is wired up. auto_refresh_seconds reruns the producer on that
interval (and at startup when the dashboard is missing or stale); 0 disables
auto-render and the stale-marker poll. While auto-render is enabled the
service also polls state/dash-inbox/.model-stale (touched by
bin/fm-dash-inbox.sh claim) every 30 seconds and reruns the producer when the
marker is newer than the dashboard, so a claimed click regenerates the model
promptly. Acknowledgment states rendered on the page come from the command
channel itself: a pending inbox record renders its action as sent, an archived
record renders it as received with the claim time, and an archived record
whose click is within the last 6 hours keeps a re-emitted stable action ID
rendered as previously approved or denied instead of a bare verdict control.
Idea suggestions stay additive and never acknowledge persistently. Routes:
  GET  /healthz       liveness, no identity required
  GET  /              dashboard with the interactive layer injected
  GET  /api/pending   pending command count
  POST /api/refresh   rerun bin/fm-capacity.mjs server-side (serialized)
  POST /api/dispatch  validated CAP action, decision answer, idea verdict,
                      parking-lot unpark request, or recurring run-now request
All routes except /healthz require a Tailscale-User-Login header matching a
configured captain login and fail closed otherwise. Dispatch refuses IDs not in
both the served dashboard and the fixed one-click allowlist, refuses an
unpark for any item the served dashboard does not currently list as parked, and
refuses a run-now for any item it does not currently list as recurring.
Browser POSTs must also be same-origin.
`);
  process.exit(exitCode);
}

function log(line) {
  process.stdout.write(`${new Date().toISOString()} ${line}\n`);
}

function readConfig() {
  try {
    const parsed = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
    const logins = Array.isArray(parsed.captain_logins)
      ? parsed.captain_logins.filter((login) => typeof login === "string" && login.trim() !== "")
      : [];
    const port = Number.isInteger(parsed.port) && parsed.port > 0 && parsed.port < 65536 ? parsed.port : null;
    const readOnly = parsed.read_only === true;
    const autoRefreshSeconds = Number.isInteger(parsed.auto_refresh_seconds) && parsed.auto_refresh_seconds >= 0
      ? parsed.auto_refresh_seconds
      : 900;
    return { port, logins, readOnly, autoRefreshSeconds };
  } catch {
    return { port: null, logins: [], readOnly: false, autoRefreshSeconds: 900 };
  }
}

function unescapeHtml(text) {
  return text
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

// The producer-rendered dashboard is the single source of current actions: an
// ID is dispatchable only while the served page actually recommends it.
function readDashboard() {
  let html;
  try {
    html = fs.readFileSync(DASHBOARD, "utf8");
  } catch {
    return null;
  }
  const actions = new Map();
  for (const match of html.matchAll(/data-copy="([^"]*)"/g)) {
    const prompt = unescapeHtml(match[1]);
    const id = (prompt.match(/CAP-\d{2}/) || [])[0];
    if (id && !actions.has(id)) actions.set(id, prompt);
  }
  const generated = (html.match(/generated ([^<]+)</) || [])[1] || "unknown";
  return { html, actions, generated: generated.trim() };
}

function pendingRecords() {
  let names;
  try {
    names = fs.readdirSync(INBOX);
  } catch {
    return [];
  }
  const records = [];
  for (const name of names.sort()) {
    if (!name.endsWith(".json")) continue;
    try {
      const file = path.join(INBOX, name);
      const raw = fs.readFileSync(file, "utf8");
      const record = JSON.parse(raw);
      if (record && typeof record.id === "string") {
        Object.defineProperties(record, {
          _file: { value: file },
          _digest: { value: createHash("sha256").update(raw).digest("hex") },
        });
        records.push(record);
      }
    } catch {
      // An unreadable record still counts as pending for the inbox owner; skip here.
    }
  }
  return records;
}

function enqueueCommand(record) {
  fs.mkdirSync(INBOX, { recursive: true, mode: 0o700 });
  const name = `${Math.floor(Date.now() / 1000)}-${randomBytes(4).toString("hex")}-${record.id}.json`;
  const tmp = path.join(INBOX, `.tmp-${randomBytes(6).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, path.join(INBOX, name));
  return name;
}

function removePendingIfUnchanged(record) {
  try {
    const raw = fs.readFileSync(record._file, "utf8");
    if (createHash("sha256").update(raw).digest("hex") !== record._digest) return false;
    fs.unlinkSync(record._file);
    return true;
  } catch {
    return false;
  }
}

// --- click acknowledgment ---------------------------------------------------
// An acknowledgeable click must never disappear back into an undecided-looking
// button. Source of truth is the durable command channel itself: a record still
// pending in state/dash-inbox/ acknowledges as sent, a record claimed into
// archive/ acknowledges as received (archive mtime is the claim time), and a
// claimed record whose click is still within ACK_PRIOR_WINDOW_MS keeps
// acknowledging a re-emitted stable action ID after the model regenerates.
// Idea suggestions are the additive, non-acknowledgeable exception. This layer
// only reads records; it never executes or mutates fleet state.

function archivedRecords() {
  const archive = path.join(INBOX, "archive");
  let names;
  try {
    names = fs.readdirSync(archive);
  } catch {
    return [];
  }
  const records = [];
  for (const name of names.sort()) {
    if (!name.endsWith(".json")) continue;
    try {
      const file = path.join(archive, name);
      const record = JSON.parse(fs.readFileSync(file, "utf8"));
      if (record && typeof record.id === "string") records.push({ record, claimedAtMs: fs.statSync(file).mtimeMs });
    } catch {
      // An unreadable archived record simply provides no acknowledgment.
    }
  }
  return records;
}

// One durable identity per acknowledgeable action. Idea suggestions stay
// additive and never acknowledge (they must not disable a later verdict).
function ackKey(record) {
  if (record.kind === "decision") return typeof record.decision_identity === "string" ? `decision:${record.decision_identity}` : null;
  if (record.kind === "idea") return record.verdict === "suggest" ? null : `idea:${record.idea}`;
  if (record.kind === "unpark") return typeof record.work_identity === "string" ? `unpark:${record.work_identity}` : null;
  return /^CAP-\d{2}$/.test(record.id) ? `cap:${record.id}` : null;
}

function ackStates(generated) {
  const acks = new Map();
  const now = Date.now();
  for (const { record, claimedAtMs } of archivedRecords()) {
    const key = ackKey(record);
    if (!key) continue;
    const requestedAtMs = Date.parse(record.requested_at || "");
    if (record.dashboard_generated === generated) {
      acks.set(key, {
        status: "claimed",
        requested_at: record.requested_at || null,
        claimed_at: new Date(claimedAtMs).toISOString(),
        verdict: record.verdict || null,
      });
    } else if (Number.isFinite(requestedAtMs) && now - requestedAtMs <= ACK_PRIOR_WINDOW_MS) {
      acks.set(key, { status: "prior", requested_at: record.requested_at, verdict: record.verdict || null });
    }
  }
  for (const record of pendingRecords()) {
    const key = ackKey(record);
    if (!key) continue;
    acks.set(key, { status: "pending", requested_at: record.requested_at || null, verdict: record.verdict || null });
  }
  return acks;
}

// --- read-only detail assembly -------------------------------------------
// Everything below only READS records the home already keeps: the producer's
// refs sidecar, the backlog, task briefs, task metadata, status tails, and
// scout reports. Detail is served only to the authenticated captain.

function readRefs(generated) {
  try {
    const parsed = JSON.parse(fs.readFileSync(REFS, "utf8"));
    if (parsed.schema !== "fm-capacity-refs.v1" || parsed.generated !== generated || typeof parsed.refs !== "object") return null;
    return parsed;
  } catch {
    return null;
  }
}

function readText(file, maxBytes = 65536) {
  try {
    const buffer = fs.readFileSync(file);
    return buffer.subarray(0, maxBytes).toString("utf8");
  } catch {
    return null;
  }
}

// Parse the tasks-axi markdown backlog: "## Section" headers and
// "- [ ] id - Title (annotation) ..." items with indented body lines.
function parseBacklog(file = BACKLOG) {
  const text = readText(file, 262144);
  if (!text) return [];
  const items = [];
  let section = "";
  let current = null;
  for (const line of text.split("\n")) {
    const heading = line.match(/^##\s+(.+)$/);
    if (heading) { section = heading[1].trim(); current = null; continue; }
    const item = line.match(/^- \[([ xX])\] (\S+) - (.*)$/);
    if (item) {
      current = { id: item[2], done: item[1] !== " ", title: item[3].trim(), section, body: [] };
      items.push(current);
      continue;
    }
    if (current && /^\s+\S/.test(line)) current.body.push(line.trim());
    else if (current && line.trim() === "") current.body.push("");
    else current = null;
  }
  return items;
}

// Strip trailing "(key: value)" / "(since date)" tasks-axi annotations from a
// backlog title line; hold reasons are single-line with no parentheses.
function titleAnnotations(rawTitle) {
  const fields = {};
  let title = String(rawTitle || "").trim();
  let match;
  while ((match = title.match(/\s*\((repo|kind|priority|hold|hold-kind|hold-until|since|merged|reported|done)[:\s]\s*([^)]*)\)$/))) {
    fields[match[1]] = match[2].trim();
    title = title.slice(0, match.index).trimEnd();
  }
  return { title, fields };
}

// Parking-lot enrichment for the authenticated captain: resolve each
// data-parked-ref the producer rendered through the current-generation refs
// sidecar, then read the owning home's backlog for the real title, park
// reason, and backlog `since` date. Reads only; the offline artifact itself
// stays opaque.
function parkedEntries(dashboardHtml, refsFile) {
  const entries = [];
  if (!refsFile) return entries;
  const backlogCache = new Map();
  const backlogFor = (owner) => {
    if (!backlogCache.has(owner)) {
      const root = decisionHome(owner);
      backlogCache.set(owner, root ? parseBacklog(path.join(root, "data", "backlog.md")) : []);
    }
    return backlogCache.get(owner);
  };
  for (const match of dashboardHtml.matchAll(/data-parked-ref="(item-\d{2,})"/g)) {
    const ref = match[1];
    const entry = refsFile.refs[ref];
    if (!entry || entry.kind !== "item") continue;
    const separator = entry.value.indexOf("/");
    const owner = entry.value.slice(0, separator);
    const id = entry.value.slice(separator + 1);
    const item = backlogFor(owner).find((row) => row.id === id) || null;
    const parsed = item ? titleAnnotations(item.title) : null;
    entries.push({
      ref,
      id,
      owner,
      title: parsed?.title || id,
      reason: parsed?.fields["hold"] || null,
      since: parsed?.fields["since"] || null,
    });
  }
  return entries;
}

// Recurring enrichment for the authenticated captain: resolve each
// data-recurring-ref the producer rendered through the current-generation refs
// sidecar, then read the owning home's backlog for the real title, schedule
// reason, and next-run date, plus the prior completed run's title, completion
// date, and first recorded artifact link. Reads only; the offline artifact
// itself stays opaque.
function recurringEntries(dashboardHtml, refsFile) {
  const entries = [];
  if (!refsFile) return entries;
  const backlogCache = new Map();
  const backlogFor = (owner) => {
    if (!backlogCache.has(owner)) {
      const root = decisionHome(owner);
      backlogCache.set(owner, root ? parseBacklog(path.join(root, "data", "backlog.md")) : []);
    }
    return backlogCache.get(owner);
  };
  const resolveItem = (ref) => {
    const entry = refsFile.refs[ref];
    if (!entry || entry.kind !== "item") return null;
    const separator = entry.value.indexOf("/");
    return { owner: entry.value.slice(0, separator), id: entry.value.slice(separator + 1) };
  };
  const rowPattern = /data-recurring-ref="(item-\d{2,})" data-next-run="(\d{4}-\d{2}-\d{2})"(?: data-last-run-ref="(item-\d{2,})")?/g;
  for (const match of dashboardHtml.matchAll(rowPattern)) {
    const [, ref, nextRun, lastRef] = match;
    const item = resolveItem(ref);
    if (!item) continue;
    const row = backlogFor(item.owner).find((entry) => entry.id === item.id) || null;
    const parsed = row ? titleAnnotations(row.title) : null;
    let lastRun = null;
    const lastItem = lastRef ? resolveItem(lastRef) : null;
    if (lastItem) {
      const doneRow = backlogFor(lastItem.owner).find((entry) => entry.id === lastItem.id) || null;
      const doneParsed = doneRow ? titleAnnotations(doneRow.title) : null;
      const artifact = doneRow
        ? (`${doneRow.title} ${doneRow.body.join(" ")}`.match(/https:\/\/[^\s"'`<>)\]]+|data\/[^\s"'`<>)\]]+\/report\.md/) || [null])[0]
        : null;
      const reportArtifact = artifact?.startsWith("data/") === true;
      lastRun = {
        id: lastItem.id,
        title: (doneParsed ? doneParsed.title.replace(/https?:\/\/[^\s]+|data\/[^\s]+\/report\.md/g, "").trim() : "") || lastItem.id,
        date: doneParsed?.fields["merged"] || doneParsed?.fields["reported"] || doneParsed?.fields["done"] || null,
        link: reportArtifact ? null : artifact,
        detail_ref: reportArtifact ? lastRef : null,
      };
    }
    entries.push({
      ref,
      id: item.id,
      owner: item.owner,
      title: parsed?.title || item.id,
      reason: parsed?.fields["hold"] || null,
      next: nextRun,
      since: parsed?.fields["since"] || null,
      last_run: lastRun,
    });
  }
  return entries;
}

function briefSections(id) {
  const text = readText(path.join(DATA, id, "brief.md"), 131072);
  if (!text) return { description: null, testPlan: null, raw: null };
  const taskMatch = text.match(/^# Task\s*\n([\s\S]*?)(?=^# |\n# |$(?![\s\S]))/m);
  const description = taskMatch ? taskMatch[1].trim().slice(0, 3000) : null;
  const planMatch = text.match(/^(?:#+\s*)?(?:acceptance criteria|test plan|definition of done)[:\s]*\n([\s\S]*?)(?=^#+ |$(?![\s\S]))/im);
  const testPlan = planMatch ? planMatch[1].trim().slice(0, 1500) : null;
  return { description, testPlan, raw: text };
}

function readMeta(id) {
  const text = readText(path.join(STATE, `${id}.meta`), 8192);
  const meta = {};
  if (!text) return meta;
  for (const line of text.split("\n")) {
    const pair = line.match(/^([a-z_]+)=(.*)$/);
    if (pair) meta[pair[1]] = pair[2];
  }
  return meta;
}

function statusTail(id, lines = 6) {
  const text = readText(path.join(STATE, `${id}.status`), 65536);
  if (!text) return [];
  return text.trim().split("\n").filter(Boolean).slice(-lines);
}

function previewLinks(...texts) {
  const links = new Set();
  for (const text of texts) {
    if (!text) continue;
    for (const match of text.matchAll(/https:\/\/[^\s"'`<>)\]]+\.ts\.net[^\s"'`<>)\]]*/g)) links.add(match[0]);
  }
  return [...links];
}

function decisionRef(entry) {
  const parts = entry.value.split("/");
  if (parts[0] !== "decision") return null;
  if (parts.length >= 4) return { home: parts[1], origin: parts[2], key: parts.slice(3).join("/") };
  if (parts.length === 3) return { home: parts[1], origin: null, key: parts[2] };
  return { home: "main", origin: null, key: parts.slice(1).join("/") };
}

function decisionHome(home) {
  if (home === "main") return FM_HOME;
  const meta = readMeta(home);
  return meta.home ? path.resolve(meta.home) : null;
}

function decisionDocument(home, origin, key) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(key)) return null;
  if (origin !== null && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(origin)) return null;
  const root = decisionHome(home);
  if (!root) return null;
  const file = origin === null
    ? path.join(root, "data", "decisions", `${key}.md`)
    : path.join(root, "data", origin, "decisions", `${key}.md`);
  const text = readText(file, 131072);
  if (!text) return null;
  const title = (text.match(/^#\s+(.+)$/m) || [])[1]?.trim();
  const sections = text.split(/^##\s+Options\s*$/im);
  if (!title || sections.length < 2) return null;
  const context = sections[0].replace(/^#\s+.*$/m, "").trim().slice(0, 4000) || null;
  const options = [];
  let current = null;
  for (const line of sections.slice(1).join("\n## Options\n").split("\n")) {
    const marker = line.match(/^\s*-\s+(?:\[recommended\]\s*)?(.+?)(?:\s+-\s+(.+))?\s*$/i);
    if (marker) {
      current = {
        text: marker[1].trim(),
        impact: (marker[2] || "").trim(),
        recommended: /^\s*-\s+\[recommended\]/i.test(line),
      };
      options.push(current);
      continue;
    }
    if (current && /^\s{2,}\S/.test(line)) current.impact = `${current.impact} ${line.trim()}`.trim();
  }
  const boundedOptions = options
    .filter((option) => option.text && option.impact)
    .slice(0, 20)
    .map((option) => ({ ...option, text: option.text.slice(0, 300), impact: option.impact.slice(0, 1200) }));
  if (!context || boundedOptions.length === 0) return null;
  return {
    title,
    context,
    options: boundedOptions,
  };
}

function refDisplayMap(refsFile, acks = null) {
  const display = {};
  for (const [ref, entry] of Object.entries(refsFile.refs)) {
    if (entry.kind === "project") display[ref] = { t: "project", label: entry.value };
    else if (entry.kind === "home") display[ref] = { t: "home", label: entry.value };
    else if (entry.kind === "item") {
      const separator = entry.value.indexOf("/");
      const owner = entry.value.slice(0, separator);
      const decision = decisionRef(entry);
      const id = decision ? `${decision.origin ? `${decision.origin}/` : ""}${decision.key}` : entry.value.slice(separator + 1);
      display[ref] = owner === "decision"
        ? { t: "decision", label: id }
        : { t: "work", label: id, owner };
      if (decision && acks) {
        const ack = acks.get(`decision:${decision.home}/${decision.origin || ""}/${decision.key}`);
        if (ack) display[ref].ack = ack;
      }
    }
  }
  return display;
}

function assembleDetail(ref) {
  const dashboard = readDashboard();
  const refsFile = dashboard ? readRefs(dashboard.generated) : null;
  const entry = refsFile?.refs?.[ref];
  if (!entry || entry.kind !== "item") return null;
  const separator = entry.value.indexOf("/");
  const owner = entry.value.slice(0, separator);
  const decision = decisionRef(entry);
  const id = decision ? decision.key : entry.value.slice(separator + 1);
  const holdId = decision?.origin ? `${decision.origin}-decision-${decision.key}` : id;
  const backlogItem = parseBacklog().find((item) => item.id === holdId) || null;

  if (owner === "decision") {
    const document = decisionDocument(decision.home, decision.origin, decision.key);
    return {
      type: "decision",
      ref,
      id,
      decision_home: decision.home,
      decision_origin: decision.origin,
      decision_identity: `${decision.home}/${decision.origin || ""}/${decision.key}`,
      title: document?.title || backlogItem?.title || id,
      description: document?.context || null,
      options: document?.options || [],
      recent: statusTail(decision.origin || id),
      note: document ? null : "This legacy decision has no structured options document; answer it in captain chat.",
    };
  }
  if (owner !== "main") {
    const root = decisionHome(owner);
    const report = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id) && root
      ? readText(path.join(root, "data", id, "report.md"), 8192)
      : null;
    return {
      type: "work",
      ref,
      id,
      owner,
      title: backlogItem ? backlogItem.title : id,
      note: "This work lives with a domain supervisor; its instructions and records are in that home.",
      report_excerpt: report ? report.trim().slice(0, 1200) : null,
    };
  }
  const brief = briefSections(id);
  const meta = readMeta(id);
  const report = readText(path.join(DATA, id, "report.md"), 8192);
  const recent = statusTail(id);
  const backlogBody = backlogItem ? backlogItem.body.join("\n") : "";
  const testPlan = brief.testPlan
    || (backlogBody.match(/acceptance criteria[:\s]*([\s\S]{0,600})/i) || [])[1]?.trim()
    || null;
  return {
    type: "work",
    ref,
    id,
    owner: "main",
    title: backlogItem ? backlogItem.title : id,
    description: brief.description || backlogBody.slice(0, 2000) || null,
    test_plan: testPlan,
    pr: meta.pr || null,
    project: meta.project ? path.basename(meta.project) : null,
    delivery_mode: meta.mode || null,
    previews: previewLinks(brief.raw, report, recent.join("\n")),
    report_excerpt: report ? report.trim().slice(0, 1200) : null,
    recent,
  };
}

// Parse data/ideas/idea-backlog.md generously: any heading or list line
// carrying an IDEA-XX token starts an idea; following lines up to the next
// idea are its concept summary.
function parseIdeas() {
  const text = readText(IDEAS, 262144);
  if (!text) return [];
  const ideas = [];
  let current = null;
  for (const line of text.split("\n")) {
    const marker = line.match(/^\s*(?:#{1,4}\s*|[-*]\s+|\d+[.)]\s+)?.*?\b(IDEA-\d+)\b[:\s-]*(.*)$/);
    if (marker && !ideas.some((idea) => idea.id === marker[1])) {
      current = { id: marker[1], title: marker[2].trim() || marker[1], summary: [] };
      ideas.push(current);
      continue;
    }
    if (current && !/\bIDEA-\d+\b/.test(line)) current.summary.push(line);
  }
  return ideas.map((idea) => ({ id: idea.id, title: idea.title, summary: idea.summary.join("\n").trim().slice(0, 3000) }));
}

function ideaDetail(id) {
  const idea = parseIdeas().find((entry) => entry.id === id);
  if (!idea) return null;
  const pitch = /^IDEA-\d+$/.test(id) ? readText(path.join(PITCHES, `${id}.md`), 131072) : null;
  return {
    type: "idea",
    id: idea.id,
    title: idea.title,
    pitch: pitch ? pitch.trim().slice(0, 12000) : null,
    description: pitch ? null : idea.summary || null,
  };
}

let refreshing = null;
function runRefresh() {
  if (refreshing) return refreshing;
  const extraArgs = (process.env.FM_DASH_CAPACITY_ARGS || "").split(" ").filter(Boolean);
  const startedAtMs = Date.now();
  refreshing = new Promise((resolve) => {
    const child = spawn(process.execPath, [CAPACITY, "--refs", REFS, ...extraArgs], {
      cwd: ROOT,
      env: { ...process.env, FM_HOME },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => child.kill("SIGKILL"), REFRESH_TIMEOUT_MS);
    child.on("close", (code) => {
      clearTimeout(timer);
      refreshing = null;
      if (code === 0) resolve({ ok: true, startedAtMs });
      else resolve({ ok: false, startedAtMs, error: stderr.trim().slice(0, 500) || `capacity producer exited ${code}` });
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      refreshing = null;
      resolve({ ok: false, startedAtMs, error: error.message });
    });
  });
  return refreshing;
}

let usageCache = null;
let usageProbe = null;
function probeUsage() {
  const now = Date.now();
  if (usageCache && now - usageCache.at < QUOTA_CACHE_MS) return Promise.resolve(usageCache.value);
  if (usageProbe) return usageProbe;
  usageProbe = new Promise((resolve) => {
    const child = spawn(QUOTA_AXI, ["--json"], { cwd: ROOT, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    let size = 0;
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      usageCache = { at: Date.now(), value };
      usageProbe = null;
      resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({ status: "unavailable", providers: [] });
    }, QUOTA_TIMEOUT_MS);
    child.stdout.on("data", (chunk) => {
      size += chunk.length;
      if (size <= 1024 * 1024) chunks.push(chunk);
    });
    child.on("error", () => {
      clearTimeout(timer);
      finish({ status: "unavailable", providers: [] });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0 || size > 1024 * 1024) {
        finish({ status: "unavailable", providers: [] });
        return;
      }
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (parsed.schemaVersion !== 2 || !Array.isArray(parsed.providers)) throw new Error("unsupported schema");
        const allowed = new Set(["claude", "codex", "grok"]);
        const providers = parsed.providers
          .filter((provider) => allowed.has(provider?.provider))
          .map((provider) => ({
            provider: provider.provider,
            label: typeof provider.label === "string" ? provider.label.slice(0, 80) : provider.provider,
            windows: Array.isArray(provider.windows)
              ? provider.windows.filter((window) =>
                typeof window?.label === "string"
                && Number.isFinite(window.percentUsed)
                && window.percentUsed >= 0
                && window.percentUsed <= 100
                && typeof window.resetsAt === "string"
                && Number.isFinite(Date.parse(window.resetsAt))
              ).slice(0, 8).map((window) => ({
                label: window.label.slice(0, 100),
                percentUsed: window.percentUsed,
                resetsAt: window.resetsAt,
              }))
              : [],
          }));
        finish({ status: "ok", providers });
      } catch {
        finish({ status: "unavailable", providers: [] });
      }
    });
  });
  return usageProbe;
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(body) });
  res.end(body);
}

function sendHtml(res, status, html) {
  res.writeHead(status, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
  res.end(html);
}

function requesterLogin(req) {
  const value = req.headers["tailscale-user-login"];
  return typeof value === "string" ? value.trim() : "";
}

function authorized(req, config) {
  const login = requesterLogin(req);
  return login !== "" && config.logins.includes(login);
}

function sameOriginPost(req) {
  const origin = req.headers.origin;
  const fetchSite = req.headers["sec-fetch-site"];
  if (origin === undefined && fetchSite === undefined) return true;
  if (typeof origin !== "string" || fetchSite !== "same-origin") return false;
  try {
    return new URL(origin).host === req.headers.host;
  } catch {
    return false;
  }
}

function inlineScriptJson(value) {
  return JSON.stringify(value).replace(/[<>&\u2028\u2029]/g, (character) => {
    const escapes = { "<": "\\u003c", ">": "\\u003e", "&": "\\u0026", "\u2028": "\\u2028", "\u2029": "\\u2029" };
    return escapes[character];
  });
}

// Injected interactive layer. It only talks to this service's own API; the
// underlying producer file stays untouched on disk and keeps working offline.
// When the producer's refs sidecar is present the layer also de-anonymizes the
// page for the authenticated captain: opaque item/project/home references get
// their real names, and work items and decisions become clickable detail views.
function interactiveLayer(dispatchable, pending, generated, readOnly, extras) {
  const config = inlineScriptJson({
    dispatchable,
    pending,
    generated,
    readOnly: readOnly === true,
    refs: extras?.refs || {},
    ideas: extras?.ideas || [],
    parked: extras?.parked || [],
    recurring: extras?.recurring || [],
    usage: extras?.usage || { status: "unavailable", providers: [] },
    degraded: extras?.degraded === true,
    acks: extras?.acks || {},
  });
  return `<style>
  .fmdash-bar{display:flex;justify-content:space-between;align-items:center;gap:.6rem 1.5rem;flex-wrap:wrap;padding:.6rem clamp(1rem,6vw,5rem);border-bottom:1px solid var(--line);background:var(--bg)}
  .fmdash-bar .fmdash-live{font-weight:800;font-size:.72rem;letter-spacing:.16em;text-transform:uppercase;color:var(--muted)}
  .fmdash-bar .fmdash-live::before{content:"";display:inline-block;width:.55rem;height:.55rem;border-radius:50%;background:var(--good);margin-right:.5rem;vertical-align:baseline}
  .fmdash-bar button{border:1px solid var(--ink);background:var(--ink);color:var(--bg);font-weight:700;padding:.45rem .9rem;cursor:pointer;font-size:.8rem}
  .fmdash-bar button[disabled]{opacity:.55;cursor:progress}
  .fmdash-pending{font-size:.76rem;color:var(--ink2)}
  .fmdash-send{border:1px solid var(--ink);background:transparent;color:var(--ink);font-weight:700;padding:.5rem .9rem;cursor:pointer;font-size:.82rem;grid-column:2}
  .fmdash-send[disabled]{opacity:.55;cursor:default}
  .fmdash-chat{color:var(--muted);font-size:.76rem;align-self:center}
  .fmdash-degraded{background:var(--crit);color:#fff;font-weight:800;font-size:.85rem;letter-spacing:.05em;padding:.7rem clamp(1rem,6vw,5rem)}
  .fmdash-click{cursor:pointer;text-decoration:underline;text-decoration-color:var(--muted);text-underline-offset:.22em}
  .fmdash-click:hover,.fmdash-click:focus-visible{color:var(--blue);text-decoration-color:var(--blue)}
  .fmdash-overlay{position:fixed;inset:0;background:color-mix(in srgb,var(--bg) 55%,transparent);backdrop-filter:blur(2px);display:grid;place-items:start center;overflow-y:auto;padding:clamp(1rem,6vh,4rem) 1rem;z-index:50}
  .fmdash-panel{background:var(--bg);border:1px solid var(--line);border-top:.55rem solid var(--sev,var(--blue));max-width:46rem;width:100%;padding:clamp(1.25rem,3vw,2.25rem)}
  .fmdash-panel .fmdash-kicker{display:flex;justify-content:space-between;gap:1rem;font-weight:800;font-size:.72rem;letter-spacing:.16em;text-transform:uppercase;color:var(--muted)}
  .fmdash-panel h2{font-size:clamp(1.4rem,3vw,2rem);font-weight:800;letter-spacing:-.02em;margin-top:.5rem;overflow-wrap:anywhere}
  .fmdash-panel h3{font-size:.74rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin-top:1.4rem;border-bottom:1px solid var(--hair);padding-bottom:.35rem}
  .fmdash-panel p,.fmdash-panel pre,.fmdash-panel li{color:var(--ink2);font-size:.92rem;margin-top:.5rem}
  .fmdash-panel pre{white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem;border:1px solid var(--hair);padding:.6rem .8rem;overflow-x:auto}
  .fmdash-panel a{overflow-wrap:anywhere}
  .fmdash-option{border-bottom:1px solid var(--hair);padding:.7rem 0;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:.6rem;align-items:start}
  .fmdash-option strong{color:var(--ink);font-size:.95rem}
  .fmdash-option small{display:block;color:var(--muted);margin-top:.25rem}
  .fmdash-close{border:1px solid var(--ink);background:transparent;color:var(--ink);font-weight:700;padding:.4rem .8rem;cursor:pointer;font-size:.78rem}
  .fmdash-usage{border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
  .fmdash-usage-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1rem;margin-top:1rem}
  .fmdash-usage-card{min-width:0;border-top:.45rem solid var(--blue);padding:.8rem 0}
  .fmdash-usage-card h3{font-size:.76rem;letter-spacing:.14em;text-transform:uppercase}
  .fmdash-window{margin-top:.7rem}
  .fmdash-window-head{display:flex;justify-content:space-between;gap:.8rem;font-size:.8rem;color:var(--ink2)}
  .fmdash-meter{height:.65rem;background:var(--hair);margin-top:.3rem}
  .fmdash-meter span{display:block;height:100%;background:var(--blue)}
  .fmdash-reset{font-size:.72rem;color:var(--muted);margin-top:.25rem}
  .fmdash-custom{width:100%;margin-top:.7rem;padding:.6rem;background:var(--bg);color:var(--ink);border:1px solid var(--hair)}
  .fmdash-unpark,.fmdash-runnow{margin-left:.8rem;padding:.3rem .7rem;font-size:.74rem}
  .fmdash-ack{display:inline-block;border:1px solid var(--good);color:var(--good);font-weight:700;font-size:.76rem;padding:.35rem .7rem;align-self:center;grid-column:2}
  .fmdash-ack-chip{margin-left:.6rem;padding:.15rem .5rem;font-size:.7rem;grid-column:auto}
  @media(max-width:760px){.fmdash-usage-grid{grid-template-columns:1fr}}
  </style>
  <script>
  (() => {
    const cfg = ${config};
    const bar = document.createElement("div");
    bar.className = "fmdash-bar";
    bar.innerHTML = '<span class="fmdash-live">Live over your tailnet</span>'
      + '<span class="fmdash-pending"></span>'
      + '<button type="button" class="fmdash-refresh">Refresh capacity</button>';
    document.body.prepend(bar);
    if (cfg.degraded) {
      const warn = document.createElement("div");
      warn.className = "fmdash-degraded";
      warn.setAttribute("role", "alert");
      warn.textContent = "RENDER DEGRADED - most worker states read as unknown, so this page may not reflect reality. The service environment is likely missing its state-reader tools; fix the environment and refresh.";
      bar.after(warn);
    }
    // Zero copy-prompt affordances on the served page: every producer copy
    // button is removed here and, where eligible, replaced by direct dispatch.
    const copyButtons = [...document.querySelectorAll("button[data-copy]")];
    const pendingEl = bar.querySelector(".fmdash-pending");
    const showPending = (n) => {
      pendingEl.textContent = cfg.readOnly
        ? ""
        : (n > 0
          ? n + " command" + (n === 1 ? "" : "s") + " queued for firstmate"
          : "No commands queued");
    };
    showPending(cfg.pending);
    const refreshButton = bar.querySelector(".fmdash-refresh");
    refreshButton.addEventListener("click", async () => {
      refreshButton.disabled = true;
      refreshButton.textContent = "Refreshing…";
      try {
        const res = await fetch("/api/refresh", { method: "POST" });
        const out = await res.json();
        if (out.status === "refreshed") { location.reload(); return; }
        refreshButton.textContent = out.status === "busy" ? "Already refreshing…" : "Refresh failed";
      } catch { refreshButton.textContent = "Refresh failed"; }
      setTimeout(() => { refreshButton.disabled = false; refreshButton.textContent = "Refresh capacity"; }, 4000);
    });
    const postJson = (body) => fetch("/api/dispatch", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    // Acknowledged-action presentation: a clicked action never falls back to an
    // undecided-looking control. States mirror the durable command channel:
    // pending record = sent, claimed record = received, recent claim behind a
    // regenerated model = previously approved.
    const ackLabel = (ack) => {
      if (!ack || ack.status === "pending") return "Sent to firstmate - in progress";
      if (ack.status === "claimed") {
        return "Received - being worked" + (ack.claimed_at ? " since " + new Date(ack.claimed_at).toLocaleString() : "");
      }
      const verb = ack.verdict === "deny" ? "Previously denied" : "Previously approved";
      return verb + (ack.requested_at ? " " + new Date(ack.requested_at).toLocaleString() : "") + " - in progress";
    };
    const ackNode = (ack, extraClass) => {
      const note = document.createElement("span");
      note.className = "fmdash-ack" + (extraClass ? " " + extraClass : "");
      note.textContent = ackLabel(ack);
      return note;
    };
    const acknowledge = (button) => {
      button.disabled = true;
      button.classList.add("fmdash-ack");
      button.textContent = ackLabel(null);
    };
    const usageSection = document.createElement("section");
    usageSection.className = "band fmdash-usage";
    usageSection.setAttribute("aria-label", "Subscription usage");
    const usageWrap = document.createElement("div");
    usageWrap.className = "wrap";
    usageWrap.innerHTML = '<p class="kicker">Subscription usage</p>';
    const usageGrid = document.createElement("div");
    usageGrid.className = "fmdash-usage-grid";
    const distance = (iso) => {
      const milliseconds = Date.parse(iso) - Date.now();
      if (milliseconds <= 0) return "reset due";
      const minutes = Math.ceil(milliseconds / 60000);
      if (minutes < 60) return "resets in " + minutes + "m";
      const hours = Math.ceil(minutes / 60);
      if (hours < 48) return "resets in " + hours + "h";
      return "resets in " + Math.ceil(hours / 24) + "d";
    };
    if (cfg.usage.status === "ok" && cfg.usage.providers.some((provider) => provider.windows.length)) {
      cfg.usage.providers.forEach((provider) => {
        if (!provider.windows.length) return;
        const card = document.createElement("article");
        card.className = "fmdash-usage-card";
        card.appendChild(textBlock("h3", provider.label));
        provider.windows.forEach((window) => {
          const item = document.createElement("div");
          item.className = "fmdash-window";
          const head = document.createElement("div");
          head.className = "fmdash-window-head";
          head.appendChild(textBlock("span", window.label));
          head.appendChild(textBlock("strong", Math.round(window.percentUsed) + "% used"));
          const meter = document.createElement("div");
          meter.className = "fmdash-meter";
          const fill = document.createElement("span");
          fill.style.width = window.percentUsed + "%";
          meter.appendChild(fill);
          const reset = textBlock("div", distance(window.resetsAt) + " · " + new Date(window.resetsAt).toLocaleString());
          reset.className = "fmdash-reset";
          item.appendChild(head);
          item.appendChild(meter);
          item.appendChild(reset);
          card.appendChild(item);
        });
        usageGrid.appendChild(card);
      });
    } else {
      usageGrid.appendChild(textBlock("p", "Subscription usage is temporarily unavailable."));
    }
    usageWrap.appendChild(usageGrid);
    usageSection.appendChild(usageWrap);
    const meterBand = document.querySelector(".band-meter");
    const mainForUsage = document.querySelector("main");
    if (meterBand) meterBand.after(usageSection);
    else if (mainForUsage) mainForUsage.appendChild(usageSection);
    // De-anonymize known references for the authenticated captain and open
    // rich detail views on click. The server refuses detail and approval
    // requests it cannot validate, so this layer is presentation only.
    const clickableTypes = { work: 1, decision: 1 };
    const refTokens = Object.keys(cfg.refs);
    if (refTokens.length) {
      const tokenPattern = /\\b(?:item|project|home)-\\d{2,}\\b/g;
      document.querySelectorAll(".item-id").forEach((chip) => {
        const token = (chip.textContent || "").trim();
        const entry = cfg.refs[token];
        if (!entry) return;
        chip.textContent = entry.label;
        if (entry.ack) chip.after(ackNode(entry.ack, "fmdash-ack-chip"));
        if (clickableTypes[entry.t]) {
          chip.classList.add("fmdash-click");
          chip.setAttribute("role", "button");
          chip.setAttribute("tabindex", "0");
          chip.setAttribute("aria-label", "Open detail for " + entry.label);
          const open = () => openDetail(token, entry);
          chip.addEventListener("click", (event) => { event.stopPropagation(); open(); });
          chip.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); open(); } });
        }
      });
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      const textNodes = [];
      while (walker.nextNode()) textNodes.push(walker.currentNode);
      textNodes.forEach((node) => {
        const value = node.nodeValue;
        if (!value || !tokenPattern.test(value)) { tokenPattern.lastIndex = 0; return; }
        tokenPattern.lastIndex = 0;
        node.nodeValue = value.replace(tokenPattern, (token) => (cfg.refs[token] ? cfg.refs[token].label : token));
      });
    }
    function section(title, node) {
      if (!node) return [];
      const heading = document.createElement("h3");
      heading.textContent = title;
      return [heading, node];
    }
    function textBlock(tag, text) {
      if (!text) return null;
      const el = document.createElement(tag);
      el.textContent = text;
      return el;
    }
    function linkBlock(urls) {
      if (!urls || !urls.length) return null;
      const list = document.createElement("ul");
      urls.forEach((url) => {
        const li = document.createElement("li");
        const a = document.createElement("a");
        a.href = url;
        a.textContent = url;
        li.appendChild(a);
        list.appendChild(li);
      });
      return list;
    }
    async function approveDecision(ref, index, button, key) {
      button.disabled = true;
      button.textContent = "Sending…";
      try {
        const res = await postJson({ ref, option: index });
        const out = await res.json();
        if (out.status === "queued" || out.status === "already-queued") {
          acknowledge(button);
          showPending(out.pending);
          return;
        }
        button.textContent = "Refused";
        button.disabled = false;
      } catch { button.textContent = "Failed"; button.disabled = false; }
    }
    async function answerDecision(ref, answer, button) {
      button.disabled = true;
      button.textContent = "Sending…";
      try {
        const res = await postJson({ ref, answer });
        const out = await res.json();
        if (out.status === "queued" || out.status === "already-queued") {
          acknowledge(button);
          showPending(out.pending);
          return;
        }
        button.textContent = "Refused";
        button.disabled = false;
      } catch { button.textContent = "Failed"; button.disabled = false; }
    }
    async function openDetail(ref, entry) {
      const overlay = document.createElement("div");
      overlay.className = "fmdash-overlay";
      const panel = document.createElement("div");
      panel.className = "fmdash-panel";
      panel.setAttribute("role", "dialog");
      panel.setAttribute("aria-modal", "true");
      panel.setAttribute("aria-label", entry.label + " detail");
      overlay.appendChild(panel);
      const close = () => { overlay.remove(); document.removeEventListener("keydown", onKey); };
      const onKey = (event) => { if (event.key === "Escape") close(); };
      overlay.addEventListener("click", (event) => { if (event.target === overlay) close(); });
      document.addEventListener("keydown", onKey);
      const kicker = document.createElement("div");
      kicker.className = "fmdash-kicker";
      kicker.textContent = entry.t === "decision" ? "Open decision" : "Work item";
      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.className = "fmdash-close";
      closeButton.textContent = "Close";
      closeButton.addEventListener("click", close);
      kicker.appendChild(closeButton);
      panel.appendChild(kicker);
      panel.appendChild(textBlock("h2", entry.label));
      panel.appendChild(textBlock("p", "Loading detail…"));
      document.body.appendChild(overlay);
      closeButton.focus();
      let detail = null;
      try {
        const res = await fetch("/api/detail?ref=" + encodeURIComponent(ref));
        if (res.ok) detail = await res.json();
      } catch { /* handled below */ }
      panel.replaceChildren(kicker);
      if (!detail) {
        panel.appendChild(textBlock("h2", entry.label));
        panel.appendChild(textBlock("p", "No further recorded detail is available for this entry."));
        return;
      }
      panel.appendChild(textBlock("h2", detail.title || detail.id));
      if (detail.title && detail.title !== detail.id) panel.appendChild(textBlock("p", detail.id));
      if (detail.note) panel.appendChild(textBlock("p", detail.note));
      section("What it is", textBlock("pre", detail.description)).forEach((el) => panel.appendChild(el));
      section("Test plan", textBlock("pre", detail.test_plan)).forEach((el) => panel.appendChild(el));
      if (detail.pr) section("Pull request", linkBlock([detail.pr])).forEach((el) => panel.appendChild(el));
      section("Tailnet previews", linkBlock(detail.previews)).forEach((el) => panel.appendChild(el));
      const facts = [detail.project ? "Project: " + detail.project : null, detail.delivery_mode ? "Delivery: " + detail.delivery_mode : null].filter(Boolean).join(" · ");
      if (facts) panel.appendChild(textBlock("p", facts));
      section("Report excerpt", textBlock("pre", detail.report_excerpt)).forEach((el) => panel.appendChild(el));
      if (detail.options && detail.options.length) {
        const heading = document.createElement("h3");
        heading.textContent = "Options";
        panel.appendChild(heading);
        detail.options.forEach((option, index) => {
          const row = document.createElement("div");
          row.className = "fmdash-option";
          const body = document.createElement("div");
          const label = document.createElement("strong");
          label.textContent = option.recommended ? "Recommended · " + option.text : option.text;
          body.appendChild(label);
          if (option.impact) {
            const impact = document.createElement("small");
            impact.textContent = option.impact;
            body.appendChild(impact);
          }
          row.appendChild(body);
          if (!cfg.readOnly && !detail.ack) {
            const approve = document.createElement("button");
            approve.type = "button";
            approve.className = "fmdash-send";
            approve.textContent = "Approve";
            approve.setAttribute("aria-label", "Approve: " + option.text);
            approve.addEventListener("click", () => approveDecision(ref, index, approve, detail.id));
            row.appendChild(approve);
          }
          panel.appendChild(row);
        });
        if (detail.ack) {
          panel.appendChild(ackNode(detail.ack));
          panel.appendChild(textBlock("p", "Your answer is already with firstmate; anything further can go through chat."));
        }
        if (!cfg.readOnly && !detail.ack) panel.appendChild(textBlock("p", "An approval here is your routine decision only; anything destructive or irreversible still gets re-confirmed with you in chat."));
        if (!cfg.readOnly && !detail.ack) {
          const custom = document.createElement("textarea");
          custom.className = "fmdash-custom";
          custom.rows = 4;
          custom.maxLength = 2000;
          custom.placeholder = "Or give firstmate a custom answer…";
          custom.setAttribute("aria-label", "Custom answer for " + detail.id);
          const sendCustom = document.createElement("button");
          sendCustom.type = "button";
          sendCustom.className = "fmdash-send";
          sendCustom.textContent = "Send custom answer";
          sendCustom.addEventListener("click", () => {
            if (custom.value.trim()) answerDecision(ref, custom.value.trim(), sendCustom);
          });
          panel.appendChild(custom);
          panel.appendChild(sendCustom);
        }
      } else if (detail.type === "decision") {
        panel.appendChild(textBlock("p", "This decision has no structured options on record; answer it in chat."));
      }
      section("Recent activity", linkBlock(null) || textBlock("pre", (detail.recent || []).join("\\n"))).forEach((el) => panel.appendChild(el));
    }
    // Ideas: rendered from data/ideas/idea-backlog.md; each idea opens its
    // pitch with approve / deny / add-suggestions controls that only enqueue
    // captain messages for firstmate.
    if (cfg.ideas.length) {
      const ideasSection = document.createElement("section");
      ideasSection.className = "band band-quiet";
      ideasSection.setAttribute("aria-label", "Ideas");
      const wrap = document.createElement("div");
      wrap.className = "wrap";
      const heading = document.createElement("h2");
      heading.className = "qhead";
      heading.textContent = "Ideas · awaiting your verdict";
      wrap.appendChild(heading);
      const list = document.createElement("ul");
      list.className = "mlist";
      cfg.ideas.forEach((idea) => {
        const row = document.createElement("li");
        row.className = "mrow";
        const chip = document.createElement("span");
        chip.className = "item-id fmdash-click";
        chip.textContent = idea.id;
        chip.setAttribute("role", "button");
        chip.setAttribute("tabindex", "0");
        chip.setAttribute("aria-label", "Open pitch for " + idea.id);
        const title = document.createElement("span");
        title.className = "mreason";
        title.textContent = idea.title;
        const open = () => openIdea(idea);
        chip.addEventListener("click", (event) => { event.stopPropagation(); open(); });
        chip.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); open(); } });
        row.addEventListener("click", open);
        row.style.cursor = "pointer";
        row.appendChild(chip);
        row.appendChild(title);
        list.appendChild(row);
      });
      wrap.appendChild(list);
      ideasSection.appendChild(wrap);
      const footer = document.querySelector("footer");
      const main = document.querySelector("main");
      if (main) main.appendChild(ideasSection);
      else if (footer) footer.before(ideasSection);
    }
    async function sendIdeaVerdict(id, verdict, suggestion, button) {
      button.disabled = true;
      const original = button.textContent;
      button.textContent = "Sending…";
      try {
        const res = await postJson({ idea: id, verdict, suggestion });
        const out = await res.json();
        if (out.status === "queued" || out.status === "replaced" || out.status === "already-queued") {
          if (verdict === "suggest") button.textContent = "Suggestions sent";
          else acknowledge(button);
          showPending(out.pending);
          return true;
        }
        button.textContent = "Refused";
        button.disabled = false;
      } catch { button.textContent = original; button.disabled = false; }
      return false;
    }
    async function openIdea(idea) {
      const overlay = document.createElement("div");
      overlay.className = "fmdash-overlay";
      const panel = document.createElement("div");
      panel.className = "fmdash-panel";
      panel.setAttribute("role", "dialog");
      panel.setAttribute("aria-modal", "true");
      panel.setAttribute("aria-label", idea.id + " pitch");
      overlay.appendChild(panel);
      const close = () => { overlay.remove(); document.removeEventListener("keydown", onKey); };
      const onKey = (event) => { if (event.key === "Escape") close(); };
      overlay.addEventListener("click", (event) => { if (event.target === overlay) close(); });
      document.addEventListener("keydown", onKey);
      const kicker = document.createElement("div");
      kicker.className = "fmdash-kicker";
      kicker.textContent = "Idea pitch";
      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.className = "fmdash-close";
      closeButton.textContent = "Close";
      closeButton.addEventListener("click", close);
      kicker.appendChild(closeButton);
      panel.appendChild(kicker);
      panel.appendChild(textBlock("h2", idea.id + " — " + idea.title));
      panel.appendChild(textBlock("p", "Loading pitch…"));
      document.body.appendChild(overlay);
      closeButton.focus();
      let detail = null;
      try {
        const res = await fetch("/api/detail?idea=" + encodeURIComponent(idea.id));
        if (res.ok) detail = await res.json();
      } catch { /* handled below */ }
      panel.replaceChildren(kicker);
      panel.appendChild(textBlock("h2", idea.id + " — " + idea.title));
      const pitchText = detail && (detail.pitch || detail.description);
      panel.appendChild(textBlock("pre", pitchText || "No pitch or concept summary is on file for this idea."));
      if (cfg.readOnly) return;
      const ideaAck = detail && detail.ack;
      const controls = document.createElement("div");
      controls.className = "fmdash-option";
      const buttons = document.createElement("div");
      if (ideaAck) {
        buttons.appendChild(ackNode(ideaAck, "fmdash-ack-chip"));
      } else {
        const approve = document.createElement("button");
        approve.type = "button";
        approve.className = "fmdash-send";
        approve.textContent = "Approve";
        approve.addEventListener("click", () => sendIdeaVerdict(idea.id, "approve", null, approve));
        const deny = document.createElement("button");
        deny.type = "button";
        deny.className = "fmdash-send";
        deny.textContent = "Deny";
        deny.style.marginLeft = ".6rem";
        deny.addEventListener("click", () => sendIdeaVerdict(idea.id, "deny", null, deny));
        buttons.appendChild(approve);
        buttons.appendChild(deny);
      }
      const suggest = document.createElement("button");
      suggest.type = "button";
      suggest.className = "fmdash-send";
      suggest.textContent = "Add suggestions";
      suggest.style.marginLeft = ".6rem";
      buttons.appendChild(suggest);
      controls.appendChild(buttons);
      panel.appendChild(controls);
      panel.appendChild(textBlock("p", ideaAck
        ? "Your verdict is already with firstmate; suggestions stay welcome and additive."
        : "Approving asks firstmate to create the work item(s) through the normal backlog lifecycle; nothing runs from this page."));
      suggest.addEventListener("click", () => {
        if (panel.querySelector("textarea")) return;
        const box = document.createElement("textarea");
        box.rows = 4;
        box.style.width = "100%";
        box.style.marginTop = ".6rem";
        box.setAttribute("aria-label", "Suggestions for " + idea.id);
        box.placeholder = "Your suggestions for this idea…";
        const send = document.createElement("button");
        send.type = "button";
        send.className = "fmdash-send";
        send.style.marginTop = ".5rem";
        send.textContent = "Send suggestions";
        send.addEventListener("click", async () => {
          if (!box.value.trim()) return;
          const ok = await sendIdeaVerdict(idea.id, "suggest", box.value.trim(), send);
          if (ok) box.disabled = true;
        });
        panel.appendChild(box);
        panel.appendChild(send);
        box.focus();
      });
    }
    // Parking lot: enrich the collapsed parked rows with the real title and
    // park reason, and add the unpark request control. Unpark only queues a
    // command record; firstmate lifts the hold through the normal backlog
    // lifecycle.
    cfg.parked.forEach((info) => {
      const row = document.querySelector('[data-parked-ref="' + info.ref + '"]');
      if (!row) return;
      const copy = row.querySelector(".parked-copy");
      if (copy) {
        const reason = info.reason ? "Parked: " + info.reason : copy.textContent;
        copy.textContent = (info.title && info.title !== info.id ? info.title + " - " : "") + reason;
      }
      const meta = row.querySelector(".mmeta");
      if (meta && info.since) meta.textContent = "on the books since " + info.since;
      if (cfg.readOnly) return;
      if (info.ack) {
        (row.querySelector(".mreason") || row).appendChild(ackNode(info.ack, "fmdash-ack-chip"));
        return;
      }
      const unpark = document.createElement("button");
      unpark.type = "button";
      unpark.className = "fmdash-send fmdash-unpark";
      unpark.textContent = "Unpark";
      unpark.setAttribute("aria-label", "Unpark " + (info.title || info.id));
      unpark.addEventListener("click", async (event) => {
        event.stopPropagation();
        unpark.disabled = true;
        unpark.textContent = "Sending…";
        try {
          const res = await postJson({ unpark: info.ref });
          const out = await res.json();
          if (out.status === "queued" || out.status === "already-queued") {
            acknowledge(unpark);
            showPending(out.pending);
            return;
          }
          unpark.textContent = "Refused";
          unpark.disabled = false;
        } catch { unpark.textContent = "Failed"; unpark.disabled = false; }
      });
      (row.querySelector(".mreason") || row).appendChild(unpark);
    });
    // Recurring: enrich each scheduled row with the real title, schedule
    // reason, and last completed run (with its recorded artifact link), and
    // add the run-now request control. Run now only queues a command record;
    // firstmate re-resolves and dispatches through the normal lifecycle.
    cfg.recurring.forEach((info) => {
      const row = document.querySelector('[data-recurring-ref="' + info.ref + '"]');
      if (!row) return;
      const copy = row.querySelector(".recurring-copy");
      if (copy) {
        const reason = info.reason ? "Scheduled: " + info.reason : copy.textContent;
        copy.textContent = (info.title && info.title !== info.id ? info.title + " - " : "") + reason;
      }
      const chain = row.querySelector(".chain");
      if (chain && info.last_run) {
        chain.textContent = "Last run " + (info.last_run.title || info.last_run.id)
          + (info.last_run.date ? " completed " + info.last_run.date : "") + ". ";
        if (info.last_run.link) {
          const link = document.createElement("a");
          link.href = info.last_run.link;
          link.textContent = info.last_run.link;
          chain.appendChild(link);
        } else if (info.last_run.detail_ref) {
          const detailRef = info.last_run.detail_ref;
          const detailEntry = cfg.refs[detailRef] || { t: "work", label: info.last_run.title || info.last_run.id };
          const link = document.createElement("a");
          link.href = "/api/detail?ref=" + encodeURIComponent(detailRef);
          link.textContent = "Open report";
          link.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            openDetail(detailRef, detailEntry);
          });
          chain.appendChild(link);
        }
      }
      if (cfg.readOnly) return;
      const runNow = document.createElement("button");
      runNow.type = "button";
      runNow.className = "fmdash-send fmdash-runnow";
      runNow.textContent = "Run now";
      runNow.setAttribute("aria-label", "Run " + (info.title || info.id) + " now");
      runNow.addEventListener("click", async (event) => {
        event.stopPropagation();
        runNow.disabled = true;
        runNow.textContent = "Sending…";
        try {
          const res = await postJson({ run_now: info.ref });
          const out = await res.json();
          if (out.status === "queued" || out.status === "already-queued") {
            runNow.textContent = "Run queued";
            showPending(out.pending);
            return;
          }
          runNow.textContent = "Refused";
          runNow.disabled = false;
        } catch { runNow.textContent = "Failed"; runNow.disabled = false; }
      });
      (row.querySelector(".mreason") || row).appendChild(runNow);
    });
    if (cfg.readOnly) {
      copyButtons.forEach((copyButton) => copyButton.remove());
      return;
    }
    copyButtons.forEach((copyButton) => {
      const id = ((copyButton.dataset.copy || "").match(/CAP-\\d{2}/) || [])[0];
      if (!id) { copyButton.remove(); return; }
      if (!cfg.dispatchable.includes(id)) {
        const note = document.createElement("span");
        note.className = "fmdash-chat";
        note.textContent = "Raise in captain chat";
        copyButton.replaceWith(note);
        return;
      }
      const capAck = cfg.acks[id];
      if (capAck) {
        copyButton.replaceWith(ackNode(capAck));
        return;
      }
      const send = document.createElement("button");
      send.type = "button";
      send.className = "fmdash-send";
      send.textContent = "Approve & send";
      send.setAttribute("aria-label", "Approve " + id + " and queue it for firstmate");
      send.addEventListener("click", async () => {
        send.disabled = true;
        send.textContent = "Sending…";
        try {
          const res = await postJson({ id });
          const out = await res.json();
          if (out.status === "queued" || out.status === "already-queued") {
            acknowledge(send);
            showPending(out.pending);
            return;
          }
          send.textContent = "Refused";
          send.disabled = false;
        } catch { send.textContent = "Failed"; send.disabled = false; }
      });
      copyButton.replaceWith(send);
    });
  })();
  </script>`;
}

function setupPage(message) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light"><title>Firstmate capacity dashboard</title>
<style>:root{color-scheme:dark;--bg:#0d0d0d;--ink:#fff;--muted:#898781}@media(prefers-color-scheme: light){:root{color-scheme:light;--bg:#f9f9f7;--ink:#0b0b0b;--muted:#66645f}}
body{margin:0;background:var(--bg);color:var(--ink);font-family:system-ui,-apple-system,"Segoe UI",sans-serif;display:grid;min-height:100vh;place-items:center;padding:2rem}
p{color:var(--muted);max-width:45ch;line-height:1.5}</style></head>
<body><div><h1>Capacity dashboard</h1><p>${message}</p></div></body></html>`;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) { reject(new Error("body too large")); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "GET" && url.pathname === "/healthz") {
    sendJson(res, 200, { status: "ok" });
    return;
  }
  const config = readConfig();
  if (config.logins.length === 0) {
    sendHtml(res, 403, setupPage("No captain login is configured yet. Run bin/fm-dash-install.sh on the firstmate machine to finish setup."));
    return;
  }
  if (!authorized(req, config)) {
    log(`refused ${req.method} ${url.pathname} identity=${JSON.stringify(requesterLogin(req)) || "none"}`);
    sendJson(res, 403, { status: "forbidden", error: "tailnet identity is not an authorized captain login" });
    return;
  }
  if (req.method === "POST" && !sameOriginPost(req)) {
    sendJson(res, 403, { status: "forbidden", error: "cross-origin browser posts are refused" });
    return;
  }
  if (req.method === "GET" && url.pathname === "/") {
    const dashboard = readDashboard();
    if (!dashboard) {
      sendHtml(res, 200, setupPage("No dashboard has been generated yet. Use the Refresh capacity action once firstmate has generated a first snapshot, or run /capacity from firstmate.")
        .replace("</body>", `${interactiveLayer([], pendingRecords().length, "never", config.readOnly)}</body>`));
      return;
    }
    const dispatchable = config.readOnly ? [] : [...dashboard.actions.keys()].filter((id) => ONE_CLICK_ACTIONS.has(id));
    const refsFile = readRefs(dashboard.generated);
    const usage = await probeUsage();
    // Degraded-render self-check: when most worker states rendered as unknown,
    // the generator likely ran without its state-reader tools (for example a
    // stripped launchd environment). Say so loudly rather than presenting
    // degraded data as truth.
    const unknownStates = (dashboard.html.match(/Authoritative current state: unknown/g) || []).length;
    const authoritativeStates = (dashboard.html.match(/Authoritative current state:/g) || []).length;
    const degraded = authoritativeStates > 0 && unknownStates * 2 >= authoritativeStates;
    if (degraded) log(`degraded render detected: ${unknownStates} of ${authoritativeStates} authoritative worker states read unknown; check the service environment (PATH/tools)`);
    const acks = ackStates(dashboard.generated);
    const parked = parkedEntries(dashboard.html, refsFile);
    for (const info of parked) {
      const ack = acks.get(`unpark:${info.owner}/${info.id}`);
      if (ack) info.ack = ack;
    }
    const capAcks = {};
    for (const [key, ack] of acks) {
      if (key.startsWith("cap:")) capAcks[key.slice(4)] = ack;
    }
    const layer = interactiveLayer(dispatchable, pendingRecords().length, dashboard.generated, config.readOnly, {
      refs: refsFile ? refDisplayMap(refsFile, acks) : {},
      ideas: parseIdeas().map((idea) => ({ id: idea.id, title: idea.title })),
      parked,
      recurring: recurringEntries(dashboard.html, refsFile),
      usage,
      degraded,
      acks: capAcks,
    });
    sendHtml(res, 200, dashboard.html.replace("</body>", `${layer}</body>`));
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/detail") {
    const ref = url.searchParams.get("ref");
    const idea = url.searchParams.get("idea");
    let detail = null;
    if (idea && /^IDEA-\d+$/.test(idea)) detail = ideaDetail(idea);
    else if (ref && /^(?:item|project|home)-\d{2,}$/.test(ref)) detail = assembleDetail(ref);
    if (!detail) {
      sendJson(res, 404, { status: "not-found" });
      return;
    }
    const detailAcks = ackStates(readDashboard()?.generated ?? "never");
    if (detail.type === "decision") detail.ack = detailAcks.get(`decision:${detail.decision_identity}`) || null;
    else if (detail.type === "idea") detail.ack = detailAcks.get(`idea:${detail.id}`) || null;
    sendJson(res, 200, detail);
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/pending") {
    sendJson(res, 200, { status: "ok", pending: pendingRecords().length });
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/refresh") {
    if (refreshing) {
      sendJson(res, 409, { status: "busy" });
      return;
    }
    log(`refresh requested by ${requesterLogin(req)}`);
    const result = await runRefresh();
    if (result.ok) sendJson(res, 200, { status: "refreshed" });
    else sendJson(res, 502, { status: "failed", error: result.error });
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/dispatch") {
    if (config.readOnly) {
      sendJson(res, 403, { status: "refused", error: "this dashboard is read-only; command dispatch is not enabled yet" });
      return;
    }
    let body;
    try {
      body = JSON.parse(await readBody(req) || "{}");
    } catch {
      sendJson(res, 400, { status: "refused", error: "invalid request body" });
      return;
    }

    // Decision approval: the chosen option must be one the server itself just
    // read from the decision's structured record.
    if (typeof body.ref === "string") {
      const detail = /^(?:item|project|home)-\d{2,}$/.test(body.ref) ? assembleDetail(body.ref) : null;
      if (!detail || detail.type !== "decision") {
        sendJson(res, 400, { status: "refused", error: "approval accepts a currently listed decision only" });
        return;
      }
      const customAnswer = typeof body.answer === "string" ? body.answer.trim() : "";
      const hasOption = Number.isInteger(body.option)
        && body.option >= 0
        && body.option < detail.options.length;
      if (!hasOption && (!customAnswer || customAnswer.length > 2000 || detail.options.length === 0)) {
        sendJson(res, 400, { status: "refused", error: "the chosen option is not on the decision's record" });
        return;
      }
      const option = hasOption ? detail.options[body.option] : null;
      const pending = pendingRecords();
      if (pending.some((record) => record.kind === "decision" && record.decision_identity === detail.decision_identity)) {
        sendJson(res, 200, { status: "already-queued", pending: pending.length });
        return;
      }
      const record = {
        schema: "fm-dash-command.v1",
        kind: "decision",
        id: body.ref,
        decision_key: detail.id,
        decision_home: detail.decision_home,
        decision_origin: detail.decision_origin,
        decision_identity: detail.decision_identity,
        option_text: option?.text || null,
        custom_answer: option ? null : customAnswer,
        requested_by: requesterLogin(req),
        requested_at: new Date().toISOString(),
        dashboard_generated: readDashboard()?.generated ?? null,
        prompt: option
          ? `Captain approved decision ${detail.id} for ${detail.decision_origin || "legacy"} in ${detail.decision_home}: choose "${option.text}". Route it through the normal decision lifecycle; a destructive or irreversible consequence still needs chat confirmation.`
          : `Captain answered decision ${detail.id} for ${detail.decision_origin || "legacy"} in ${detail.decision_home}: ${customAnswer}. Route it through the normal decision lifecycle; a destructive or irreversible consequence still needs chat confirmation.`,
      };
      const name = enqueueCommand(record);
      log(`queued decision ${detail.id} as ${name} for ${record.requested_by}`);
      sendJson(res, 200, { status: "queued", pending: pending.length + 1 });
      return;
    }

    // Idea verdicts: approve, deny, or captain suggestions for a listed idea.
    // The suggestion text is captain-authored data for firstmate, never a
    // command the service interprets or executes.
    if (typeof body.idea === "string") {
      const verdict = body.verdict;
      if (!/^IDEA-\d+$/.test(body.idea) || !["approve", "deny", "suggest"].includes(verdict)) {
        sendJson(res, 400, { status: "refused", error: "idea dispatch needs a listed idea and an approve, deny, or suggest verdict" });
        return;
      }
      const idea = parseIdeas().find((entry) => entry.id === body.idea);
      if (!idea) {
        sendJson(res, 404, { status: "refused", error: `${body.idea} is not in the idea backlog` });
        return;
      }
      const suggestion = verdict === "suggest" && typeof body.suggestion === "string" ? body.suggestion.trim() : null;
      if (verdict === "suggest" && (!suggestion || suggestion.length > 2000)) {
        sendJson(res, 400, { status: "refused", error: "suggestions need text" });
        return;
      }
      const pending = pendingRecords();
      const priorVerdict = verdict === "suggest"
        ? null
        : pending.find((record) => record.kind === "idea" && record.idea === idea.id && record.verdict !== "suggest");
      if (priorVerdict?.verdict === verdict) {
        sendJson(res, 200, { status: "already-queued", pending: pending.length });
        return;
      }
      const verbs = { approve: "approved", deny: "denied", suggest: "added suggestions to" };
      const record = {
        schema: "fm-dash-command.v1",
        kind: "idea",
        id: idea.id,
        idea: idea.id,
        verdict,
        suggestion,
        requested_by: requesterLogin(req),
        requested_at: new Date().toISOString(),
        dashboard_generated: readDashboard()?.generated ?? null,
        prompt: `Captain ${verbs[verdict]} idea ${idea.id} (${idea.title}).${suggestion ? ` Captain suggestion text: ${suggestion}` : ""}${verdict === "approve" ? " Create the follow-up work item(s) through the normal backlog lifecycle." : ""}`,
      };
      const name = enqueueCommand(record);
      if (priorVerdict) removePendingIfUnchanged(priorVerdict);
      log(`queued idea ${idea.id} ${verdict} as ${name} for ${record.requested_by}`);
      sendJson(res, 200, { status: priorVerdict ? "replaced" : "queued", pending: pendingRecords().length });
      return;
    }

    // Unpark: the ref must be listed as parked by the currently served
    // dashboard and resolve through the current-generation refs sidecar. The
    // record only asks firstmate to lift the parked hold through the normal
    // backlog lifecycle; the service never edits the backlog.
    if (typeof body.unpark === "string") {
      const ref = body.unpark;
      if (!/^item-\d{2,}$/.test(ref)) {
        sendJson(res, 400, { status: "refused", error: "unpark accepts a currently parked item reference only" });
        return;
      }
      const currentDashboard = readDashboard();
      if (!currentDashboard || !currentDashboard.html.includes(`data-parked-ref="${ref}"`)) {
        sendJson(res, 409, { status: "refused", error: `${ref} is not in the current dashboard's parking lot; refresh first` });
        return;
      }
      const currentRefs = readRefs(currentDashboard.generated);
      const entry = currentRefs?.refs?.[ref];
      if (!entry || entry.kind !== "item") {
        sendJson(res, 409, { status: "refused", error: `${ref} cannot be resolved against the current dashboard generation; refresh first` });
        return;
      }
      const separator = entry.value.indexOf("/");
      const workHome = entry.value.slice(0, separator);
      const workId = entry.value.slice(separator + 1);
      const pending = pendingRecords();
      if (pending.some((record) => record.kind === "unpark" && record.work_identity === entry.value)) {
        sendJson(res, 200, { status: "already-queued", pending: pending.length });
        return;
      }
      const record = {
        schema: "fm-dash-command.v1",
        kind: "unpark",
        id: ref,
        work_id: workId,
        work_home: workHome,
        work_identity: entry.value,
        requested_by: requesterLogin(req),
        requested_at: new Date().toISOString(),
        dashboard_generated: currentDashboard.generated,
        prompt: `Captain clicked UNPARK for parked work ${workId}${workHome === "main" ? "" : ` (owned by domain supervisor ${workHome})`}: lift its parked hold through the normal backlog lifecycle so it rejoins the active queue. This request lifts the hold only; dispatch still follows normal re-evaluation and authority checks.`,
      };
      const name = enqueueCommand(record);
      log(`queued unpark ${workId} as ${name} for ${record.requested_by}`);
      sendJson(res, 200, { status: "queued", pending: pending.length + 1 });
      return;
    }

    // Run now: the ref must be listed as recurring by the currently served
    // dashboard and resolve through the current-generation refs sidecar. The
    // record only asks firstmate to run the scheduled item early through the
    // normal lifecycle; the service never edits the backlog and never
    // dispatches anything itself.
    if (typeof body.run_now === "string") {
      const ref = body.run_now;
      if (!/^item-\d{2,}$/.test(ref)) {
        sendJson(res, 400, { status: "refused", error: "run-now accepts a currently listed recurring item reference only" });
        return;
      }
      const currentDashboard = readDashboard();
      if (!currentDashboard || !currentDashboard.html.includes(`data-recurring-ref="${ref}"`)) {
        sendJson(res, 409, { status: "refused", error: `${ref} is not in the current dashboard's recurring section; refresh first` });
        return;
      }
      const currentRefs = readRefs(currentDashboard.generated);
      const entry = currentRefs?.refs?.[ref];
      if (!entry || entry.kind !== "item") {
        sendJson(res, 409, { status: "refused", error: `${ref} cannot be resolved against the current dashboard generation; refresh first` });
        return;
      }
      const separator = entry.value.indexOf("/");
      const workHome = entry.value.slice(0, separator);
      const workId = entry.value.slice(separator + 1);
      const pending = pendingRecords();
      if (pending.some((record) => record.kind === "run-now" && record.work_identity === entry.value)) {
        sendJson(res, 200, { status: "already-queued", pending: pending.length });
        return;
      }
      const record = {
        schema: "fm-dash-command.v1",
        kind: "run-now",
        id: ref,
        work_id: workId,
        work_home: workHome,
        work_identity: entry.value,
        requested_by: requesterLogin(req),
        requested_at: new Date().toISOString(),
        dashboard_generated: currentDashboard.generated,
        prompt: `Captain clicked RUN NOW for scheduled recurring work ${workId}${workHome === "main" ? "" : ` (owned by domain supervisor ${workHome})`}: lift its schedule hold through the normal backlog lifecycle, then dispatch it through normal re-evaluation, project resolution, and authority checks. This request asks for one early run only; it grants no authority beyond normal dispatch checks.`,
      };
      const name = enqueueCommand(record);
      log(`queued run-now ${workId} as ${name} for ${record.requested_by}`);
      sendJson(res, 200, { status: "queued", pending: pending.length + 1 });
      return;
    }

    const id = body.id;
    if (typeof id !== "string" || !/^CAP-\d{2}$/.test(id)) {
      sendJson(res, 400, { status: "refused", error: "dispatch accepts a known CAP-NN action id only" });
      return;
    }
    if (!ONE_CLICK_ACTIONS.has(id)) {
      sendJson(res, 403, { status: "refused", error: `${id} is not one-click eligible; raise it in captain chat` });
      return;
    }
    const dashboard = readDashboard();
    const prompt = dashboard?.actions.get(id);
    if (!prompt) {
      sendJson(res, 409, { status: "refused", error: `${id} is not recommended by the current dashboard; refresh first` });
      return;
    }
    const pending = pendingRecords();
    if (pending.some((record) => record.id === id)) {
      sendJson(res, 200, { status: "already-queued", pending: pending.length });
      return;
    }
    const record = {
      schema: "fm-dash-command.v1",
      id,
      prompt,
      requested_by: requesterLogin(req),
      requested_at: new Date().toISOString(),
      dashboard_generated: dashboard.generated,
    };
    const name = enqueueCommand(record);
    log(`queued ${id} as ${name} for ${record.requested_by}`);
    sendJson(res, 200, { status: "queued", pending: pending.length + 1 });
    return;
  }
  sendJson(res, 404, { status: "not-found" });
}

function main() {
  const args = process.argv.slice(2);
  let portOverride = null;
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--help" || args[i] === "-h") usage(0);
    else if (args[i] === "--port" && args[i + 1]) { portOverride = Number(args[i + 1]); i += 1; }
    else usage(2);
  }
  const config = readConfig();
  const port = portOverride || config.port || 8847;
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      log(`error handling ${req.method} ${req.url}: ${error.message}`);
      if (!res.headersSent) sendJson(res, 500, { status: "error" });
      else res.end();
    });
  });
  server.listen(port, "127.0.0.1", () => {
    log(`fm-dash-serve listening on 127.0.0.1:${port} for FM_HOME=${FM_HOME}${config.readOnly ? " (read-only)" : ""}`);
  });
  if (config.autoRefreshSeconds > 0) {
    const autoRender = async () => {
      const result = await runRefresh();
      log(result.ok ? "auto-render replaced the dashboard" : `auto-render failed: ${result.error}`);
    };
    let stale = true;
    try {
      stale = Date.now() - fs.statSync(DASHBOARD).mtimeMs > config.autoRefreshSeconds * 1000;
    } catch { /* missing dashboard is stale */ }
    if (stale) autoRender();
    setInterval(autoRender, config.autoRefreshSeconds * 1000).unref();
    // Prompt post-claim regeneration: bin/fm-dash-inbox.sh claim touches the
    // stale marker after archiving commands, so the model catches up with the
    // captain's handled clicks well before the next full auto-render interval.
    let staleCheckRunning = false;
    const requeueStaleRefresh = () => {
      try {
        fs.linkSync(STALE_REFRESH_MARKER, STALE_MARKER);
        fs.unlinkSync(STALE_REFRESH_MARKER);
        return true;
      } catch (error) {
        if (error.code === "ENOENT") return true;
        if (error.code !== "EEXIST") return false;
        try {
          fs.unlinkSync(STALE_REFRESH_MARKER);
          return true;
        } catch (unlinkError) {
          return unlinkError.code === "ENOENT";
        }
      }
    };
    const staleCheck = async () => {
      if (staleCheckRunning || !requeueStaleRefresh()) return;
      let markerMs;
      try {
        fs.renameSync(STALE_MARKER, STALE_REFRESH_MARKER);
        markerMs = fs.statSync(STALE_REFRESH_MARKER).mtimeMs;
      } catch {
        return;
      }
      staleCheckRunning = true;
      log("claimed captain commands marked the model stale; regenerating");
      try {
        const result = await runRefresh();
        if (result.ok && result.startedAtMs >= markerMs) {
          try { fs.unlinkSync(STALE_REFRESH_MARKER); } catch { /* already gone */ }
        } else {
          requeueStaleRefresh();
          if (!result.ok) log(`stale-marker refresh failed: ${result.error}`);
        }
      } catch (error) {
        requeueStaleRefresh();
        log(`stale-marker refresh failed: ${error.message}`);
      } finally {
        staleCheckRunning = false;
      }
    };
    setInterval(staleCheck, STALE_POLL_MS).unref();
  }
  const stop = () => server.close(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

main();
