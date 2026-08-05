#!/usr/bin/env bash
# fm-dash-install.sh - persistent tailnet-only publication of the capacity dashboard.
#
# Single owner of dashboard-service persistence: the launchd agent that keeps
# bin/fm-dash-serve.mjs running across reboots, the tailscale serve proxy that
# exposes it tailnet-only at one stable HTTPS URL, config/dash.json, and the
# registered fm-dash watcher check that lets captain commands and chat messages
# wake firstmate.
# It never enables Funnel: the serve mapping is tailnet-only by construction and
# install verifies Funnel is off for the served port, tearing the mapping back
# down and refusing if any Funnel exposure is detected.
#
# Usage: fm-dash-install.sh <command> [options]
#   install       write config, launchd agent, tailscale serve mapping, and the
#                 fm-dash watcher check; idempotent, prints the stable URL
#   uninstall     remove the serve mapping, launchd agent, and watcher registration;
#                 keeps config and durable dashboard records
#   status        report agent, serve mapping, and pending-command state
#   print-plist   print the launchd plist to stdout without installing
#   write-check   write and register only the fm-dash watcher check
#   unregister-check  remove only the fm-dash watcher registration
# Options:
#   --port <n>        local loopback port for the service (default 8847)
#   --serve-port <n>  tailnet HTTPS port for tailscale serve (default 8443)
#   --captain <login> authorized tailnet login; repeatable; defaults to the
#                     tailnet self login reported by tailscale status
#   --read-only       serve the dashboard without inbound command, chat, or merge
#                     writes and remove the watcher check
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
CHECK_TRUST="$STATE/fm-dash.check-trust"
DEFAULT_PORT=8847
DEFAULT_SERVE_PORT=8443
TX_ACTIVE=false
TX_CONFIG_BACKUP=""
TX_CONFIG_EXISTED=false
TX_PLIST_BACKUP=""
TX_PLIST_EXISTED=false
TX_CHECK_BACKUP=""
TX_CHECK_EXISTED=false
TX_TRUST_BACKUP=""
TX_TRUST_EXISTED=false
TX_CONFIG_STAGE=""
TX_PLIST_STAGE=""
TX_PRIOR_LOADED=false
TX_PREVIOUS_SERVE_PORT=""
TX_PREVIOUS_MAPPING_PRESENT=false
TX_PREVIOUS_MAPPING_TARGET=""
TX_NEW_SERVE_PORT=""
TX_NEW_MAPPING=false
TX_LABEL=""
TX_PLIST_PATH=""

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

write_config_file() {
  local target=$1 port=$2 serve_port=$3 read_only=$4
  shift 4
  node -e '
    const fs = require("node:fs");
    const [config, port, servePort, readOnly, ...logins] = process.argv.slice(1);
    const payload = { port: Number(port), serve_port: Number(servePort), captain_logins: logins, read_only: readOnly === "true" };
    fs.writeFileSync(config, JSON.stringify(payload, null, 2) + "\n", { mode: 0o600 });
    const verified = JSON.parse(fs.readFileSync(config, "utf8"));
    if (verified.port !== Number(port) || verified.serve_port !== Number(servePort)) process.exit(1);
  ' "$target" "$port" "$serve_port" "$read_only" "$@" || return 1
  chmod 600 "$target" 2>/dev/null || true
}

configured_serve_port() {
  [ -f "$CONFIG" ] || return 0
  node -e '
    const fs = require("node:fs");
    try {
      const parsed = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const port = parsed.serve_port === undefined ? Number(process.argv[2]) : parsed.serve_port;
      if (!Number.isInteger(port) || port < 1 || port > 65535) process.exit(1);
      console.log(port);
    } catch {
      process.exit(1);
    }
  ' "$CONFIG" "$DEFAULT_SERVE_PORT"
}

configured_mapping_target() {
  [ -f "$CONFIG" ] || return 0
  node -e '
    const fs = require("node:fs");
    try {
      const parsed = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const port = parsed.port === undefined ? Number(process.argv[2]) : parsed.port;
      if (!Number.isInteger(port) || port < 1 || port > 65535) process.exit(1);
      console.log("http://127.0.0.1:" + port);
    } catch {
      process.exit(1);
    }
  ' "$CONFIG" "$DEFAULT_PORT"
}

