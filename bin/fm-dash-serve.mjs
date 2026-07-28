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
 * producer and quota probe, and never mutates any state
 * outside state/dash-inbox/ and the producer-owned dashboard file. A clicked
 * CAP action becomes one durable fm-dash-command.v1 record in state/dash-inbox/;
 * the running firstmate consumes it through its registered fm-dash watcher check
 * (bin/fm-dash-inbox.sh claim). Delivery therefore rides the sanctioned wake
 * path and inherits its cadence rather than any direct control channel.
 *
 * Identity fails closed: every route except /healthz requires the
 * Tailscale-User-Login header injected by tailscale serve to match a login in
 * config/dash.json. Requests without a matching identity get 403 and cause no
 * writes. Dispatch accepts only known CAP-NN identifiers that are present in
 * the currently served dashboard AND in the fixed one-click allowlist below;
 * free-text commands are structurally impossible and unknown or future action
 * IDs are refused (route those through captain chat). The server binds
 * 127.0.0.1 only, so the only remote path in is the tailnet proxy.
 *
 * Environment: FM_HOME selects the home (defaults to this checkout);
 * FM_DASH_CAPACITY_ARGS appends producer fixture args for tests ONLY and must
 * stay unset in real deployments. Run --help for routes and config schema.
 */

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import process from "node:process";
import { randomBytes } from "node:crypto";
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
  {"port": 8847, "captain_logins": ["captain@example.com"],
   "read_only": false, "auto_refresh_seconds": 900}
--port overrides the configured port. read_only=true refuses dispatch and
serves the page without send buttons, for running the service before command
consumption is wired up. auto_refresh_seconds reruns the producer on that
interval (and at startup when the dashboard is missing or stale); 0 disables
auto-render. Routes:
  GET  /healthz       liveness, no identity required
  GET  /              dashboard with the interactive layer injected
  GET  /api/pending   pending command count
  POST /api/refresh   rerun bin/fm-capacity.mjs server-side (serialized)
  POST /api/dispatch  validated CAP action, decision answer, or idea verdict
