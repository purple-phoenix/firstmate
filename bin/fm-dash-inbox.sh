#!/usr/bin/env bash
# fm-dash-inbox.sh - firstmate-side consumer for captain dashboard commands.
#
# Single owner of state/dash-inbox/ consumption: listing pending
# fm-dash-command.v1 records written by bin/fm-dash-serve.mjs and claiming them
# durably. "claim" prints each record before archiving it under
# state/dash-inbox/archive/ (newest 50 kept), so an interruption can re-surface
# a command but can never silently lose one. Delivery is at-least-once across
# interruption, and the capacity skill requires idempotency checks before
# handling re-surfaced CAP actions, decision answers, idea verdicts, or unpark requests.
# Each claimed prompt carries the capacity skill's authority limits and never
# grants destructive or merge authority.
# After archiving at least one command, claim touches
# state/dash-inbox/.model-stale so the dashboard service regenerates the model
# promptly and handled clicks stop rendering as undecided; the archived records
# themselves keep acknowledging each click on the served page in the meantime.
#
# Usage: fm-dash-inbox.sh [list|claim|pending-count]
#   list           print pending commands without consuming them
#   claim          print and archive pending commands for handling
#   pending-count  print the number of pending commands
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INBOX="$STATE/dash-inbox"
ARCHIVE="$INBOX/archive"
ARCHIVE_KEEP=50

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,21p'
  exit "${1:-0}"
}

pending_files() {
  [ -d "$INBOX" ] || return 0
  find "$INBOX" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort
}

print_record() {
  local file=$1
  # shellcheck disable=SC2016 # the $-expressions below are JavaScript template literals, not shell
  node -e '
    const fs = require("node:fs");
    try {
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (r.schema !== "fm-dash-command.v1" || typeof r.id !== "string" || typeof r.prompt !== "string") {
        console.log(`- unreadable record ${process.argv[1]} (unexpected schema); inspect it by hand`);
        process.exit(0);
      }
      console.log(`- ${r.id} requested by ${r.requested_by || "unknown"} at ${r.requested_at || "unknown"} (dashboard generated ${r.dashboard_generated || "unknown"})`);
      console.log(`  prompt: ${r.prompt.replace(/\s+/g, " ")}`);
    } catch {
      console.log(`- unreadable record ${process.argv[1]} (invalid JSON); inspect it by hand`);
    }
  ' "$file"
}

prune_archive() {
  local extra
  extra=$(find "$ARCHIVE" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort -r | tail -n +$((ARCHIVE_KEEP + 1)))
  [ -n "$extra" ] || return 0
  printf '%s\n' "$extra" | while IFS= read -r old; do
    rm -f -- "$old"
  done
}

command -v node >/dev/null 2>&1 || { echo "error: node is required to read dashboard command records" >&2; exit 1; }

case "${1:-list}" in
  -h|--help)
    usage 0
    ;;
  pending-count)
    pending_files | grep -c . || true
    ;;
  list)
    files=$(pending_files)
    if [ -z "$files" ]; then
      echo "no pending dashboard commands"
      exit 0
    fi
    printf 'pending: %s captain dashboard command(s)\n' "$(printf '%s\n' "$files" | grep -c .)"
    printf '%s\n' "$files" | while IFS= read -r f; do
      print_record "$f"
    done
    ;;
  claim)
    files=$(pending_files)
    if [ -z "$files" ]; then
      echo "no pending dashboard commands"
      exit 0
    fi
    mkdir -p "$ARCHIVE"
    chmod 700 "$ARCHIVE" 2>/dev/null || true
    delivered=0
    archived=0
    while IFS= read -r f; do
      dest="$ARCHIVE/$(basename "$f")"
      if [ -e "$dest" ]; then
        rm -f -- "$f"
        continue
      fi
      [ -e "$f" ] || continue
      print_record "$f"
      delivered=$((delivered + 1))
      if mv -n -- "$f" "$dest" 2>/dev/null && [ ! -e "$f" ] && [ -e "$dest" ]; then
        if touch "$dest"; then
          archived=$((archived + 1))
        else
          mv -n -- "$dest" "$f" 2>/dev/null || true
        fi
      fi
    done <<EOF
$files
EOF
    if [ "$delivered" -eq 0 ]; then
      echo "no pending dashboard commands"
      exit 0
    fi
    if [ "$archived" -gt 0 ]; then
      touch "$INBOX/.model-stale"
      chmod 600 "$INBOX/.model-stale" 2>/dev/null || true
    fi
    printf 'delivered: %s captain dashboard command(s)\n' "$delivered"
    printf 'archived: %s captain dashboard command(s)\n' "$archived"
    echo "apply idempotency checks to every delivered prompt, then handle it by kind under the capacity skill; its authority limits apply and nothing here authorizes a merge, discard, or other destructive act."
    echo "CAP records approve that action ID; decision records answer the named owner-qualified decision through the decision lifecycle, with destructive consequences re-confirmed in chat; idea records are captain verdicts: approve creates work through the normal backlog lifecycle, deny records the outcome, and suggestions are captain input."
    prune_archive
    ;;
  *)
    usage 2 >&2
    ;;
esac
