#!/usr/bin/env node
/**
 * fm-dash-pr-evidence.mjs - read-only merge-review evidence for one task's PR.
 *
 * Single owner of the typed evidence record that the dashboard service's merge
 * confirmation surface and bin/fm-dash-merge.sh both consume. It reads the
 * task's recorded pr= URL from state/<id>.meta, validates the canonical GitHub
 * PR URL shape (mirroring bin/fm-pr-lib.sh; GitLab and every other provider is
 * refused because bin/fm-pr-merge.sh addresses GitHub only), asks the forge one
 * bounded read-only question through the gh CLI, and prints one
 * fm-dash-pr-evidence.v1 JSON object on stdout. It never mutates the PR, the
 * task, or any local state, and it never receives or prints a credential; gh
 * resolves its own stored auth exactly as the capacity producer's bounded
 * reads already do.
 *
 * Eligibility is deliberately strict: eligible=true only for an open,
 * non-draft, mergeable pull request whose current checks are ALL terminal
 * green (CheckRun status COMPLETED with conclusion SUCCESS or SKIPPED;
 * StatusContext state SUCCESS). That is a superset of GitHub's required-check
 * set, so a PR the dashboard offers for merge is never weaker than the
 * branch-protection requirement. checks_identity is the sha256 of the sorted
 * "name<TAB>result" lines and binds an approval to the exact check set and
 * results it was granted against.
 *
 * Usage: fm-dash-pr-evidence.mjs <task-id>
 * Environment: FM_HOME / FM_STATE_OVERRIDE select the home;
 * FM_DASH_PR_GH_BIN overrides the gh binary for tests ONLY and must stay
 * unset in real deployments.
 * Exit 0 with a JSON object always (available:false carries the reason);
 * exit 2 only for an unusable invocation.
 */

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const FM_HOME = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const STATE = process.env.FM_STATE_OVERRIDE || path.join(FM_HOME, "state");
const GH_BIN = process.env.FM_DASH_PR_GH_BIN || "gh";
const GH_TIMEOUT_MS = 20000;
const MAX_GH_OUTPUT = 1024 * 1024;

function emit(payload) {
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  process.exit(0);
}

function unavailable(task, reason) {
  emit({ schema: "fm-dash-pr-evidence.v1", task, available: false, eligible: false, reason });
}

// Mirrors bin/fm-pr-lib.sh fm_task_id_path_safe.
function taskIdValid(id) {
  return typeof id === "string" && id.length > 0 && id.length <= 64 && !id.startsWith(".") && /^[A-Za-z0-9._-]+$/.test(id);
}

// Mirrors bin/fm-pr-lib.sh fm_pr_url_parse's GitHub arm, including the
// double-hyphen owner refusal and the "."/".." repo refusal.
function parseGithubPrUrl(raw) {
  const match = /^https:\/\/github\.com\/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])\/([A-Za-z0-9._-]{1,100})\/pull\/([1-9][0-9]*)$/.exec(raw);
  if (!match) return null;
  if (match[1].includes("--")) return null;
  if (match[2] === "." || match[2] === "..") return null;
  return { url: raw, owner: match[1], repo: match[2], number: Number(match[3]) };
}

function checkResults(rollup) {
  if (!Array.isArray(rollup)) return null;
  const checks = [];
  for (const entry of rollup) {
    if (!entry || typeof entry !== "object") return null;
    if (typeof entry.context === "string") {
      // Legacy commit status context: terminal green is exactly SUCCESS.
      const state = typeof entry.state === "string" ? entry.state : "UNKNOWN";
      checks.push({ name: entry.context.slice(0, 200), result: state, green: state === "SUCCESS" });
      continue;
    }
    const name = typeof entry.name === "string" ? entry.name.slice(0, 200) : null;
    if (!name) return null;
    const status = typeof entry.status === "string" ? entry.status : "UNKNOWN";
    const conclusion = typeof entry.conclusion === "string" ? entry.conclusion : "";
    const terminal = status === "COMPLETED";
    const green = terminal && (conclusion === "SUCCESS" || conclusion === "SKIPPED");
    checks.push({ name, result: terminal ? conclusion || "UNKNOWN" : status, green });
  }
  return checks;
}

function checksIdentity(checks) {
  const lines = checks.map((check) => `${check.name}\t${check.result}`).sort();
  return createHash("sha256").update(lines.join("\n")).digest("hex");
}

