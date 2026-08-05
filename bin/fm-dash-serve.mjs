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
 * CAP action, decision answer, idea verdict, parking-lot unpark, recurring
 * run-now, or needs-you your-go becomes one durable fm-dash-command.v1 record
 * in state/dash-inbox/;
 * the running firstmate consumes it through its registered fm-dash watcher check
 * (bin/fm-dash-inbox.sh claim). Delivery therefore rides the sanctioned wake
 * path and inherits its cadence rather than any direct control channel; an
 * unpark click only asks firstmate to lift the parked hold through the normal
 * backlog lifecycle, a run-now click only asks firstmate to run the
 * scheduled recurring item early through the same normal lifecycle, and a
 * your-go click only routes the captain's go-ahead, not-now, or bounded
 * guidance text for an item awaiting them back through the normal lifecycle.
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
 * idea suggestion, decision custom answer, or needs-you guidance note
 * delivered to firstmate as data,
 * never interpreted or executed by this service. Unknown or future action IDs
 * are refused (route those through captain chat). The server binds 127.0.0.1
 * only, so the only remote path in is the tailnet proxy.
 *
 * Captain chat: the authenticated served page carries a Chat destination that
 * reaches the same firstmate agent through durable local records only. A sent
 * message becomes one fm-dash-chat-message.v1 record in
 * state/dash-chat/messages/ (atomic, mode 0600, bounded, idempotent by
 * client_key); bin/fm-dash-chat.sh claims messages and records exactly one
 * fm-dash-chat-reply.v1 answer per message. Chat text is captain input for
 * firstmate to read - never shell, a path, script source, HTML, or authority
 * by itself - and the page renders every side of the conversation as text
 * nodes, never markup.
 *
 * Exact PR merge approval: an approval-ready row whose task records a
 * canonical GitHub PR can open a merge review. The service itself never talks
 * to the forge and never merges: it spawns the read-only trusted
 * bin/fm-dash-pr-evidence.mjs probe, renders the evidence, and an explicit
 * confirmation writes one typed kind=merge-approval fm-dash-command.v1 record
 * bound to the exact PR identity, head SHA, check-set identity, merge method,
 * captain login, short expiry, and one-time nonce. Only firstmate's guarded
 * bin/fm-dash-merge.sh consumer - which revalidates every binding and
 * independently rechecks the live PR - may turn that record into a merge
 * through bin/fm-pr-merge.sh. Every other sensitive action kind remains
 * refused here; there is no generic command surface.
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
import { readDecisionDocument } from "./fm-decision-document.mjs";

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
const CHAT_DIR = path.join(STATE, "dash-chat");
const CHAT_MESSAGES = path.join(CHAT_DIR, "messages");
const CHAT_ARCHIVE = path.join(CHAT_DIR, "archive");
const CHAT_REPLIES = path.join(CHAT_DIR, "replies");
const CHAT_MAX_CHARS = Number(process.env.FM_DASH_CHAT_MAX_CHARS) > 0 ? Number(process.env.FM_DASH_CHAT_MAX_CHARS) : 4000;
const CHAT_PENDING_MAX = 100;
const CHAT_HISTORY_LIMIT = 200;
const MERGE_EVIDENCE_BIN = path.join(ROOT, "bin", "fm-dash-pr-evidence.mjs");
const MERGE_DIR = path.join(STATE, "dash-merge");
const MERGE_CONSUMED = path.join(MERGE_DIR, "consumed");
const EVIDENCE_TIMEOUT_MS = 30000;
// A merge approval is deliberately short-lived: long enough to survive the
// 30-second wake cadence plus handling, short enough that a stale review
// cannot linger as authority. FM_DASH_MERGE_TTL_SECS is for tests ONLY.
const MERGE_TTL_SECS = Number(process.env.FM_DASH_MERGE_TTL_SECS) > 0 ? Number(process.env.FM_DASH_MERGE_TTL_SECS) : 900;

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
                      parking-lot unpark request, recurring run-now request,
                      or needs-you your-go request (go, park, or guidance)
  GET  /api/chat/history   bounded captain chat history (limit, before)
  POST /api/chat/send      one bounded captain chat message with a client
                           idempotency key; stored as a durable record for
                           bin/fm-dash-chat.sh, never executed
  GET  /api/merge/preview  read-only merge evidence for one currently listed
                           approval-ready task (ref), via the trusted
                           bin/fm-dash-pr-evidence.mjs probe
  POST /api/merge/approve  one typed, expiring, one-time-nonce merge-approval
                           record for exactly the previewed PR head; consumed
                           only by the guarded bin/fm-dash-merge.sh
All routes except /healthz require a Tailscale-User-Login header matching a
configured captain login and fail closed otherwise. Dispatch refuses IDs not in
both the served dashboard and the fixed one-click allowlist, refuses an
unpark for any item the served dashboard does not currently list as parked,
refuses a run-now for any item it does not currently list as recurring, and
refuses a your-go for any item it does not currently list as awaiting the
captain. Merge approval refuses any task not currently listed as
approval-ready with a canonical GitHub PR, and refuses whenever the fresh
forge evidence is not an open, non-draft, mergeable PR with every current
check terminal green or differs from what the captain reviewed. Browser POSTs
must also be same-origin. read_only additionally refuses chat and merge
routes.
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

// --- captain chat ----------------------------------------------------------
// Durable, bounded, local-only conversation records. The service only writes
// captain messages and reads the three chat directories; bin/fm-dash-chat.sh
// owns claiming (messages/ -> archive/) and the one-reply-per-message ledger
// in replies/. All content is data: it is stored verbatim, served as JSON,
// and rendered client-side as text nodes only.

const CHAT_MESSAGE_ID = /^[0-9]{1,19}-[0-9a-f]{8}$/;
const CHAT_CLIENT_KEY = /^[A-Za-z0-9-]{8,64}$/;

function readChatDir(dir, state) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const records = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      const record = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"));
      if (record?.schema === "fm-dash-chat-message.v1"
        && typeof record.message_id === "string"
        && CHAT_MESSAGE_ID.test(record.message_id)
        && typeof record.text === "string") {
        records.push({ record, state });
      }
    } catch {
      // An unreadable record renders nothing rather than markup or a guess.
    }
  }
  return records;
}

function readChatReply(messageId) {
  try {
    const record = JSON.parse(fs.readFileSync(path.join(CHAT_REPLIES, `${messageId}.json`), "utf8"));
    if (record?.schema === "fm-dash-chat-reply.v1" && typeof record.text === "string") {
      return { text: record.text, replied_at: typeof record.replied_at === "string" ? record.replied_at : null };
    }
  } catch {
    // No reply yet.
  }
  return null;
}

function chatHistory(limit, before) {
  const all = [...readChatDir(CHAT_MESSAGES, "sent"), ...readChatDir(CHAT_ARCHIVE, "received")]
    .sort((a, b) => (a.record.message_id < b.record.message_id ? -1 : 1));
  const upper = typeof before === "string" && CHAT_MESSAGE_ID.test(before)
    ? all.filter((entry) => entry.record.message_id < before)
    : all;
  const bounded = Math.min(Math.max(1, limit || 100), CHAT_HISTORY_LIMIT);
  const slice = upper.slice(-bounded);
  return {
    messages: slice.map(({ record, state }) => {
      const reply = readChatReply(record.message_id);
      return {
        message_id: record.message_id,
        text: record.text,
        requested_by: typeof record.requested_by === "string" ? record.requested_by : null,
        requested_at: typeof record.requested_at === "string" ? record.requested_at : null,
        state: reply ? "answered" : state,
        reply,
      };
    }),
    has_more: upper.length > slice.length,
    pending_unclaimed: readChatDir(CHAT_MESSAGES, "sent").length,
  };
}