snapshot_serve_mapping() {
  local serve_port=$1 status_json
  status_json=$("$(tailscale_bin)" serve status --json 2>/dev/null) || return 1
  printf '%s' "$status_json" | node -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      try {
        const s = JSON.parse(raw);
        if (!s || Array.isArray(s) || typeof s !== "object") throw new Error();
        const tcp = s.TCP === undefined ? {} : s.TCP;
        const web = s.Web === undefined ? {} : s.Web;
        if (!tcp || Array.isArray(tcp) || typeof tcp !== "object"
          || !web || Array.isArray(web) || typeof web !== "object") throw new Error();
        const tcpMapping = tcp[process.argv[1]];
        const webMappings = Object.entries(web).filter(([hostport]) => hostport.endsWith(":" + process.argv[1]));
        if (tcpMapping === undefined && webMappings.length === 0) return;
        if (!tcpMapping || tcpMapping.HTTPS !== true || webMappings.length !== 1) {
          console.log("foreign");
          return;
        }
        const handlers = webMappings[0][1] && webMappings[0][1].Handlers;
        if (!handlers || Array.isArray(handlers) || typeof handlers !== "object") {
          console.log("foreign");
          return;
        }
        const paths = Object.keys(handlers);
        const proxy = handlers["/"] && handlers["/"].Proxy;
        if (paths.length !== 1 || paths[0] !== "/" || typeof proxy !== "string" || proxy.length === 0) {
          console.log("foreign");
          return;
        }
        console.log(proxy);
      } catch {
        process.exit(1);
      }
    });
  ' "$serve_port"
}

disable_serve_port() {
  "$(tailscale_bin)" serve --https="$1" off >/dev/null 2>&1
}

disable_owned_serve_port() {
  local serve_port=$1 expected_target=$2 live_target
  live_target=$(snapshot_serve_mapping "$serve_port") || return 1
  [ -n "$live_target" ] || return 0
  if [ -z "$expected_target" ] || [ "$live_target" != "$expected_target" ]; then
    printf 'kept: serve port %s carries a non-dashboard mapping\n' "$serve_port"
    return 0
  fi
  disable_serve_port "$serve_port"
}

cleanup_install_transaction() {
  local file
  for file in "$TX_CONFIG_BACKUP" "$TX_PLIST_BACKUP" "$TX_CHECK_BACKUP" "$TX_TRUST_BACKUP" "$TX_CONFIG_STAGE" "$TX_PLIST_STAGE"; do
    [ -z "$file" ] || rm -f -- "$file"
  done
}

fail_staging() {
  local message=$1
  cleanup_install_transaction
  err "$message"
}

restore_snapshot() {
  local path=$1 backup=$2 existed=$3
  if [ "$existed" = true ]; then
    mv -f -- "$backup" "$path"
  else
    rm -f -- "$path"
  fi
}

rollback_install() {
  local status=0
  TX_ACTIVE=false
  if [ "$TX_NEW_MAPPING" = true ]; then
    disable_serve_port "$TX_NEW_SERVE_PORT" || status=1
  fi
  restore_snapshot "$CONFIG" "$TX_CONFIG_BACKUP" "$TX_CONFIG_EXISTED" || status=1
  restore_snapshot "$TX_PLIST_PATH" "$TX_PLIST_BACKUP" "$TX_PLIST_EXISTED" || status=1
  restore_snapshot "$CHECK" "$TX_CHECK_BACKUP" "$TX_CHECK_EXISTED" || status=1
  restore_snapshot "$CHECK_TRUST" "$TX_TRUST_BACKUP" "$TX_TRUST_EXISTED" || status=1
  launchctl bootout "gui/$(id -u)/$TX_LABEL" >/dev/null 2>&1 || true
  if [ "$TX_PRIOR_LOADED" = true ]; then
    launchctl bootstrap "gui/$(id -u)" "$TX_PLIST_PATH" >/dev/null 2>&1 || status=1
    launchctl kickstart "gui/$(id -u)/$TX_LABEL" >/dev/null 2>&1 || status=1
  fi
  if [ "$TX_PREVIOUS_MAPPING_PRESENT" = true ]; then
    "$(tailscale_bin)" serve --bg --https="$TX_PREVIOUS_SERVE_PORT" "$TX_PREVIOUS_MAPPING_TARGET" >/dev/null 2>&1 || status=1
    assert_no_funnel "$TX_PREVIOUS_SERVE_PORT" >/dev/null 2>&1 || status=1
  fi
  cleanup_install_transaction
  return "$status"
}

fail_install() {
  local message=$1
  if rollback_install; then
    err "$message; the previous dashboard installation was restored"
  fi
  err "$message; rollback was incomplete and requires manual inspection"
}

snapshot_file() {
  local path=$1 template=$2 backup_var=$3 existed_var=$4 backup
  if [ -e "$path" ]; then
    backup=$(mktemp "$template") || return 1
    printf -v "$backup_var" '%s' "$backup"
    cp -p -- "$path" "$backup" || return 1
    printf -v "$existed_var" '%s' true
  fi
}