All routes except /healthz require a Tailscale-User-Login header matching a
configured captain login and fail closed otherwise. Dispatch refuses IDs not in
both the served dashboard and the fixed one-click allowlist. Browser POSTs must
also be same-origin.
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
      const record = JSON.parse(fs.readFileSync(path.join(INBOX, name), "utf8"));
      if (record && typeof record.id === "string") {
        Object.defineProperty(record, "_file", { value: path.join(INBOX, name) });
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

function replaceCommand(file, record) {
  const tmp = path.join(INBOX, `.tmp-${randomBytes(6).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
  return path.basename(file);
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
function parseBacklog() {
  const text = readText(BACKLOG, 262144);
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
  if (parts.length >= 3) return { home: parts[1], id: parts.slice(2).join("/") };
  return { home: "main", id: parts.slice(1).join("/") };
}

function decisionHome(home) {
  if (home === "main") return FM_HOME;
  const meta = readMeta(home);
  return meta.home ? path.resolve(meta.home) : null;
}

function decisionDocument(home, id) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id)) return null;
  const root = decisionHome(home);
  if (!root) return null;
  const text = readText(path.join(root, "data", "decisions", `${id}.md`), 131072);
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

function refDisplayMap(refsFile) {
  const display = {};
  for (const [ref, entry] of Object.entries(refsFile.refs)) {
    if (entry.kind === "project") display[ref] = { t: "project", label: entry.value };
    else if (entry.kind === "home") display[ref] = { t: "home", label: entry.value };
    else if (entry.kind === "item") {
      const separator = entry.value.indexOf("/");
      const owner = entry.value.slice(0, separator);
      const decision = decisionRef(entry);
      const id = decision ? decision.id : entry.value.slice(separator + 1);
      display[ref] = owner === "decision"
        ? { t: "decision", label: id }
        : { t: "work", label: id, owner };
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
  const id = decision ? decision.id : entry.value.slice(separator + 1);
  const backlogItem = parseBacklog().find((item) => item.id === id) || null;

  if (owner === "decision") {
    const document = decisionDocument(decision.home, id);
    return {
      type: "decision",
      ref,
      id,
      title: document?.title || backlogItem?.title || id,
      description: document?.context || null,
      options: document?.options || [],
      recent: statusTail(id),
      note: document ? null : "This legacy decision has no structured options document; answer it in captain chat.",
    };
  }
  if (owner !== "main") {
    return {
      type: "work",
      ref,
      id,
      owner,
      title: backlogItem ? backlogItem.title : id,
      note: "This work lives with a domain supervisor; its instructions and records are in that home.",
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
      if (code === 0) resolve({ ok: true });
      else resolve({ ok: false, error: stderr.trim().slice(0, 500) || `capacity producer exited ${code}` });
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      refreshing = null;
      resolve({ ok: false, error: error.message });
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
    usage: extras?.usage || { status: "unavailable", providers: [] },
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
          button.textContent = "Approved · queued";
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
          button.textContent = "Answer queued";
          showPending(out.pending);
          return;
        }
        button.textContent = "Refused";
      } catch { button.textContent = "Failed"; }
      button.disabled = false;
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
          if (!cfg.readOnly) {
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
        if (!cfg.readOnly) panel.appendChild(textBlock("p", "An approval here is your routine decision only; anything destructive or irreversible still gets re-confirmed with you in chat."));
        if (!cfg.readOnly) {
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
          button.textContent = verdict === "suggest" ? "Suggestions sent" : (verdict === "approve" ? "Approved · queued" : "Denied · queued");
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
      const controls = document.createElement("div");
      controls.className = "fmdash-option";
      const buttons = document.createElement("div");
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
      const suggest = document.createElement("button");
      suggest.type = "button";
      suggest.className = "fmdash-send";
      suggest.textContent = "Add suggestions";
      suggest.style.marginLeft = ".6rem";
      buttons.appendChild(approve);
      buttons.appendChild(deny);
      buttons.appendChild(suggest);
      controls.appendChild(buttons);
      panel.appendChild(controls);
      panel.appendChild(textBlock("p", "Approving asks firstmate to create the work item(s) through the normal backlog lifecycle; nothing runs from this page."));
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
    if (cfg.readOnly) return;
    document.querySelectorAll("button[data-copy]").forEach((copyButton) => {
      const id = ((copyButton.dataset.copy || "").match(/CAP-\\d{2}/) || [])[0];
      if (!id) return;
      if (!cfg.dispatchable.includes(id)) {
        const note = document.createElement("span");
        note.className = "fmdash-chat";
        note.textContent = "Raise in captain chat";
        copyButton.after(note);
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
            send.textContent = "Approved · queued";
            showPending(out.pending);
            return;
          }
          send.textContent = "Refused";
          send.disabled = false;
        } catch { send.textContent = "Failed"; send.disabled = false; }
      });
      copyButton.after(send);
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
    const layer = interactiveLayer(dispatchable, pendingRecords().length, dashboard.generated, config.readOnly, {
      refs: refsFile ? refDisplayMap(refsFile) : {},
      ideas: parseIdeas().map((idea) => ({ id: idea.id, title: idea.title })),
      usage,
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
      if (pending.some((record) => record.kind === "decision" && record.decision_key === detail.id)) {
        sendJson(res, 200, { status: "already-queued", pending: pending.length });
        return;
      }
      const record = {
        schema: "fm-dash-command.v1",
        kind: "decision",
        id: body.ref,
        decision_key: detail.id,
        option_text: option?.text || null,
        custom_answer: option ? null : customAnswer,
        requested_by: requesterLogin(req),
        requested_at: new Date().toISOString(),
        prompt: option
          ? `Captain approved decision ${detail.id}: choose "${option.text}". Route it through the normal decision lifecycle; a destructive or irreversible consequence still needs chat confirmation.`
          : `Captain answered decision ${detail.id}: ${customAnswer}. Route it through the normal decision lifecycle; a destructive or irreversible consequence still needs chat confirmation.`,
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
        prompt: `Captain ${verbs[verdict]} idea ${idea.id} (${idea.title}).${suggestion ? ` Captain suggestion text: ${suggestion}` : ""}${verdict === "approve" ? " Create the follow-up work item(s) through the normal backlog lifecycle." : ""}`,
      };
      const name = priorVerdict ? replaceCommand(priorVerdict._file, record) : enqueueCommand(record);
      log(`queued idea ${idea.id} ${verdict} as ${name} for ${record.requested_by}`);
      sendJson(res, 200, { status: priorVerdict ? "replaced" : "queued", pending: pending.length + (priorVerdict ? 0 : 1) });
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
  }
  const stop = () => server.close(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

main();
