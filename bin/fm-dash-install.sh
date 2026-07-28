#!/usr/bin/env bash
# fm-dash-install.sh - persistent tailnet-only publication of the capacity dashboard.
#
# Single owner of dashboard-service persistence: the launchd agent that keeps
# bin/fm-dash-serve.mjs running across reboots, the tailscale serve proxy that
# exposes it tailnet-only at one stable HTTPS URL, config/dash.json, and the
# registered fm-dash watcher check that lets clicked commands wake firstmate.
# It never enables Funnel: the serve mapping is tailnet-only by construction and
# install verifies Funnel is off for the served port, tearing the mapping back
# down and refusing if any Funnel exposure is detected.
#
# Usage: fm-dash-install.sh <command> [options]
#   install       write config, launchd agent, tailscale serve mapping, and the
#                 fm-dash watcher check; idempotent, prints the stable URL
#   uninstall     remove the serve mapping and launchd agent; keeps config and
#                 any pending commands in state/dash-inbox/
#   status        report agent, serve mapping, and pending-command state
#   print-plist   print the launchd plist to stdout without installing
#   write-check   write and register only the fm-dash watcher check
# Options:
#   --port <n>        local loopback port for the service (default 8847)
#   --serve-port <n>  tailnet HTTPS port for tailscale serve (default 8443)
#   --captain <login> authorized tailnet login; repeatable; defaults to the
#                     tailnet self login reported by tailscale status
#   --read-only       serve the dashboard without command dispatch and skip the
#                     watcher check; for running the service ahead of command wiring
# FM_HOME selects the home; scripts and the service always run from this
# checkout. docs/dashboard-service.md owns the architecture and evidence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="$FM_HOME/config"
CONFIG="$CONFIG_DIR/dash.json"
CHECK="$STATE/fm-dash.check.sh"
DEFAULT_PORT=8847
DEFAULT_SERVE_PORT=8443

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,29p'
  exit "${1:-0}"
}

err() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

home_label() {
  local hash
  hash=$(printf '%s' "$FM_HOME" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print substr($1,1,8)}')
  printf 'io.firstmate.dashboard.%s' "$hash"
}

node_bin() {
  command -v node || err "node is required"
}

tailscale_bin() {
  command -v tailscale || err "the tailscale CLI is required"
}

tailscale_self_json() {
  "$(tailscale_bin)" status --json 2>/dev/null
}

tailscale_self_login() {
  tailscale_self_json | node -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      try {
        const s = JSON.parse(raw);
        const user = s.User && s.Self ? s.User[s.Self.UserID] : null;
        if (user && user.LoginName) { console.log(user.LoginName); return; }
      } catch {}
      process.exit(1);
    });
  '
}

tailscale_self_dnsname() {
  tailscale_self_json | node -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      try {
        const s = JSON.parse(raw);
        if (s.Self && s.Self.DNSName) { console.log(s.Self.DNSName.replace(/\.$/, "")); return; }
      } catch {}
      process.exit(1);
    });
  '
}

# Refuse loudly if any Funnel exposure exists for the served port. Funnel is
# never acceptable for this service.
assert_no_funnel() {
  local serve_port=$1 status_json
  status_json=$("$(tailscale_bin)" serve status --json 2>/dev/null) || {
    echo "could not verify Funnel state: tailscale serve status failed" >&2
    return 1
  }
  printf '%s' "$status_json" | node -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      try {
        const s = JSON.parse(raw);
        if (!s || Array.isArray(s) || typeof s !== "object"
          || !s.TCP || Array.isArray(s.TCP) || typeof s.TCP !== "object"
          || !s.Web || Array.isArray(s.Web) || typeof s.Web !== "object"
          || !s.TCP[process.argv[1]] || s.TCP[process.argv[1]].HTTPS !== true
          || !Object.keys(s.Web).some((hostport) => hostport.endsWith(":" + process.argv[1]))) {
          throw new Error("unsupported tailscale serve status schema");
        }
        if (s.AllowFunnel !== undefined && (!s.AllowFunnel || Array.isArray(s.AllowFunnel) || typeof s.AllowFunnel !== "object")) {
          throw new Error("unsupported AllowFunnel schema");
        }
        const allow = s.AllowFunnel || {};
        for (const [hostport, enabled] of Object.entries(allow)) {
          if (typeof enabled !== "boolean") throw new Error("unsupported AllowFunnel value");
          if (enabled && hostport.endsWith(":" + process.argv[1])) {
            console.error("funnel is enabled for " + hostport);
            process.exit(1);
          }
        }
      } catch (error) {
        console.error("could not verify Funnel state: " + error.message);
        process.exit(1);
      }
    });
  ' "$serve_port"
}

write_config() {
  local port=$1 read_only=$2
  shift 2
  mkdir -p "$CONFIG_DIR"
  node -e '
    const fs = require("node:fs");
    const [config, port, readOnly, ...logins] = process.argv.slice(1);
    const payload = { port: Number(port), captain_logins: logins, read_only: readOnly === "true" };
    fs.writeFileSync(config, JSON.stringify(payload, null, 2) + "\n", { mode: 0o600 });
  ' "$CONFIG" "$port" "$read_only" "$@" || err "could not write $CONFIG"
  chmod 600 "$CONFIG" 2>/dev/null || true
}

