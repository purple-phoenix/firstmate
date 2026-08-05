#!/usr/bin/env bash
# fm-dash-merge.sh - one-time consumer for an exact dashboard merge approval.
#
# Single owner of turning a claimed fm-dash-command.v1 kind=merge-approval
# record into at most one guarded merge attempt. The dashboard service can only
# WRITE approval records; this consumer is where authority is checked, and only
# the existing guarded bin/fm-pr-merge.sh owner performs the merge itself.
#
# A record is honored only when every binding validates: schema and kind, a
# captain login from config/dash.json, an unexpired approval, the canonical
# GitHub PR URL re-parsed through bin/fm-pr-lib.sh with matching repository and
# number, the task's own recorded pr= metadata, a valid exact head SHA, a valid
# one-time nonce, and a known merge method. Consumption is crash-safe and
# one-time: the nonce is claimed with a create-only hard link under
# state/dash-merge/consumed/ BEFORE any merge attempt, so replays, concurrent
# invocations, and restarts can never produce a second merge attempt from one
# approval. After the claim, the live PR is independently rechecked through
# bin/fm-dash-pr-evidence.mjs: the head SHA and current check-set identity must
# still exactly match what the captain approved, or the approval is recorded
# invalidated and a fresh approval is required. A consumed approval never
# regains authority, whatever the PR does afterwards.
#
# Usage: fm-dash-merge.sh <task-id>
# Exit codes: 0 merged; 2 no valid approval record; 3 approval already
# consumed (no second attempt); 4 approval invalidated by live recheck;
# 5 merge attempt failed or outcome uncertain - report to the captain, never
# auto-retry.
# Environment: FM_DASH_PR_EVIDENCE_BIN and FM_DASH_PR_MERGE_BIN override the
# evidence probe and merge owner for tests ONLY and must stay unset in real
# deployments.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DASH_CONFIG="$CONFIG_DIR/dash.json"
INBOX="$STATE/dash-inbox"
CONSUMED_DIR="$STATE/dash-merge/consumed"
EVIDENCE_BIN="${FM_DASH_PR_EVIDENCE_BIN:-$SCRIPT_DIR/fm-dash-pr-evidence.mjs}"
MERGE_BIN="${FM_DASH_PR_MERGE_BIN:-$SCRIPT_DIR/fm-pr-merge.sh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,31p'
  exit "${1:-0}"
}

case "${1:-}" in
  -h|--help|'') usage "${1:+0}" ;;
esac
[ "$#" -eq 1 ] || { echo "error: invalid merge-approval request" >&2; exit 2; }
ID=$1
fm_pr_task_id_valid "$ID" || { echo "error: invalid merge-approval request" >&2; exit 2; }

command -v node >/dev/null 2>&1 || { echo "error: node is required to read dashboard approval records" >&2; exit 2; }

# Locate the newest structurally valid, unexpired approval record for this
# task among claimed (archived) records. Field extraction is data-only; the
# record never becomes shell source.
read_record() {
  local file=$1
  # shellcheck disable=SC2016 # JavaScript template literals, not shell
  node -e '
    const fs = require("node:fs");
    try {
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const fields = ["task", "url", "repo", "number", "head_sha", "merge_method", "checks_identity", "requested_by", "requested_at", "expires_at", "nonce"];
      if (r.schema !== "fm-dash-command.v1" || r.kind !== "merge-approval") process.exit(1);
      for (const field of fields) {
        const value = field === "number" ? r[field] : r[field];
        if (field === "number" ? !Number.isInteger(value) : (typeof value !== "string" || value === "")) process.exit(1);
      }
      if (!/^[0-9a-f]{32}$/.test(r.nonce)) process.exit(1);
      if (!["squash", "merge", "rebase"].includes(r.merge_method)) process.exit(1);
      if (!Number.isFinite(Date.parse(r.requested_at)) || !Number.isFinite(Date.parse(r.expires_at))) process.exit(1);
      process.stdout.write(fields.map((field) => String(r[field])).join("\u001f"));
    } catch {
      process.exit(1);
    }
  ' "$file"
}

captain_login_authorized() {
  local login=$1
  # shellcheck disable=SC2016 # JavaScript template literals, not shell
  node -e '
    const fs = require("node:fs");
    try {
      const parsed = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const logins = Array.isArray(parsed.captain_logins) ? parsed.captain_logins : [];
      process.exit(logins.includes(process.argv[2]) ? 0 : 1);
    } catch {
      process.exit(1);
    }
  ' "$DASH_CONFIG" "$login"
}

