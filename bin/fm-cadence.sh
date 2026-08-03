#!/usr/bin/env bash
# fm-cadence.sh - the single owner of this home's watcher check cadence.
#
# THE CONTRACT (docs/configuration.md "Watcher check cadence" is the operator-facing
# owner): bin/fm-watch.sh sweeps state/*.check.sh every FM_CHECK_INTERVAL seconds,
# 300 by default. A home with an ARMED INBOUND CAPTAIN CHANNEL cannot afford that:
# a channel poll is the only thing that notices a captain message, so a five-minute
# sweep is a five-minute delivery delay. Such a home therefore sweeps every 30s.
#
# The whole mechanism is ONE generated file, config/check-cadence.env, which
# exports FM_CHECK_INTERVAL=30. It exists exactly while an inbound captain channel
# is armed - X mode relay polling (state/x-watch.check.sh), the Telegram captain
# channel (state/fm-telegram.check.sh), or both - and is absent otherwise, so a
# home with neither keeps the default cadence and nothing about it changes. Both
# channels resolve to the SAME file: two armed channels are still one cadence, one
# config owner, and one supervision cycle.
#
# The armed-channel predicate is not duplicated here; bin/fm-supervision-lib.sh
# already owns it for the "this home needs a live supervision cycle" decision, and
# a home that needs a cycle for a channel is exactly a home that needs it fast.
#
# WHY A FILE AND NOT A WATCHER-SIDE READ: every harness protocol starts its watcher
# through a shell it controls, so a sourceable env file is the one mechanism all of
# them (claude's Stop auto-arm, codex's checkpoint, the pi extension, the opencode
# plugin, grok's tracked background arm, and the away-mode daemon) can honor with
# no new process, no second poller, and no watcher restart machinery of its own.
#
# WHAT THIS SCRIPT WILL NOT PRETEND: fm-watch.sh reads FM_CHECK_INTERVAL once, at
# process start. Reconciling this file does NOT re-cadence a watcher that is
# already running, and this script never restarts one - restarting the supervision
# cycle belongs to the harness protocol that owns it. Every transition line
# therefore carries the harness-specific repair instruction and says plainly that
# the new cadence starts with the next supervision cycle.
#
# Usage:
#   fm-cadence.sh reconcile   Converge the generated file with the armed channels,
#                             idempotently. Prints ONE "CADENCE: ..." line only on a
#                             real transition (armed, cleared, or failed) and stays
#                             completely silent when the file already matches, so a
#                             steady-state session sees nothing. Also removes the
#                             pre-rename config/x-mode.env left by an older
#                             firstmate. Exit 0 on success, 1 if a write or removal
#                             failed (the diagnostic is still printed).
#   fm-cadence.sh path        Print the cadence file path for this home.
#   fm-cadence.sh status      Print "fast <path>" or "default", plus the armed
#                             channels, for operators and tests.
#
# Home resolution is the usual one: FM_HOME, then FM_CONFIG_OVERRIDE /
# FM_STATE_OVERRIDE for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-cadence-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-cadence-lib.sh"

CADENCE_FILE=$(fm_cadence_file "$CONFIG")
LEGACY_FILE=$(fm_cadence_legacy_file "$CONFIG")
FAST_SECS=$FM_CADENCE_FAST_SECS

# The armed channels, as operator-readable words, for the transition line.
armed_channels() {
  local names=
  [ -f "$STATE/x-watch.check.sh" ] && names="X mode"
  if [ -f "$STATE/fm-telegram.check.sh" ]; then
    [ -n "$names" ] && names="$names and the Telegram captain channel" \
      || names="the Telegram captain channel"
  fi
  printf '%s' "$names"
}

supervision_repair() {
  local out
  out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
    || out='repair missing watcher supervision according to the session-start operating block.'
  printf '%s' "$out"
}

cmd_reconcile() {
  local want=0 body rc=0 legacy_note=''
  fm_supervision_channel_armed "$STATE" && want=1

  # Migrate off the pre-rename file first, in both directions: leaving it behind
  # would give a home two cadence owners, and an already-running watcher armed from
  # it keeps its 30s cadence until it restarts either way.
  if fmx_generated_present "$LEGACY_FILE"; then
    if fmx_generated_remove "$LEGACY_FILE"; then
      legacy_note=" (replacing the older config/x-mode.env)"
    else
      echo "CADENCE: failed to remove the superseded config/x-mode.env; remove it by hand so this home has one cadence owner"
      rc=1
    fi
  fi

  if [ "$want" -eq 1 ]; then
    mkdir -p "$CONFIG" 2>/dev/null || {
      echo "CADENCE: failed to create the config directory; the ${FAST_SECS}s check cadence is not armed and captain messages stay on the 300s cadence"
      return 1
    }
    # Unchanged content is left byte-identical by the writer, so a steady-state
    # session neither rewrites the file nor prints anything.
    if fmx_generated_present "$CADENCE_FILE" \
      && [ -z "$legacy_note" ] \
      && cmp -s "$CADENCE_FILE" <(fm_cadence_body); then
      return "$rc"
    fi
    body=$(fm_cadence_body)
    if fmx_generated_write_if_changed "$CADENCE_FILE" "$body" 600; then
      echo "CADENCE: ${FAST_SECS}s check cadence armed for $(armed_channels)${legacy_note}; it applies to the NEXT supervision cycle, not one already running - $(supervision_repair)"
    else
      echo "CADENCE: failed to arm the ${FAST_SECS}s check cadence; captain messages stay on the 300s cadence"
      rc=1
    fi
    return "$rc"
  fi

  if fmx_generated_present "$CADENCE_FILE"; then
    if fmx_generated_remove "$CADENCE_FILE"; then
      echo "CADENCE: default 300s check cadence restored - no inbound captain channel is armed; it applies to the NEXT supervision cycle, not one already running - $(supervision_repair)"
    else
      echo "CADENCE: failed to remove the ${FAST_SECS}s check cadence; the next supervision cycle keeps polling fast"
      rc=1
    fi
  elif [ -n "$legacy_note" ]; then
    echo "CADENCE: removed the superseded config/x-mode.env; no inbound captain channel is armed, so the default 300s check cadence applies to the next supervision cycle"
  fi
  return "$rc"
}

cmd_status() {
  local names
  names=$(armed_channels)
  if fmx_generated_present "$CADENCE_FILE"; then
    printf 'fast %s\n' "$CADENCE_FILE"
  else
    printf 'default\n'
  fi
  if [ -n "$names" ]; then
    printf 'armed: %s\n' "$names"
  else
    printf 'armed: none\n'
  fi
}

# `path` is on the hot path of every guard, turn-end hook, and session-start
# render, so it stays a bare constant lookup; only the mutating and reporting
# commands pay for the libraries below.
#   fm-x-lib.sh          - shared generated-artifact primitives (single-link,
#                          single-device, mode-verified atomic write). They live
#                          there because X mode was the first generated watcher
#                          artifact; they are mode-neutral and carry no X behavior.
#   fm-supervision-lib.sh - the armed-inbound-channel predicate.
case "${1-}" in
  reconcile|status)
    # shellcheck source=bin/fm-x-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-x-lib.sh"
    # shellcheck source=bin/fm-supervision-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-supervision-lib.sh"
    ;;
esac

case "${1-}" in
  reconcile) cmd_reconcile ;;
  path)      printf '%s\n' "$CADENCE_FILE" ;;
  status)    cmd_status ;;
  -h|--help)
    sed -n '2,/^set -u$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "usage: fm-cadence.sh reconcile|path|status" >&2
    exit 2
    ;;
esac