render_plist() {
  local label node_path log_dir fm_root fm_home
  label=$(xml_escape "$1")
  node_path=$(xml_escape "$2")
  log_dir=$(xml_escape "$3")
  fm_root=$(xml_escape "$FM_ROOT")
  fm_home=$(xml_escape "$FM_HOME")
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$node_path</string>
    <string>$fm_root/bin/fm-dash-serve.mjs</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key><string>$fm_home</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$log_dir/dash-serve.log</string>
  <key>StandardErrorPath</key><string>$log_dir/dash-serve.log</string>
</dict>
</plist>
PLIST
}

xml_escape() {
  node -e 'process.stdout.write(process.argv[1].replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll("\"", "&quot;").replaceAll("\x27", "&apos;"))' "$1"
}

write_check() {
  mkdir -p "$STATE"
  cat > "$CHECK" <<'SHIM'
#!/bin/sh
# fm-dash watcher check - wakes firstmate when captain dashboard commands are
# pending in state/dash-inbox/. Written and registered by bin/fm-dash-install.sh.
state_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
inbox="$state_dir/dash-inbox"
[ -d "$inbox" ] || exit 0
count=0
for f in "$inbox"/*.json; do
  [ -e "$f" ] || continue
  count=$((count + 1))
done
[ "$count" -gt 0 ] || exit 0
printf 'dashboard: %s captain command(s) pending - run bin/fm-dash-inbox.sh claim and handle them under the capacity skill\n' "$count"
SHIM
  chmod 700 "$CHECK"
  "$SCRIPT_DIR/fm-check-register.sh" fm-dash || err "could not register the fm-dash watcher check"
}

cmd_install() {
  local port=$DEFAULT_PORT serve_port=$DEFAULT_SERVE_PORT read_only=false captains=() label plist_path node_path dnsname
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port=${2:?--port needs a value}; shift 2 ;;
      --serve-port) serve_port=${2:?--serve-port needs a value}; shift 2 ;;
      --captain) captains+=("${2:?--captain needs a value}"); shift 2 ;;
      --read-only) read_only=true; shift ;;
      *) err "unknown install option: $1" ;;
    esac
  done
  [ "$(uname)" = Darwin ] || err "install requires macOS launchd; on another OS run bin/fm-dash-serve.mjs under your init system and proxy it with tailscale serve (never funnel)"
  command -v launchctl >/dev/null 2>&1 || err "launchctl is required"
  node_path=$(node_bin)
  tailscale_bin >/dev/null

  if [ "${#captains[@]}" -eq 0 ]; then
    local self_login
    self_login=$(tailscale_self_login) || err "could not resolve the tailnet self login; pass --captain <login>"
    captains=("$self_login")
  fi

  write_config "$port" "$read_only" "${captains[@]}"
  # A read-only install serves the dashboard without command dispatch, so the
  # watcher check that surfaces clicked commands is not registered.
  [ "$read_only" = true ] || write_check

  label=$(home_label)
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$STATE"
  render_plist "$label" "$node_path" "$STATE" > "$plist_path"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist_path" || err "launchctl bootstrap failed for $plist_path"
  # RunAtLoad does not reliably start a re-bootstrapped agent on every macOS;
  # kickstart makes install-serves-now deterministic.
  launchctl kickstart "gui/$(id -u)/$label" 2>/dev/null || true

  # Tailnet-only HTTPS proxy. tailscale serve without funnel is tailnet-only by
  # construction; the assertion below still verifies no Funnel exposure exists
  # for this port and tears the mapping down if one is found.
  "$(tailscale_bin)" serve --bg --https="$serve_port" "http://127.0.0.1:$port" >/dev/null \
    || err "tailscale serve refused the mapping; is tailscale up?"
  if ! assert_no_funnel "$serve_port"; then
    "$(tailscale_bin)" serve --https="$serve_port" off >/dev/null 2>&1 || true
    err "could not verify tailnet-only exposure for port $serve_port; the mapping was removed - this service must stay tailnet-only"
  fi

  dnsname=$(tailscale_self_dnsname) || err "could not resolve this machine's tailnet name"
  printf 'installed: launchd agent %s\n' "$label"
  printf 'captains: %s\n' "${captains[*]}"
  printf 'dashboard: https://%s:%s/\n' "$dnsname" "$serve_port"
}

cmd_uninstall() {
  local serve_port=$DEFAULT_SERVE_PORT label plist_path
  while [ $# -gt 0 ]; do
    case "$1" in
      --serve-port) serve_port=${2:?--serve-port needs a value}; shift 2 ;;
      *) err "unknown uninstall option: $1" ;;
    esac
  done
  [ "$(uname)" = Darwin ] || err "uninstall requires macOS launchd"
  label=$(home_label)
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  if command -v tailscale >/dev/null 2>&1; then
    tailscale serve --https="$serve_port" off >/dev/null 2>&1 || true
  fi
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist_path"
  printf 'uninstalled: %s (config and any pending commands were kept)\n' "$label"
}

cmd_status() {
  local label pending
  label=$(home_label)
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    printf 'agent: %s loaded\n' "$label"
  else
    printf 'agent: %s not loaded\n' "$label"
  fi
  if command -v tailscale >/dev/null 2>&1; then
    tailscale serve status 2>/dev/null | sed 's/^/serve: /' || true
  fi
  pending=$("$SCRIPT_DIR/fm-dash-inbox.sh" pending-count 2>/dev/null || echo unknown)
  printf 'pending commands: %s\n' "$pending"
}

case "${1:-}" in
  -h|--help|'') usage 0 ;;
  install) shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  status) shift; cmd_status ;;
  print-plist) shift; render_plist "$(home_label)" "$(node_bin)" "$STATE" ;;
  write-check) shift; write_check ;;
  *) usage 2 >&2 ;;
esac