now_epoch=$(date +%s)
STATE_DEVICE=$(fm_pr_file_device "$STATE") || { echo "error: task state is unavailable" >&2; exit 2; }
best_file=""
best_requested=""
R_URL="" R_REPO="" R_NUMBER="" R_HEAD="" R_METHOD="" R_CHECKS="" R_BY="" R_EXPIRES="" R_NONCE=""
for file in "$INBOX/archive"/*.json; do
  [ -e "$file" ] || continue
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  fm_pr_private_file_valid "$file" 600 "$STATE_DEVICE" >/dev/null 2>&1 || continue
  fields=$(read_record "$file") || continue
  IFS=$'\037' read -r r_task r_url r_repo r_number r_head r_method r_checks r_by r_requested r_expires r_nonce <<EOF
$fields
EOF
  [ "$r_task" = "$ID" ] || continue
  if [ -z "$best_requested" ] || [ "$best_requested" \< "$r_requested" ]; then
    best_file=$file
    best_requested=$r_requested
    R_URL=$r_url R_REPO=$r_repo R_NUMBER=$r_number R_HEAD=$r_head
    R_METHOD=$r_method R_CHECKS=$r_checks R_BY=$r_by
    R_EXPIRES=$r_expires R_NONCE=$r_nonce
  fi
done

if [ -z "$best_file" ]; then
  echo "error: no claimed dashboard merge approval is on record for this task" >&2
  exit 2
fi

# Every binding must validate before the approval counts as the captain's word.
if ! captain_login_authorized "$R_BY"; then
  echo "error: the approval was not made by an authorized captain login" >&2
  exit 2
fi
expires_epoch=$(node -e 'const t = Date.parse(process.argv[1]); if (!Number.isFinite(t)) process.exit(1); console.log(Math.floor(t / 1000));' "$R_EXPIRES") || {
  echo "error: the approval carries an unreadable expiry" >&2
  exit 2
}
if [ "$now_epoch" -ge "$expires_epoch" ]; then
  echo "error: the approval expired at $R_EXPIRES; a fresh dashboard approval is required" >&2
  exit 2
fi
if ! fm_pr_url_parse "$R_URL" || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: the approval does not name a canonical GitHub pull request" >&2
  exit 2
fi
if [ "$FM_PR_PATH" != "$R_REPO" ] || [ "$FM_PR_NUMBER" != "$R_NUMBER" ]; then
  echo "error: the approval's repository or PR number does not match its URL" >&2
  exit 2
fi
fm_pr_head_valid "$R_HEAD" || { echo "error: the approval carries an invalid head commit" >&2; exit 2; }
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 2
fi
grep -qxF "pr=$R_URL" "$META" || {
  echo "error: the approval's pull request is not the one recorded for this task" >&2
  exit 2
}

# One-time consumption: claim the nonce BEFORE any merge attempt. A second
# invocation, a replay, or a crash-restart finds the claim and never attempts
# a second merge from the same approval.
umask 077
mkdir -p "$CONSUMED_DIR"
chmod 700 "$STATE/dash-merge" "$CONSUMED_DIR" 2>/dev/null || true
CONSUMED="$CONSUMED_DIR/$R_NONCE"
write_outcome() {
  local outcome=$1 tmp
  tmp=$(mktemp "$CONSUMED_DIR/.tmp-outcome.XXXXXX") || return 1
  printf 'task=%s\nurl=%s\nhead_sha=%s\noutcome=%s\nrecorded_at=%s\n' \
    "$ID" "$R_URL" "$R_HEAD" "$outcome" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CONSUMED"
}
claim_tmp=$(mktemp "$CONSUMED_DIR/.tmp-claim.XXXXXX") || exit 2
printf 'task=%s\nurl=%s\nhead_sha=%s\noutcome=claimed\nrecorded_at=%s\n' \
  "$ID" "$R_URL" "$R_HEAD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$claim_tmp" || { rm -f -- "$claim_tmp"; exit 2; }
chmod 600 "$claim_tmp" || { rm -f -- "$claim_tmp"; exit 2; }
if ! ln -- "$claim_tmp" "$CONSUMED" 2>/dev/null; then
  rm -f -- "$claim_tmp"
  prior_outcome=$(grep '^outcome=' "$CONSUMED" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  echo "error: this approval was already consumed (outcome: ${prior_outcome:-unknown}); a new merge attempt needs a fresh dashboard approval" >&2
  exit 3
fi
rm -f -- "$claim_tmp"

# Independent live recheck through the read-only evidence owner: the PR must
# still be exactly what the captain approved.
evidence=$("$EVIDENCE_BIN" "$ID" 2>/dev/null) || evidence=""
# shellcheck disable=SC2016 # JavaScript template literals, not shell
recheck=$(printf '%s' "$evidence" | node -e '
  let raw = "";
  process.stdin.on("data", (c) => { raw += c; });
  process.stdin.on("end", () => {
    try {
      const e = JSON.parse(raw);
      if (e.schema !== "fm-dash-pr-evidence.v1") throw new Error("unexpected evidence schema");
      if (e.available !== true) throw new Error(e.reason || "PR evidence unavailable");
      if (e.eligible !== true) throw new Error(e.reason || "PR is no longer eligible");
      if (e.url !== process.argv[1]) throw new Error("PR identity changed");
      if (e.head_sha !== process.argv[2]) throw new Error("the PR head moved since approval");
      if (e.checks_identity !== process.argv[3]) throw new Error("the PR check set or results changed since approval");
      console.log("ok");
    } catch (error) {
      console.log(`refused: ${error.message}`);
    }
  });
' "$R_URL" "$R_HEAD" "$R_CHECKS") || recheck="refused: evidence recheck could not run"
if [ "$recheck" != ok ]; then
  reason=${recheck#refused: }
  write_outcome "invalidated: $reason" || true
  echo "error: approval invalidated by live recheck - $reason; a fresh dashboard approval is required" >&2
  exit 4
fi

write_outcome "merging" || true
if "$MERGE_BIN" "$ID" "$R_URL" -- "--$R_METHOD"; then
  write_outcome "merged" || true
  echo "merged: $R_URL at $R_HEAD (approved by $R_BY via dashboard)"
  exit 0
fi
write_outcome "attempt-failed" || true
echo "error: the merge attempt did not complete; verify the PR state by hand and get a fresh approval before any retry" >&2
exit 5