function chatTextProblem(text) {
  if (typeof text !== "string" || text.trim() === "") return "a message needs text";
  if (text.length > CHAT_MAX_CHARS) return `messages are limited to ${CHAT_MAX_CHARS} characters; send long material as a link`;
  if (typeof text.isWellFormed === "function" ? !text.isWellFormed() : /\p{Cs}/u.test(text)) return "the message contains malformed text and was not stored";
  // Keep newlines and tabs; refuse every other control character so stored
  // records stay terminal- and log-safe.
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text)) return "the message contains unsupported control characters";
  return null;
}

function findChatByClientKey(clientKey) {
  for (const dir of [CHAT_MESSAGES, CHAT_ARCHIVE]) {
    for (const { record } of readChatDir(dir, "any")) {
      if (record.client_key === clientKey) return record;
    }
  }
  return null;
}

function enqueueChatMessage(text, clientKey, login) {
  fs.mkdirSync(CHAT_MESSAGES, { recursive: true, mode: 0o700 });
  const record = {
    schema: "fm-dash-chat-message.v1",
    message_id: `${Math.floor(Date.now() / 1000)}-${randomBytes(4).toString("hex")}`,
    text,
    client_key: clientKey,
    requested_by: login,
    requested_at: new Date().toISOString(),
  };
  const tmp = path.join(CHAT_MESSAGES, `.tmp-${randomBytes(6).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, path.join(CHAT_MESSAGES, `${record.message_id}.json`));
  return record;
}

// --- exact PR merge review -------------------------------------------------
// The service's only forge knowledge comes from spawning the read-only
// trusted evidence probe with a server-resolved task id; no client-supplied
// value ever reaches that spawn. Approval records are typed, bound, and
// consumed exclusively by bin/fm-dash-merge.sh on the firstmate side.

function runMergeEvidence(taskId) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [MERGE_EVIDENCE_BIN, taskId], {
      cwd: ROOT,
      env: { ...process.env, FM_HOME },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const chunks = [];
    let size = 0;
    const timer = setTimeout(() => child.kill("SIGKILL"), EVIDENCE_TIMEOUT_MS);
    child.stdout.on("data", (chunk) => {
      size += chunk.length;
      if (size <= 1024 * 1024) chunks.push(chunk);
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ available: false, eligible: false, reason: "the merge evidence probe could not run" });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0 || size > 1024 * 1024) {
        resolve({ available: false, eligible: false, reason: "the merge evidence probe could not run" });
        return;
      }
      try {
        const evidence = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (evidence?.schema !== "fm-dash-pr-evidence.v1") throw new Error("schema");
        resolve(evidence);
      } catch {
        resolve({ available: false, eligible: false, reason: "the merge evidence probe returned an unreadable record" });
      }
    });
  });
}

// A merge review is offered only for a row the current dashboard itself lists
// as awaiting captain approval, whose main-home task records a canonical
// GitHub PR. The returned task id comes from the server-read refs sidecar.
function mergeReviewTarget(ref) {
  if (!/^item-\d{2,}$/.test(ref)) return null;
  const dashboard = readDashboard();
  if (!dashboard || !dashboard.html.includes(`data-your-go-ref="${ref}" data-your-go-kind="approval"`)) return null;
  const refsFile = readRefs(dashboard.generated);
  const entry = refsFile?.refs?.[ref];
  if (!entry || entry.kind !== "item") return null;
  const separator = entry.value.indexOf("/");
  if (entry.value.slice(0, separator) !== "main") return null;
  const id = entry.value.slice(separator + 1);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(id)) return null;
  const meta = readMeta(id);
  if (!meta.pr || !/^https:\/\/github\.com\//.test(meta.pr)) return null;
  return { task: id, url: meta.pr, generated: dashboard.generated };
}

function mergeConsumedOutcome(nonce) {
  if (typeof nonce !== "string" || !/^[0-9a-f]{32}$/.test(nonce)) return null;
  try {
    const text = fs.readFileSync(path.join(MERGE_CONSUMED, nonce), "utf8");
    const outcome = text.split("\n").filter((line) => line.startsWith("outcome=")).pop();
    return outcome ? outcome.slice("outcome=".length) : null;
  } catch {
    return null;
  }
}

// The captain-facing lifecycle of the newest approval for one task: a pending
// record is "sent", a claimed record is "received", and a consumed nonce
// reports the guarded consumer's recorded outcome honestly.
function mergeApprovalState(taskId) {
  const candidates = [];
  for (const record of pendingRecords()) {
    if (record.kind === "merge-approval" && record.task === taskId) candidates.push({ record, status: "pending" });
  }
  for (const { record } of archivedRecords()) {
    if (record.kind === "merge-approval" && record.task === taskId) candidates.push({ record, status: "claimed" });
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => ((a.record.requested_at || "") < (b.record.requested_at || "") ? -1 : 1));
  const newest = candidates[candidates.length - 1];
  return {
    status: newest.status,
    requested_at: newest.record.requested_at || null,
    head_sha: newest.record.head_sha || null,
    expires_at: newest.record.expires_at || null,
    outcome: newest.status === "claimed" ? mergeConsumedOutcome(newest.record.nonce) : null,
  };
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
  if (record.kind === "your-go") {
    // A your-go answer for a decision shares the decision's durable ack
    // identity, so answering through either path acknowledges the same item.
    if (typeof record.decision_identity === "string") return `decision:${record.decision_identity}`;
    return typeof record.work_identity === "string" ? `yourgo:${record.work_identity}` : null;
  }
  if (record.kind === "merge-approval") return typeof record.task === "string" ? `merge:${record.task}` : null;
  return /^CAP-\d{2}$/.test(record.id) ? `cap:${record.id}` : null;
}

function ackStates(generated) {
  const acks = new Map();
  const now = Date.now();
  const stateFor = (record, status, extra = {}) => ({
    status,
    requested_at: record.requested_at || null,
    verdict: record.verdict || null,
    ...(record.kind === "your-go" ? { kind: record.kind, action: record.action || null } : {}),
    ...extra,
  });
  for (const { record, claimedAtMs } of archivedRecords()) {
    const key = ackKey(record);
    if (!key) continue;
    const requestedAtMs = Date.parse(record.requested_at || "");
    if (record.dashboard_generated === generated) {
      acks.set(key, stateFor(record, "claimed", {
        claimed_at: new Date(claimedAtMs).toISOString(),
      }));
    } else if (Number.isFinite(requestedAtMs) && now - requestedAtMs <= ACK_PRIOR_WINDOW_MS) {
      acks.set(key, stateFor(record, "prior"));
    }
  }
  for (const record of pendingRecords()) {
    const key = ackKey(record);
    if (!key) continue;
    acks.set(key, stateFor(record, "pending"));
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

// Needs-you enrichment for the authenticated captain: resolve each
// data-your-go-ref anchor the producer rendered through the current-generation
// refs sidecar so every row awaiting the captain carries real interaction
// controls. A decision ref reports whether its structured options document
// exists (per-option approval stays the canonical path when it does); a work
// ref reads the owning home's backlog for the real title and hold reason. A
// hold reason that asks the captain to furnish something concrete (the
// deliverable-ask verbs below) becomes a prefilled guidance ask. Reads only.
const DELIVERABLE_ASK = /\b(?:supply|provide|send|share|upload|paste|deliver|furnish)\b/i;

function yourGoEntries(dashboardHtml, refsFile) {
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
  const seen = new Set();
  const rowPattern = /data-your-go-ref="(item-\d{2,})" data-your-go-kind="(approval|review|decision)"/g;
  for (const match of dashboardHtml.matchAll(rowPattern)) {
    const [, ref, rowKind] = match;
    if (seen.has(ref)) continue;
    seen.add(ref);
    const entry = refsFile.refs[ref];
    if (!entry || entry.kind !== "item") continue;
    const decision = decisionRef(entry);
    if (decision) {
      const holdId = decision.origin ? `${decision.origin}-decision-${decision.key}` : decision.key;
      const row = decision.home === "main"
        ? backlogFor(decision.home).find((item) => item.id === holdId) || null
        : null;
      const parsed = row ? titleAnnotations(row.title) : null;
      const reason = parsed?.fields["hold"] || null;
      const detail = projectedDecisionDetail(entry, decision);
      entries.push({
        ref,
        row_kind: rowKind,
        target: "decision",
        identity: `${decision.home}/${decision.origin || ""}/${decision.key}`,
        title: detail.available ? detail.title : parsed?.title || decision.key,
        reason,
        has_options: detail.available === true,
        ask: reason && DELIVERABLE_ASK.test(reason) ? reason : null,
      });
      continue;
    }
    const separator = entry.value.indexOf("/");
    const owner = entry.value.slice(0, separator);
    const id = entry.value.slice(separator + 1);
    const row = backlogFor(owner).find((item) => item.id === id) || null;
    const parsed = row ? titleAnnotations(row.title) : null;
    const reason = parsed?.fields["hold"] || null;
    // An approval-ready main-home task with a recorded GitHub PR gets the
    // exact merge review path; the row's generic controls stay unchanged and
    // grant no merge authority.
    const mergeCandidate = rowKind === "approval"
      && owner === "main"
      && /^https:\/\/github\.com\//.test(readMeta(id).pr || "");
    entries.push({
      ref,
      row_kind: rowKind,
      target: "work",
      identity: entry.value,
      title: parsed?.title || id,
      reason,
      has_options: false,
      ask: reason && DELIVERABLE_ASK.test(reason) ? reason : null,
      merge_candidate: mergeCandidate,
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

function projectedDecisionDetail(entry, decision) {
  if (decision.home === "main") {
    const root = decisionHome(decision.home);
    return root
      ? readDecisionDocument(root, decision.origin, decision.key, { allowOversizePrefix: true })
      : { available: false, reason: "main decision home could not be resolved" };
  }
  const detail = entry?.decision_detail;
  if (detail?.available === true
    && typeof detail.title === "string"
    && typeof detail.context === "string"
    && Array.isArray(detail.options)
    && detail.options.length > 0
    && detail.options.every((option) => typeof option?.text === "string"
      && typeof option?.impact === "string"
      && typeof option?.recommended === "boolean")) {
    return detail;
  }
  if (detail?.available === false && typeof detail.reason === "string" && detail.reason) return detail;
  return {
    available: false,
    reason: detail === undefined
      ? "structured decision detail was not included in the bounded snapshot"
      : "structured decision detail in the bounded snapshot was malformed",
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
      const label = typeof entry.label === "string" && entry.label.trim()
        ? entry.label.trim().slice(0, 200)
        : id;
      display[ref] = owner === "decision"
        ? { t: "decision", label: id }
        : { t: "work", label, owner };
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
    const document = projectedDecisionDetail(entry, decision);
    const remote = decision.home !== "main";
    return {
      type: "decision",
      ref,
      id,
      decision_home: decision.home,
      decision_origin: decision.origin,
      decision_identity: `${decision.home}/${decision.origin || ""}/${decision.key}`,
      title: document.available ? document.title : backlogItem?.title || id,
      description: document.available ? document.context : null,
      options: document.available ? document.options : [],
      recent: remote ? [] : statusTail(decision.origin || id),
      note: document.available
        ? null
        : remote
          ? `Decision details unavailable: ${document.reason}.`
          : "This legacy decision has no structured options document; answer it in captain chat.",
      provenance_note: remote ? "This decision lives with a domain supervisor." : null,
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
    yourGo: extras?.yourGo || [],
    usage: extras?.usage || { status: "unavailable", providers: [] },
    degraded: extras?.degraded === true,
    acks: extras?.acks || {},
    chat: readOnly !== true,
    chatMaxChars: CHAT_MAX_CHARS,
    mergeTtlSeconds: MERGE_TTL_SECS,
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
  .fmdash-panel .fmdash-provenance{color:var(--muted);font-size:.76rem}
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
  .fmdash-yourgo{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin-top:.5rem}
  .fmdash-yourgo .fmdash-send{grid-column:auto;padding:.35rem .7rem;font-size:.76rem}
  .fmdash-yourgo .fmdash-primary{background:var(--ink);color:var(--bg)}
  .fmdash-guide{width:100%;margin-top:.5rem;padding:.5rem;background:var(--bg);color:var(--ink);border:1px solid var(--hair);font-size:.85rem}
  .fmdash-ack{display:inline-block;border:1px solid var(--good);color:var(--good);font-weight:700;font-size:.76rem;padding:.35rem .7rem;align-self:center;grid-column:2}
  .fmdash-ack-chip{margin-left:.6rem;padding:.15rem .5rem;font-size:.7rem;grid-column:auto}
  .fmdash-chatpage *,.fmdash-panel *{box-sizing:border-box}
  .fmdash-chatpage .wrap{max-width:46rem}
  .fmdash-chat-note{border:1px solid var(--hair);padding:.6rem .8rem;margin-top:1rem;font-size:.78rem;color:var(--muted)}
  .fmdash-chat-note summary{cursor:pointer;color:var(--ink2);font-weight:700}
  .fmdash-chat-note p{margin-top:.5rem;line-height:1.45}
  .fmdash-chat-tools{display:flex;gap:.5rem;align-items:center;margin-top:1rem;flex-wrap:wrap}
  .fmdash-chat-search{flex:1 1 12rem;min-width:0;padding:.55rem .7rem;background:var(--bg);color:var(--ink);border:1px solid var(--hair);font-size:.9rem}
  .fmdash-chat-log{list-style:none;margin:1rem 0 0;padding:0;display:flex;flex-direction:column;gap:.9rem}
  .fmdash-msg{max-width:85%;border:1px solid var(--hair);padding:.6rem .8rem;min-width:0}
  .fmdash-msg-captain{align-self:flex-end;border-color:var(--line);background:color-mix(in srgb,var(--blue) 12%,var(--bg))}
  .fmdash-msg-agent{align-self:flex-start}
  .fmdash-msg-text{white-space:pre-wrap;overflow-wrap:anywhere;color:var(--ink);font-size:.92rem;line-height:1.45}
  .fmdash-msg-text a{overflow-wrap:anywhere}
  .fmdash-msg-meta{margin-top:.35rem;font-size:.7rem;color:var(--muted)}
  .fmdash-msg-state{font-weight:700}
  .fmdash-msg-state-answered{color:var(--good)}
  .fmdash-msg-unsent{border-color:var(--crit)}
  .fmdash-chat-offline{display:none;border:1px solid var(--warn);color:var(--warn);padding:.5rem .8rem;margin-top:1rem;font-size:.8rem}
  .fmdash-chat-offline.fmdash-on{display:block}
  .fmdash-composer{position:sticky;bottom:0;background:var(--bg);border-top:1px solid var(--line);padding:.8rem 0 max(.8rem,env(safe-area-inset-bottom));margin-top:1rem}
  .fmdash-composer textarea{width:100%;min-height:3.2rem;max-height:9rem;resize:vertical;padding:.6rem .7rem;background:var(--bg);color:var(--ink);border:1px solid var(--hair);font-size:1rem;font-family:inherit}
  .fmdash-composer-row{display:flex;gap:.6rem;align-items:center;margin-top:.5rem;flex-wrap:wrap}
  .fmdash-composer-row .fmdash-send{min-height:2.75rem;padding:.5rem 1.2rem;grid-column:auto}
  .fmdash-composer-hint{font-size:.72rem;color:var(--muted);flex:1 1 12rem}
  .fmdash-chat-cred{margin-top:.5rem;font-size:.72rem;color:var(--warn)}
  .fmdash-merge-facts{list-style:none;margin:1rem 0 0;padding:0;border-top:1px solid var(--hair)}
  .fmdash-merge-facts li{display:grid;grid-template-columns:minmax(7rem,auto) minmax(0,1fr);gap:.6rem;padding:.45rem 0;border-bottom:1px solid var(--hair);font-size:.88rem}
  .fmdash-merge-facts .fact-label{color:var(--muted);font-size:.74rem;font-weight:800;letter-spacing:.08em;text-transform:uppercase;padding-top:.15rem}
  .fmdash-merge-facts .fact-value{color:var(--ink2);overflow-wrap:anywhere;min-width:0}
  .fmdash-merge-facts code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.82rem;overflow-wrap:anywhere}
  .fmdash-merge-check-green{color:var(--good)}
  .fmdash-merge-check-bad{color:var(--crit)}
  .fmdash-merge-confirm{display:flex;gap:.6rem;align-items:flex-start;margin-top:1rem;font-size:.88rem;color:var(--ink2)}
  .fmdash-merge-confirm input{width:1.1rem;height:1.1rem;margin-top:.15rem;flex:none}
  .fmdash-merge-approve{margin-top:.9rem;border:1px solid var(--good);background:var(--good);color:var(--bg);font-weight:800;padding:.6rem 1.2rem;cursor:pointer;font-size:.9rem;min-height:2.75rem}
  .fmdash-merge-approve[disabled]{opacity:.45;cursor:default}
  .fmdash-merge-refused{border:1px solid var(--warn);color:var(--warn);padding:.6rem .8rem;margin-top:1rem;font-size:.85rem}
  @media(max-width:760px){.fmdash-usage-grid{grid-template-columns:1fr}.fmdash-ack{grid-column:1;justify-self:start;max-width:100%}.fmdash-msg{max-width:100%}.fmdash-merge-facts li{grid-template-columns:1fr;gap:.15rem}.fmdash-composer{position:static}.fmdash-composer-row .fmdash-send{flex:1 1 auto}}
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
      warn.textContent = "RENDER DEGRADED - most worker states read as unknown, so this page may not reflect reality. That usually means the state reader could not resolve a current source for those workers (for example an active validation run was not attributed), or the service environment is missing tools such as git, tmux, or no-mistakes. Refresh after tools and fleet state are healthy; if unknowns persist, raise it in chat rather than assuming only a PATH problem.";
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
      const yourGoVerbs = {
        go: "Previously approved",
        park: "Previously parked",
        guidance: "Guidance previously sent",
      };
      const verb = ack.kind === "your-go"
        ? (yourGoVerbs[ack.action] || "Previously answered")
        : (ack.verdict === "deny" ? "Previously denied" : "Previously approved");
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
      if (detail.provenance_note) {
        const provenance = textBlock("p", detail.provenance_note);
        provenance.className = "fmdash-provenance";
        panel.appendChild(provenance);
      }
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
      const ideasPage = document.querySelector('[data-dashboard-page="ideas"]');
      const placeholder = ideasPage && ideasPage.querySelector(".band-quiet");
      if (placeholder) placeholder.replaceWith(ideasSection);
      else if (ideasPage) ideasPage.appendChild(ideasSection);
      else if (main) main.appendChild(ideasSection);
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
    // Needs-you rows: every item awaiting the captain gets real controls.
    // A decision with a structured options document keeps its per-option flow
    // (Choose opens the existing detail view with one Approve per option plus
    // the custom answer); everything else gets generic go-ahead, not-now, and
    // send-guidance controls, and a concrete captain-deliverable ask leads
    // with a prefilled provide control. Every click only enqueues one durable
    // command record; firstmate re-resolves it through the normal lifecycle.
    async function sendYourGo(ref, action, text, button) {
      button.disabled = true;
      const original = button.textContent;
      button.textContent = "Sending…";
      try {
        const res = await postJson({ your_go: ref, action, text, dashboard_generated: cfg.generated });
        const out = await res.json();
        if (out.status === "queued" || out.status === "replaced" || out.status === "already-queued") {
          acknowledge(button);
          showPending(out.pending);
          return;
        }
        button.textContent = "Refused";
        button.disabled = false;
      } catch { button.textContent = original; button.disabled = false; }
    }
    cfg.yourGo.forEach((info) => {
      const row = document.querySelector('[data-your-go-ref="' + info.ref + '"]');
      if (!row || cfg.readOnly) return;
      const cell = row.querySelector(".why") || row;
      if (info.ack) {
        // Decision refs already acknowledge on their de-anonymized chip.
        if (info.target !== "decision") cell.appendChild(ackNode(info.ack, "fmdash-ack-chip"));
        return;
      }
      const controls = document.createElement("div");
      controls.className = "fmdash-yourgo";
      const makeButton = (label, aria, primary) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "fmdash-send" + (primary ? " fmdash-primary" : "");
        button.textContent = label;
        button.setAttribute("aria-label", aria);
        return button;
      };
      const openGuidance = (prefill, sendLabel) => {
        const existing = cell.querySelector("textarea");
        if (existing) { existing.focus(); return; }
        const box = document.createElement("textarea");
        box.className = "fmdash-guide";
        box.rows = 3;
        box.maxLength = 2000;
        box.value = prefill || "";
        box.placeholder = "Your guidance for firstmate…";
        box.setAttribute("aria-label", "Guidance for " + (info.title || info.ref));
        const send = makeButton(sendLabel, sendLabel + " for " + (info.title || info.ref));
        send.addEventListener("click", () => {
          if (box.value.trim()) sendYourGo(info.ref, "guidance", box.value.trim(), send);
        });
        cell.appendChild(box);
        cell.appendChild(send);
        box.focus();
      };
      // An approval-ready task with a recorded GitHub PR leads with the exact
      // merge review; the generic controls remain and grant no merge
      // authority. A live approval state renders instead of a second button.
      if (info.merge_candidate) {
        const state = info.merge_state;
        const settled = state && (state.status === "pending" || (state.status === "claimed" && (!state.outcome || state.outcome === "merging" || state.outcome === "merged")));
        if (settled) {
          controls.appendChild(mergeStateNode(state));
        } else {
          const review = makeButton("Review merge…", "Open exact merge review for " + (info.title || info.ref), true);
          review.addEventListener("click", (event) => { event.stopPropagation(); openMergeReview(info); });
          controls.appendChild(review);
          if (state) controls.appendChild(mergeStateNode(state));
        }
      }
      if (info.has_options) {
        const entry = cfg.refs[info.ref] || { t: "decision", label: info.title || info.ref };
        const choose = makeButton("Choose…", "Open options for " + (info.title || info.ref), true);
        choose.addEventListener("click", (event) => { event.stopPropagation(); openDetail(info.ref, entry); });
        controls.appendChild(choose);
      } else {
        if (info.ask) {
          const provide = makeButton("Provide it…", "Provide what is asked: " + info.ask, true);
          provide.addEventListener("click", () => openGuidance(info.ask + ": ", "Send"));
          controls.appendChild(provide);
        }
        const go = makeButton("Go ahead", "Go ahead with " + (info.title || info.ref), !info.ask);
        go.addEventListener("click", () => sendYourGo(info.ref, "go", null, go));
        const park = makeButton("Not now", "Not now - park " + (info.title || info.ref));
        park.addEventListener("click", () => sendYourGo(info.ref, "park", null, park));
        const guide = makeButton("Send guidance…", "Send guidance for " + (info.title || info.ref));
        guide.addEventListener("click", () => openGuidance("", "Send guidance"));
        controls.appendChild(go);
        controls.appendChild(park);
        controls.appendChild(guide);
      }
      cell.appendChild(controls);
    });
    // Exact merge review: everything rendered here is server-read evidence;
    // the approve click writes one typed, expiring, one-time approval record
    // that only firstmate's guarded consumer can act on.
    function mergeStateNode(state) {
      const label = state.status === "pending"
        ? "Merge approval sent - awaiting firstmate"
        : state.outcome === "merged"
          ? "Merged"
          : state.outcome === "merging" || !state.outcome
            ? "Approval received - being verified"
            : (state.outcome || "").indexOf("invalidated") === 0
              ? "Approval invalidated - review again"
              : "Merge attempt failed - see chat";
      const node = ackNode(null, "fmdash-ack-chip");
      node.textContent = label;
      return node;
    }
    function factRow(list, label, valueNode) {
      if (!valueNode) return;
      const li = document.createElement("li");
      const dt = document.createElement("span");
      dt.className = "fact-label";
      dt.textContent = label;
      const dd = document.createElement("span");
      dd.className = "fact-value";
      dd.appendChild(valueNode);
      li.appendChild(dt);
      li.appendChild(dd);
      list.appendChild(li);
    }
    async function openMergeReview(info) {
      const overlay = document.createElement("div");
      overlay.className = "fmdash-overlay";
      const panel = document.createElement("div");
      panel.className = "fmdash-panel";
      panel.setAttribute("role", "dialog");
      panel.setAttribute("aria-modal", "true");
      panel.setAttribute("aria-label", "Exact merge review for " + (info.title || info.ref));
      overlay.appendChild(panel);
      const close = () => { overlay.remove(); document.removeEventListener("keydown", onKey); };
      const onKey = (event) => { if (event.key === "Escape") close(); };
      overlay.addEventListener("click", (event) => { if (event.target === overlay) close(); });
      document.addEventListener("keydown", onKey);
      const kicker = document.createElement("div");
      kicker.className = "fmdash-kicker";
      kicker.textContent = "Exact merge review";
      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.className = "fmdash-close";
      closeButton.textContent = "Close";
      closeButton.addEventListener("click", close);
      kicker.appendChild(closeButton);
      panel.appendChild(kicker);
      panel.appendChild(textBlock("h2", info.title || info.ref));
      panel.appendChild(textBlock("p", "Checking the pull request…"));
      document.body.appendChild(overlay);
      closeButton.focus();
      let out = null;
      try {
        const res = await fetch("/api/merge/preview?ref=" + encodeURIComponent(info.ref));
        out = await res.json();
      } catch { /* rendered below */ }
      panel.replaceChildren(kicker);
      panel.appendChild(textBlock("h2", info.title || info.ref));
      if (!out || out.status !== "ok") {
        const refused = textBlock("p", (out && out.error) || "The merge review could not be loaded; refresh the dashboard and try again.");
        refused.className = "fmdash-merge-refused";
        panel.appendChild(refused);
        return;
      }
      const ev = out.evidence || {};
      if (out.approval && (out.approval.status === "pending" || out.approval.status === "claimed")) {
        panel.appendChild(mergeStateNode(out.approval));
      }
      if (!ev.available) {
        const refused = textBlock("p", "No merge control is available: " + (ev.reason || "the pull request evidence could not be read") + ".");
        refused.className = "fmdash-merge-refused";
        panel.appendChild(refused);
        return;
      }
      const facts = document.createElement("ul");
      facts.className = "fmdash-merge-facts";
      const link = document.createElement("a");
      link.href = ev.url;
      link.textContent = ev.url;
      factRow(facts, "Pull request", link);
      factRow(facts, "Repository", textBlock("span", ev.repo + " · PR #" + ev.number + (ev.base ? " into " + ev.base : "")));
      factRow(facts, "Title", textBlock("span", ev.title || "(no title)"));
      const sha = document.createElement("code");
      sha.textContent = ev.head_sha;
      factRow(facts, "Exact version", sha);
      factRow(facts, "Merge method", textBlock("span", ev.merge_method));
      factRow(facts, "Risk", textBlock("span", ev.risk || "not recorded"));
      if (ev.delivery_mode) factRow(facts, "Validation", textBlock("span", ev.delivery_mode === "no-mistakes" ? "no-mistakes pipeline (evidence: check set below)" : ev.delivery_mode));
      const checksWrap = document.createElement("div");
      (ev.checks || []).forEach((check) => {
        const row = document.createElement("div");
        row.className = check.green ? "fmdash-merge-check-green" : "fmdash-merge-check-bad";
        row.textContent = (check.green ? "✓ " : "✗ ") + check.name + " — " + check.result;
        checksWrap.appendChild(row);
      });
      factRow(facts, "Current checks", checksWrap);
      factRow(facts, "Approval window", textBlock("span", "an approval is valid for " + Math.round((out.ttl_seconds || cfg.mergeTtlSeconds) / 60) + " minutes and only for this exact version"));
      panel.appendChild(facts);
      if (!ev.eligible) {
        const refused = textBlock("p", "No merge control is available: " + (ev.reason || "the pull request is not ready") + ".");
        refused.className = "fmdash-merge-refused";
        panel.appendChild(refused);
        return;
      }
      const confirm = document.createElement("label");
      confirm.className = "fmdash-merge-confirm";
      const box = document.createElement("input");
      box.type = "checkbox";
      const confirmText = document.createElement("span");
      confirmText.textContent = "I reviewed PR #" + ev.number + " at version " + ev.head_sha.slice(0, 12) + " and approve merging exactly this version by " + ev.merge_method + ". Any change to the code or its checks cancels this approval.";
      confirm.appendChild(box);
      confirm.appendChild(confirmText);
      panel.appendChild(confirm);
      const approve = document.createElement("button");
      approve.type = "button";
      approve.className = "fmdash-merge-approve";
      approve.textContent = "Approve this exact merge";
      approve.disabled = true;
      approve.setAttribute("aria-label", "Approve merging PR #" + ev.number + " at version " + ev.head_sha.slice(0, 12));
      box.addEventListener("change", () => { approve.disabled = !box.checked; });
      approve.addEventListener("click", async () => {
        approve.disabled = true;
        approve.textContent = "Sending…";
        try {
          const res = await postJson2("/api/merge/approve", {
            ref: info.ref,
            url: ev.url,
            head_sha: ev.head_sha,
            checks_identity: ev.checks_identity,
            merge_method: ev.merge_method,
          });
          const result = await res.json();
          if (result.status === "queued" || result.status === "replaced" || result.status === "already-queued") {
            panel.replaceChildren(kicker);
            panel.appendChild(textBlock("h2", "Merge approval sent"));
            panel.appendChild(textBlock("p", "Firstmate will independently re-verify this exact version and merge it through its guarded path. The approval expires " + (result.expires_at ? new Date(result.expires_at).toLocaleString() : "shortly") + "; if anything about the pull request changes first, it is refused and you can review again."));
            panel.appendChild(textBlock("p", "This approved this one exact merge only. Anything else - and anything destructive or irreversible - still goes through chat."));
            showPending(result.pending || cfg.pending);
            return;
          }
          const refused = textBlock("p", (result && result.error) || "The approval was refused.");
          refused.className = "fmdash-merge-refused";
          panel.appendChild(refused);
          approve.textContent = "Approve this exact merge";
        } catch {
          const refused = textBlock("p", "The approval could not be sent; check your connection and reopen the review.");
          refused.className = "fmdash-merge-refused";
          panel.appendChild(refused);
          approve.textContent = "Approve this exact merge";
        }
      });
      panel.appendChild(approve);
      panel.appendChild(textBlock("p", "Approving asks firstmate to merge exactly this reviewed version. Every other action - and anything destructive, irreversible, or security-sensitive - still gets confirmed in chat."));
    }
    function postJson2(url, body) {
      return fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    }
    // Captain chat: a phone-ready conversation with the same firstmate agent.
    // Everything renders through text nodes - captain and agent text can never
    // become markup - and every send is an idempotent durable record.
    if (cfg.chat) {
      const nav = document.querySelector(".dashboard-nav");
      const chatMain = document.querySelector("main");
      if (nav && chatMain) {
        const navLink = document.createElement("a");
        navLink.href = "#chat";
        navLink.textContent = "Chat";
        navLink.setAttribute("data-dashboard-link", "chat");
        nav.appendChild(navLink);
        const page = document.createElement("section");
        page.className = "dashboard-page band fmdash-chatpage";
        page.id = "chat";
        page.setAttribute("data-dashboard-page", "chat");
        page.setAttribute("aria-labelledby", "chat-title");
        page.hidden = true;
        const wrap = document.createElement("div");
        wrap.className = "wrap";
        const kickerP = document.createElement("p");
        kickerP.className = "kicker";
        kickerP.textContent = "Direct line";
        const title = document.createElement("h2");
        title.id = "chat-title";
        title.className = "qhead";
        title.textContent = "Chat with your firstmate";
        const note = document.createElement("details");
        note.className = "fmdash-chat-note";
        const noteSummary = document.createElement("summary");
        noteSummary.textContent = "How private is this?";
        const noteBody = document.createElement("p");
        noteBody.textContent = "This conversation never leaves your tailnet: traffic between your device and the firstmate machine is protected by Tailscale WireGuard encryption plus HTTPS, including when it crosses a DERP relay. It is not end-to-end application encryption: content is readable at both endpoints, and history is stored on the firstmate machine protected by its disk encryption (FileVault) and endpoint security.";
        const noteCred = document.createElement("p");
        noteCred.textContent = "Never send passwords, API keys, tokens, or recovery codes here - firstmate will never ask for one in chat. Provide credentials at the terminal or keychain instead.";
        note.appendChild(noteSummary);
        note.appendChild(noteBody);
        note.appendChild(noteCred);
        const offline = document.createElement("div");
        offline.className = "fmdash-chat-offline";
        offline.setAttribute("role", "status");
        offline.textContent = "Offline - the dashboard cannot be reached right now. Your typed message is kept; retry when you are back on the tailnet.";
        const tools = document.createElement("div");
        tools.className = "fmdash-chat-tools";
        const search = document.createElement("input");
        search.type = "search";
        search.className = "fmdash-chat-search";
        search.placeholder = "Search this conversation…";
        search.setAttribute("aria-label", "Search this conversation");
        const earlier = document.createElement("button");
        earlier.type = "button";
        earlier.className = "fmdash-send";
        earlier.textContent = "Load earlier";
        earlier.hidden = true;
        tools.appendChild(search);
        tools.appendChild(earlier);
        const logList = document.createElement("ul");
        logList.className = "fmdash-chat-log";
        logList.setAttribute("role", "log");
        logList.setAttribute("aria-live", "polite");
        logList.setAttribute("aria-label", "Conversation with firstmate");
        const composer = document.createElement("div");
        composer.className = "fmdash-composer";
        const input = document.createElement("textarea");
        input.setAttribute("aria-label", "Message for firstmate");
        input.placeholder = "Message your firstmate…";
        input.autocomplete = "on";
        input.setAttribute("autocapitalize", "sentences");
        input.spellcheck = true;
        input.maxLength = cfg.chatMaxChars;
        const composerRow = document.createElement("div");
        composerRow.className = "fmdash-composer-row";
        const sendButton = document.createElement("button");
        sendButton.type = "button";
        sendButton.className = "fmdash-send";
        sendButton.textContent = "Send";
        sendButton.setAttribute("aria-label", "Send message to firstmate");
        const hint = document.createElement("span");
        hint.className = "fmdash-composer-hint";
        hint.textContent = window.matchMedia("(pointer: fine)").matches
          ? "Enter sends · Shift+Enter for a new line"
          : "Messages are picked up within about half a minute";
        composerRow.appendChild(sendButton);
        composerRow.appendChild(hint);
        const cred = document.createElement("p");
        cred.className = "fmdash-chat-cred";
        cred.textContent = "No secrets here: credentials go to the terminal or keychain, and long reports arrive as links.";
        composer.appendChild(input);
        composer.appendChild(composerRow);
        composer.appendChild(cred);
        wrap.appendChild(kickerP);
        wrap.appendChild(title);
        wrap.appendChild(note);
        wrap.appendChild(offline);
        wrap.appendChild(tools);
        wrap.appendChild(logList);
        wrap.appendChild(composer);
        page.appendChild(wrap);
        chatMain.appendChild(page);
        // The producer's own hash router now knows the injected page.
        window.dispatchEvent(new HashChangeEvent("hashchange"));

        const loaded = new Map();
        let oldestLoaded = null;
        let hasMore = false;
        const stateLabel = { sent: "Sent to firstmate", received: "Received - being worked", answered: "Answered" };
        function linkifyInto(node, text) {
          text.split(/(https:\\/\\/[^\\s]+)/g).forEach((part) => {
            if (/^https:\\/\\//.test(part)) {
              const a = document.createElement("a");
              a.href = part;
              a.textContent = part;
              node.appendChild(a);
            } else if (part) {
              node.appendChild(document.createTextNode(part));
            }
          });
        }
        function messageNodes(message) {
          const nodes = [];
          const mine = document.createElement("li");
          mine.className = "fmdash-msg fmdash-msg-captain";
          mine.setAttribute("data-message-id", message.message_id);
          const text = document.createElement("div");
          text.className = "fmdash-msg-text";
          linkifyInto(text, message.text);
          const meta = document.createElement("div");
          meta.className = "fmdash-msg-meta";
          const when = message.requested_at ? new Date(message.requested_at).toLocaleString() : "";
          const state = document.createElement("span");
          state.className = "fmdash-msg-state" + (message.state === "answered" ? " fmdash-msg-state-answered" : "");
          state.textContent = stateLabel[message.state] || message.state;
          meta.appendChild(document.createTextNode(when ? when + " · " : ""));
          meta.appendChild(state);
          mine.appendChild(text);
          mine.appendChild(meta);
          nodes.push(mine);
          if (message.reply) {
            const theirs = document.createElement("li");
            theirs.className = "fmdash-msg fmdash-msg-agent";
            const replyText = document.createElement("div");
            replyText.className = "fmdash-msg-text";
            linkifyInto(replyText, message.reply.text);
            const replyMeta = document.createElement("div");
            replyMeta.className = "fmdash-msg-meta";
            replyMeta.textContent = "Firstmate" + (message.reply.replied_at ? " · " + new Date(message.reply.replied_at).toLocaleString() : "");
            theirs.appendChild(replyText);
            theirs.appendChild(replyMeta);
            nodes.push(theirs);
          }
          return nodes;
        }
        function renderLog() {
          const atBottom = logList.scrollHeight - logList.scrollTop - logList.clientHeight < 80;
          logList.replaceChildren();
          const term = search.value.trim().toLowerCase();
          [...loaded.values()]
            .sort((a, b) => (a.message_id < b.message_id ? -1 : 1))
            .forEach((message) => {
              if (term) {
                const haystack = (message.text + " " + (message.reply ? message.reply.text : "")).toLowerCase();
                if (haystack.indexOf(term) === -1) return;
              }
              messageNodes(message).forEach((node) => logList.appendChild(node));
            });
          earlier.hidden = !hasMore;
          if (atBottom && !term) page.scrollTop = page.scrollHeight;
        }
        async function refreshChat(before) {
          try {
            const query = before ? "?limit=100&before=" + encodeURIComponent(before) : "?limit=100";
            const res = await fetch("/api/chat/history" + query);
            if (!res.ok) throw new Error("history");
            const out = await res.json();
            (out.messages || []).forEach((message) => loaded.set(message.message_id, message));
            if (!before) hasMore = out.has_more === true;
            else if (out.messages && out.messages.length) hasMore = out.has_more === true;
            const ids = [...loaded.keys()].sort();
            oldestLoaded = ids.length ? ids[0] : null;
            offline.classList.remove("fmdash-on");
            renderLog();
          } catch {
            offline.classList.add("fmdash-on");
          }
        }
        earlier.addEventListener("click", () => { if (oldestLoaded) refreshChat(oldestLoaded); });
        search.addEventListener("input", renderLog);
        let sending = false;
        let pendingSend = null;
        async function sendChat() {
          if (sending) return;
          const text = input.value.trim();
          if (!text) return;
          sending = true;
          sendButton.disabled = true;
          sendButton.textContent = "Sending…";
          if (!pendingSend || pendingSend.text !== text) {
            pendingSend = {
              text,
              clientKey: (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + "-" + Math.random().toString(16).slice(2, 10)),
            };
          }
          try {
            const res = await postJson2("/api/chat/send", { text, client_key: pendingSend.clientKey });
            const out = await res.json();
            pendingSend = null;
            if (out.status === "queued" || out.status === "already-received") {
              input.value = "";
              offline.classList.remove("fmdash-on");
              await refreshChat();
            } else {
              offline.classList.remove("fmdash-on");
              hint.textContent = out.error || "The message was refused.";
            }
          } catch {
            offline.classList.add("fmdash-on");
          }
          sending = false;
          sendButton.disabled = false;
          sendButton.textContent = "Send";
        }
        sendButton.addEventListener("click", sendChat);
        input.addEventListener("keydown", (event) => {
          if (event.key === "Enter" && !event.shiftKey && window.matchMedia("(pointer: fine)").matches) {
            event.preventDefault();
            sendChat();
          }
        });
        let chatStarted = false;
        function chatVisible() { return !page.hidden && document.visibilityState === "visible"; }
        function ensureChat() {
          if (!chatVisible()) return;
          if (!chatStarted) { chatStarted = true; refreshChat().then(() => { input.focus(); }); }
        }
        window.addEventListener("hashchange", ensureChat);
        document.addEventListener("visibilitychange", ensureChat);
        ensureChat();
        setInterval(() => { if (chatVisible() && chatStarted) refreshChat(); }, 8000);
      }
    }
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
    // either the state reader failed to resolve a current source (run-step /
    // pane / status-log) or the service environment is missing tools. Say so
    // honestly rather than presenting degraded data as truth or blaming only PATH.
    const unknownStates = (dashboard.html.match(/Authoritative current state: unknown/g) || []).length;
    const authoritativeStates = (dashboard.html.match(/Authoritative current state:/g) || []).length;
    const degraded = authoritativeStates > 0 && unknownStates * 2 >= authoritativeStates;
    if (degraded) log(`degraded render detected: ${unknownStates} of ${authoritativeStates} authoritative worker states read unknown; state source unresolved and/or service tools missing`);
    const acks = ackStates(dashboard.generated);
    const parked = parkedEntries(dashboard.html, refsFile);
    for (const info of parked) {
      const ack = acks.get(`unpark:${info.owner}/${info.id}`);
      if (ack) info.ack = ack;
    }
    const yourGo = yourGoEntries(dashboard.html, refsFile);
    for (const info of yourGo) {
      const ack = acks.get(info.target === "decision" ? `decision:${info.identity}` : `yourgo:${info.identity}`);
      if (ack) info.ack = ack;
      if (info.merge_candidate) info.merge_state = mergeApprovalState(info.identity.slice("main/".length));
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
      yourGo,
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
  if (req.method === "GET" && url.pathname === "/api/chat/history") {
    if (config.readOnly) {
      sendJson(res, 403, { status: "refused", error: "this dashboard is read-only; chat is not enabled" });
      return;
    }
    const limit = Number(url.searchParams.get("limit")) || 100;
    sendJson(res, 200, { status: "ok", ...chatHistory(limit, url.searchParams.get("before")) });
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/chat/send") {
    if (config.readOnly) {
      sendJson(res, 403, { status: "refused", error: "this dashboard is read-only; chat is not enabled" });
      return;
    }
    let body;
    try {
      body = JSON.parse(await readBody(req) || "{}");
    } catch {
      sendJson(res, 400, { status: "refused", error: "invalid request body" });
      return;
    }
    const problem = chatTextProblem(body.text);
    if (problem) {
      sendJson(res, 400, { status: "refused", error: problem });
      return;
    }
    if (typeof body.client_key !== "string" || !CHAT_CLIENT_KEY.test(body.client_key)) {
      sendJson(res, 400, { status: "refused", error: "a message needs a valid idempotency key" });
      return;
    }
    // Idempotency across double-taps, retries, and concurrent tabs: the same
    // client key never creates a second record.
    const existing = findChatByClientKey(body.client_key);
    if (existing) {
      sendJson(res, 200, { status: "already-received", message_id: existing.message_id });
      return;
    }
    if (readChatDir(CHAT_MESSAGES, "sent").length >= CHAT_PENDING_MAX) {
      sendJson(res, 429, { status: "refused", error: "too many messages are waiting for firstmate already; give it a moment to catch up" });
      return;
    }
    const record = enqueueChatMessage(body.text, body.client_key, requesterLogin(req));
    log(`queued chat message ${record.message_id} for ${record.requested_by}`);
    sendJson(res, 200, { status: "queued", message_id: record.message_id, requested_at: record.requested_at });
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/merge/preview") {
    if (config.readOnly) {
      sendJson(res, 403, { status: "refused", error: "this dashboard is read-only; merge review is not enabled" });
      return;
    }
    const target = mergeReviewTarget(url.searchParams.get("ref") || "");
    if (!target) {
      sendJson(res, 409, { status: "refused", error: "merge review is only available for a currently listed approval-ready task with a recorded GitHub pull request; refresh first" });
      return;
    }
    const evidence = await runMergeEvidence(target.task);
    sendJson(res, 200, {
      status: "ok",
      evidence,
      approval: mergeApprovalState(target.task),
      ttl_seconds: MERGE_TTL_SECS,
    });
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/merge/approve") {
    if (config.readOnly) {
      sendJson(res, 403, { status: "refused", error: "this dashboard is read-only; merge approval is not enabled" });
      return;
    }
    let body;
    try {
      body = JSON.parse(await readBody(req) || "{}");
    } catch {
      sendJson(res, 400, { status: "refused", error: "invalid request body" });
      return;
    }
    const target = mergeReviewTarget(typeof body.ref === "string" ? body.ref : "");
    if (!target) {
      sendJson(res, 409, { status: "refused", error: "merge approval is only available for a currently listed approval-ready task; refresh first" });
      return;
    }
    // The server's own fresh forge read is authoritative; the fields the
    // captain reviewed are echoed back only as a cross-check, so any code,
    // check, or method change between review and click refuses the approval.
    const evidence = await runMergeEvidence(target.task);
    if (evidence.available !== true || evidence.eligible !== true) {
      sendJson(res, 409, { status: "refused", error: evidence.reason || "the pull request is not eligible for merge approval" });
      return;
    }
    if (evidence.url !== target.url
      || body.url !== evidence.url
      || body.head_sha !== evidence.head_sha
      || body.checks_identity !== evidence.checks_identity
      || body.merge_method !== evidence.merge_method) {
      sendJson(res, 409, { status: "refused", error: "the pull request changed while you were reviewing; reopen the merge review" });
      return;
    }
    const pending = pendingRecords();
    const prior = pending.find((record) => record.kind === "merge-approval" && record.task === target.task);
    if (prior && prior.head_sha === evidence.head_sha && prior.checks_identity === evidence.checks_identity) {
      sendJson(res, 200, { status: "already-queued", pending: pending.length, expires_at: prior.expires_at || null });
      return;
    }
    const requestedAt = new Date();
    const record = {
      schema: "fm-dash-command.v1",
      kind: "merge-approval",
      id: `merge-${target.task}`,
      task: target.task,
      url: evidence.url,
      repo: evidence.repo,
      number: evidence.number,
      title: evidence.title,
      head_sha: evidence.head_sha,
      merge_method: evidence.merge_method,
      checks_identity: evidence.checks_identity,
      checks: evidence.checks,
      risk: evidence.risk,
      requested_by: requesterLogin(req),
      requested_at: requestedAt.toISOString(),
      expires_at: new Date(requestedAt.getTime() + MERGE_TTL_SECS * 1000).toISOString(),
      nonce: randomBytes(16).toString("hex"),
      dashboard_generated: target.generated,
      prompt: `Captain approved an exact dashboard merge for ${target.task}: ${evidence.url} at head ${evidence.head_sha}. Validate and consume this approval ONLY through bin/fm-dash-merge.sh ${target.task}, which revalidates every binding, independently rechecks the live PR, and merges through the guarded bin/fm-pr-merge.sh owner. Outside that consumer this record grants no authority.`,
    };
    const name = enqueueCommand(record);
    if (prior) removePendingIfUnchanged(prior);
    log(`queued merge approval for ${target.task} (${evidence.url} at ${evidence.head_sha}) as ${name} for ${record.requested_by}`);
    sendJson(res, 200, { status: prior ? "replaced" : "queued", pending: pendingRecords().length, expires_at: record.expires_at });
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

    // Your-go: generic captain interaction for any item the served dashboard
    // currently lists as awaiting the captain (a data-your-go-ref anchor),
    // resolved through the current-generation refs sidecar. The record only
    // routes the captain's verdict - go ahead, not now, or bounded guidance
    // text - to firstmate, which re-resolves it through the normal lifecycle;
    // the service never edits the backlog and the click grants no authority
    // beyond normal lifecycle checks. A newer verdict for the same item
    // replaces its pending predecessor so the newest captain intent wins.
    if (typeof body.your_go === "string") {
      const ref = body.your_go;
      const action = body.action;
      if (!/^item-\d{2,}$/.test(ref) || !["go", "park", "guidance"].includes(action)) {
        sendJson(res, 400, { status: "refused", error: "your-go accepts a currently listed captain-awaiting item and a go, park, or guidance action" });
        return;
      }
      const text = typeof body.text === "string" ? body.text.trim() : "";
      if (action === "guidance" && (!text || text.length > 2000)) {
        sendJson(res, 400, { status: "refused", error: "guidance needs bounded text" });
        return;
      }
      const currentDashboard = readDashboard();
      if (!currentDashboard || body.dashboard_generated !== currentDashboard.generated) {
        sendJson(res, 409, { status: "refused", error: "your-go was sent from a stale dashboard generation; refresh first" });
        return;
      }
      if (!currentDashboard.html.includes(`data-your-go-ref="${ref}"`)) {
        sendJson(res, 409, { status: "refused", error: `${ref} is not awaiting the captain on the current dashboard; refresh first` });
        return;
      }
      const currentRefs = readRefs(currentDashboard.generated);
      const entry = currentRefs?.refs?.[ref];
      if (!entry || entry.kind !== "item") {
        sendJson(res, 409, { status: "refused", error: `${ref} cannot be resolved against the current dashboard generation; refresh first` });
        return;
      }
      const decision = decisionRef(entry);
      if (decision && projectedDecisionDetail(entry, decision).available) {
        sendJson(res, 409, { status: "refused", error: `${ref} has structured decision options; use the per-option approval flow` });
        return;
      }
      const separator = entry.value.indexOf("/");
      const workHome = decision ? decision.home : entry.value.slice(0, separator);
      const workId = decision ? decision.key : entry.value.slice(separator + 1);
      const decisionIdentity = decision ? `${decision.home}/${decision.origin || ""}/${decision.key}` : null;
      const identityKey = decision ? `decision:${decisionIdentity}` : `yourgo:${entry.value}`;
      const pending = pendingRecords();
      const prior = pending.find((record) => record.kind === "your-go" && ackKey(record) === identityKey);
      if (prior && prior.action === action && (prior.guidance || null) === (action === "guidance" ? text : null)) {
        sendJson(res, 200, { status: "already-queued", pending: pending.length });
        return;
      }
      const subject = decision
        ? `decision ${decision.key} for ${decision.origin || "legacy"} in ${decision.home}`
        : `work ${workId}${workHome === "main" ? "" : ` (owned by domain supervisor ${workHome})`}`;
      const prompts = {
        go: `Captain clicked GO AHEAD for ${subject}: re-resolve its current wait, lift a captain hold through the normal backlog lifecycle where one is set, and proceed through normal re-evaluation, project resolution, and authority checks. This grants no authority beyond those checks; a PR merge, destructive, or irreversible consequence still needs chat confirmation.`,
        park: `Captain clicked NOT NOW for ${subject}: park it through the normal backlog lifecycle so it rests outside the active queue until the captain returns to it. This changes scheduling only and grants no other authority.`,
        guidance: `Captain sent guidance for ${subject}: ${text}. Treat it as captain input on that waiting item${decision ? " and route any resulting answer through the normal decision lifecycle" : " through the normal lifecycle"}; a destructive or irreversible consequence still needs chat confirmation.`,
      };
      const record = {
        schema: "fm-dash-command.v1",
        kind: "your-go",
        id: ref,
        action,
        guidance: action === "guidance" ? text : null,
        work_id: workId,
        work_home: workHome,
        work_identity: decision ? null : entry.value,
        decision_identity: decisionIdentity,
        decision_origin: decision ? decision.origin : null,
        requested_by: requesterLogin(req),
        requested_at: new Date().toISOString(),
        dashboard_generated: currentDashboard.generated,
        prompt: prompts[action],
      };
      const name = enqueueCommand(record);
      if (prior) removePendingIfUnchanged(prior);
      log(`queued your-go ${action} for ${workId} as ${name} for ${record.requested_by}`);
      sendJson(res, 200, { status: prior ? "replaced" : "queued", pending: pendingRecords().length });
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