render_plist() {
  local label node_path log_dir fm_root fm_home path_env
  label=$(xml_escape "$1")
  node_path=$(xml_escape "$2")
  log_dir=$(xml_escape "$3")
  fm_root=$(xml_escape "$FM_ROOT")
  fm_home=$(xml_escape "$FM_HOME")
  # launchd starts agents with a minimal PATH that cannot resolve the state
  # reader tools (tmux, no-mistakes, tasks-axi, gh), which silently degrades
  # every rendered state to unknown. Capture the installing shell's full PATH
  # so the service and the generator it runs see the same tools the captain's
  # interactive runs do.
  path_env=$(xml_escape "$PATH")
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
    <key>PATH</key><string>$path_env</string>
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
# pending in state/dash-inbox/ or captain chat messages are pending in
# state/dash-chat/messages/. Written and registered by bin/fm-dash-install.sh.
state_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
inbox="$state_dir/dash-inbox"
chat="$state_dir/dash-chat/messages"
count=0
if [ -d "$inbox" ]; then
  for f in "$inbox"/*.json; do
    [ -e "$f" ] || continue
    count=$((count + 1))
  done
fi
chat_count=0
if [ -d "$chat" ]; then
  for f in "$chat"/*.json; do
    [ -e "$f" ] || continue
    chat_count=$((chat_count + 1))
  done
fi
[ "$count" -gt 0 ] || [ "$chat_count" -gt 0 ] || exit 0
printf 'dashboard: %s captain command(s) and %s chat message(s) pending - run bin/fm-dash-inbox.sh claim and bin/fm-dash-chat.sh claim and handle them under the capacity skill\n' "$count" "$chat_count"
SHIM
  chmod 700 "$CHECK"
  "$SCRIPT_DIR/fm-check-register.sh" fm-dash || err "could not register the fm-dash watcher check"
}

unregister_check() {
  rm -f -- "$CHECK" "$CHECK_TRUST" || err "could not unregister the fm-dash watcher check"
}

cmd_install() {
  local port=$DEFAULT_PORT serve_port=$DEFAULT_SERVE_PORT previous_serve_port previous_mapping_target requested_mapping_target expected_mapping_target read_only=false captains=() label plist_path node_path dnsname
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
  previous_serve_port=$(configured_serve_port) || err "could not read the previously configured dashboard serve port"
  expected_mapping_target=$(configured_mapping_target) || err "could not read the previously configured dashboard mapping target"
  if [ -n "$previous_serve_port" ]; then
    previous_mapping_target=$(snapshot_serve_mapping "$previous_serve_port") || err "could not inspect the previously configured dashboard serve port"
    if [ -n "$previous_mapping_target" ] && [ "$previous_mapping_target" != "$expected_mapping_target" ]; then
      err "configured dashboard serve port $previous_serve_port carries a non-dashboard mapping; refusing to replace it"
    fi
    TX_PREVIOUS_MAPPING_TARGET=$previous_mapping_target
    [ -z "$previous_mapping_target" ] || TX_PREVIOUS_MAPPING_PRESENT=true
  fi
  if [ "$serve_port" = "$previous_serve_port" ]; then
    requested_mapping_target=$previous_mapping_target
  else
    requested_mapping_target=$(snapshot_serve_mapping "$serve_port") || err "could not inspect requested dashboard serve port $serve_port"
  fi
  if [ -n "$requested_mapping_target" ] && { [ "$serve_port" != "$previous_serve_port" ] || [ "$requested_mapping_target" != "$expected_mapping_target" ]; }; then
    err "requested dashboard serve port $serve_port carries a non-dashboard mapping; choose another --serve-port"
  fi

  if [ "${#captains[@]}" -eq 0 ]; then
    local self_login
    self_login=$(tailscale_self_login) || err "could not resolve the tailnet self login; pass --captain <login>"
    captains=("$self_login")
  fi

  label=$(home_label)
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$CONFIG_DIR" "$HOME/Library/LaunchAgents" "$STATE"
  TX_LABEL=$label
  TX_PLIST_PATH=$plist_path
  TX_PREVIOUS_SERVE_PORT=$previous_serve_port
  TX_NEW_SERVE_PORT=$serve_port
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && TX_PRIOR_LOADED=true
  snapshot_file "$CONFIG" "$CONFIG_DIR/.dash.json.backup.XXXXXX" TX_CONFIG_BACKUP TX_CONFIG_EXISTED || fail_staging "could not snapshot $CONFIG"
  snapshot_file "$plist_path" "$HOME/Library/LaunchAgents/.$label.backup.XXXXXX" TX_PLIST_BACKUP TX_PLIST_EXISTED || fail_staging "could not snapshot $plist_path"
  snapshot_file "$CHECK" "$STATE/.fm-dash.check.backup.XXXXXX" TX_CHECK_BACKUP TX_CHECK_EXISTED || fail_staging "could not snapshot $CHECK"
  snapshot_file "$CHECK_TRUST" "$STATE/.fm-dash.check-trust.backup.XXXXXX" TX_TRUST_BACKUP TX_TRUST_EXISTED || fail_staging "could not snapshot $CHECK_TRUST"
  TX_CONFIG_STAGE=$(mktemp "$CONFIG_DIR/.dash.json.stage.XXXXXX") || fail_staging "could not stage $CONFIG"
  TX_PLIST_STAGE=$(mktemp "$HOME/Library/LaunchAgents/.$label.stage.XXXXXX") || fail_staging "could not stage $plist_path"
  write_config_file "$TX_CONFIG_STAGE" "$port" "$serve_port" "$read_only" "${captains[@]}" || fail_staging "could not stage $CONFIG"
  render_plist "$label" "$node_path" "$STATE" > "$TX_PLIST_STAGE" || fail_staging "could not stage $plist_path"
  TX_ACTIVE=true
  trap '[ "$TX_ACTIVE" != true ] || rollback_install' EXIT
  mv -f -- "$TX_CONFIG_STAGE" "$CONFIG" || fail_install "could not activate $CONFIG"
  TX_CONFIG_STAGE=""
  mv -f -- "$TX_PLIST_STAGE" "$plist_path" || fail_install "could not activate $plist_path"
  TX_PLIST_STAGE=""
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist_path" || fail_install "launchctl bootstrap failed for $plist_path"
  # RunAtLoad does not reliably start a re-bootstrapped agent on every macOS;
  # kickstart makes install-serves-now deterministic.
  launchctl kickstart "gui/$(id -u)/$label" >/dev/null 2>&1 || fail_install "launchctl kickstart failed for $label"

  # Tailnet-only HTTPS proxy. tailscale serve without funnel is tailnet-only by
  # construction; the assertion below still verifies no Funnel exposure exists
  # for this port and tears the mapping down if one is found.
  "$(tailscale_bin)" serve --bg --https="$serve_port" "http://127.0.0.1:$port" >/dev/null \
    || fail_install "tailscale serve refused the replacement mapping"
  TX_NEW_MAPPING=true
  if ! assert_no_funnel "$serve_port"; then
    fail_install "could not verify tailnet-only exposure for port $serve_port"
  fi
  if [ -n "$previous_serve_port" ] && [ "$previous_serve_port" != "$serve_port" ]; then
    if ! disable_serve_port "$previous_serve_port"; then
      fail_install "could not remove the previous dashboard mapping for port $previous_serve_port"
    fi
  fi
  if [ "$read_only" = true ]; then
    unregister_check
  else
    write_check
  fi
  dnsname=$(tailscale_self_dnsname) || fail_install "could not resolve this machine's tailnet name"
  TX_ACTIVE=false
  cleanup_install_transaction
  trap - EXIT

  printf 'installed: launchd agent %s\n' "$label"
  printf 'captains: %s\n' "${captains[*]}"
  printf 'dashboard: https://%s:%s/\n' "$dnsname" "$serve_port"
}

cmd_uninstall() {
  local serve_port="" configured_port configured_target label plist_path
  while [ $# -gt 0 ]; do
    case "$1" in
      --serve-port) serve_port=${2:?--serve-port needs a value}; shift 2 ;;
      *) err "unknown uninstall option: $1" ;;
    esac
  done
  [ "$(uname)" = Darwin ] || err "uninstall requires macOS launchd"
  configured_port=$(configured_serve_port) || err "could not read the configured dashboard serve port"
  configured_target=$(configured_mapping_target) || err "could not read the configured dashboard mapping target"
  [ -n "$serve_port" ] || serve_port=${configured_port:-$DEFAULT_SERVE_PORT}
  label=$(home_label)
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  if command -v tailscale >/dev/null 2>&1; then
    disable_owned_serve_port "$serve_port" "$configured_target" || err "could not inspect or remove the dashboard mapping for port $serve_port"
    if [ -n "$configured_port" ] && [ "$configured_port" != "$serve_port" ]; then
      disable_owned_serve_port "$configured_port" "$configured_target" || err "could not inspect or remove the configured dashboard mapping for port $configured_port"
    fi
  fi
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist_path"
  unregister_check
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
  unregister-check) shift; unregister_check ;;
  *) usage 2 >&2 ;;
esac