function main() {
  const args = process.argv.slice(2);
  if (args.length !== 1 || args[0] === "--help" || args[0] === "-h") {
    process.stderr.write("usage: fm-dash-pr-evidence.mjs <task-id>\n");
    process.exit(args.length === 1 ? 0 : 2);
  }
  const task = args[0];
  if (!taskIdValid(task)) {
    process.stderr.write("error: invalid task id\n");
    process.exit(2);
  }
  const metaPath = path.join(STATE, `${task}.meta`);
  let metaStat;
  try {
    metaStat = fs.lstatSync(metaPath);
  } catch {
    unavailable(task, "task metadata is unavailable");
  }
  if (!metaStat.isFile() || metaStat.isSymbolicLink()) unavailable(task, "task metadata is unavailable");
  const meta = {};
  for (const line of fs.readFileSync(metaPath, "utf8").split("\n")) {
    const pair = /^([a-z_]+)=(.*)$/.exec(line);
    if (pair) meta[pair[1]] = pair[2];
  }
  if (!meta.pr) unavailable(task, "the task has no recorded pull request");
  const parsed = parseGithubPrUrl(meta.pr);
  if (!parsed) unavailable(task, "the recorded pull request is not a canonical GitHub PR URL; dashboard merge review supports GitHub only");

  const fields = "state,isDraft,mergeable,headRefOid,title,baseRefName,statusCheckRollup,url,number";
  const probe = spawnSync(GH_BIN, ["pr", "view", parsed.url, "--json", fields], {
    cwd: ROOT,
    env: process.env,
    timeout: GH_TIMEOUT_MS,
    maxBuffer: MAX_GH_OUTPUT,
    encoding: "utf8",
  });
  if (probe.error || probe.status !== 0) {
    unavailable(task, "the pull request could not be read from the forge right now");
  }
  let pr;
  try {
    pr = JSON.parse(probe.stdout);
  } catch {
    unavailable(task, "the forge returned an unreadable pull request record");
  }
  const headSha = typeof pr.headRefOid === "string" && /^[0-9a-f]{40}$|^[0-9a-f]{64}$/.test(pr.headRefOid) ? pr.headRefOid : null;
  const checks = checkResults(pr.statusCheckRollup ?? []);
  if (!headSha || typeof pr.state !== "string" || checks === null || pr.url !== parsed.url || pr.number !== parsed.number) {
    unavailable(task, "the forge pull request record was missing required evidence");
  }
  const allGreen = checks.length > 0 && checks.every((check) => check.green);
  const open = pr.state === "OPEN";
  const draft = pr.isDraft === true;
  const mergeable = pr.mergeable === "MERGEABLE";
  let ineligibleReason = null;
  if (!open) ineligibleReason = `the pull request is ${pr.state.toLowerCase()}, not open`;
  else if (draft) ineligibleReason = "the pull request is a draft";
  else if (!mergeable) ineligibleReason = pr.mergeable === "CONFLICTING" ? "the pull request has merge conflicts" : "the forge has not confirmed the pull request is mergeable";
  else if (checks.length === 0) ineligibleReason = "the pull request has no recorded checks, so green cannot be shown";
  else if (!allGreen) ineligibleReason = "not every current check is terminal green";

  emit({
    schema: "fm-dash-pr-evidence.v1",
    task,
    available: true,
    eligible: ineligibleReason === null,
    reason: ineligibleReason,
    url: parsed.url,
    repo: `${parsed.owner}/${parsed.repo}`,
    number: parsed.number,
    title: typeof pr.title === "string" ? pr.title.slice(0, 300) : "",
    base: typeof pr.baseRefName === "string" ? pr.baseRefName.slice(0, 200) : "",
    state: pr.state,
    is_draft: draft,
    mergeable: pr.mergeable ?? "UNKNOWN",
    head_sha: headSha,
    checks,
    all_checks_green: allGreen,
    checks_identity: checksIdentity(checks),
    merge_method: "squash",
    risk: typeof meta.risk === "string" && meta.risk ? meta.risk.slice(0, 100) : null,
    delivery_mode: typeof meta.mode === "string" && meta.mode ? meta.mode.slice(0, 40) : null,
    observed_at: new Date().toISOString(),
  });
}

main();
