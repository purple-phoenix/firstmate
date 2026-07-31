#!/usr/bin/env bash
# Behavior and contract tests for the persistent tailnet-only dashboard service:
# bin/fm-dash-serve.mjs, bin/fm-dash-inbox.sh, and bin/fm-dash-install.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVE="$ROOT/bin/fm-dash-serve.mjs"
INBOX_SH="$ROOT/bin/fm-dash-inbox.sh"
INSTALL_SH="$ROOT/bin/fm-dash-install.sh"
CAPACITY="$ROOT/bin/fm-capacity.mjs"
TMP_ROOT=$(fm_test_tmproot fm-dash)
QUOTA_STUB="$TMP_ROOT/quota-axi"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

CAPTAIN="captain@example.com"
SERVER_PID=""

cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

make_fixture() {
  local home=$1 snapshot=$2 environment=$3
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$snapshot" <<EOF
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-07-28T10:00:00Z",
  "fm_home": "$home",
  "roots": {"fm_root":"$ROOT","state":"$home/state","data":"$home/data","config":"$home/config","projects":"$home/projects"},
  "backlog": {
    "path": "$home/data/backlog.md",
    "present": true,
    "records": [
      {"order":0,"state":"in_flight","structured":true,"id":"active-task","title":"Run the active rollout","repo":"alpha","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: rollout remains observable."},
      {"order":1,"state":"queued","structured":true,"id":"ready-safe","title":"Ship the gamma feature","repo":"gamma","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: bounded regression tests pass."},
      {"order":2,"state":"queued","structured":true,"id":"captain-choice","title":"Choose the rollout policy","repo":"alpha","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"pick conservative or fast rollout","body_excerpt":"Origin: active-task\nDecision key: rollout-policy\nState: awaiting captain decision."},
      {"order":3,"state":"queued","structured":true,"id":"captain-choice-two","title":"Choose the secondary rollout policy","repo":"alpha","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"pick a secondary rollout","body_excerpt":"Origin: secondary-task\nDecision key: rollout-policy\nState: awaiting captain decision."},
      {"order":4,"state":"queued","structured":true,"id":"blocked-child","title":"Ship after rollout choice","repo":"alpha","project_resolved":true,"kind":"ship","blocked_by":"captain-choice","body_excerpt":"Acceptance criteria: follows the selected rollout."}
    ]
  },
  "tasks": [
    {"id":"active-task","kind":"ship","project":"alpha","current_state":{"state":"working","source":"pane","detail":"running rollout"},"endpoint":{"exists":true},"hints":{"open_decisions":[{"key":"runtime-policy"}]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"active-task","title":"Run the active rollout","repo":"alpha","project_resolved":true,"kind":"ship"}}
  ],
  "scout_reports": [],
  "secondmate_current": {"registry":{"available":true,"complete":true,"records":[]},"records":[],"total":0,"shown":0,"truncated":0},
  "secondmate_landed": {"records":[],"truncated":[],"unreadable":[]}
}
EOF
  cat > "$environment" <<'EOF'
{
  "backend": {"name":"tmux","available":true,"evidence":"required runtime tools present","owner":"fixture"},
  "github_auth": {"status":"available","evidence":"authenticated","owner":"fixture"},
  "dispatch": {"config_present":true,"valid":true,"reason":null,"lanes":[
    {"harness":"codex","model":"gpt-test","effort":"high","when":"default","available":true,"availability_evidence":"executable present","quota":"not observed - capacity never guesses quota"}
  ]},
  "secondmates": {}
}
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-task - Run the active rollout (repo: alpha) (kind: ship)
  Acceptance criteria: rollout remains observable.

## Queued
- [ ] ready-safe - Ship the gamma feature (repo: gamma) (kind: ship)
  Acceptance criteria: bounded regression tests pass.
- [ ] captain-choice - Choose the rollout policy (repo: alpha) (kind: captain)
  Pick the alpha rollout pace before dependent work starts.
  - Conservative rollout: slower, safest for existing users
  - Fast rollout: reaches everyone this week, higher regression risk
- [ ] captain-choice-two - Choose the secondary rollout policy (repo: alpha) (kind: captain)
  Pick the secondary rollout pace independently.
- [ ] blocked-child - Ship after rollout choice (repo: alpha) (kind: ship) (blocked-by: captain-choice)
  Acceptance criteria: follows the selected rollout.

## Done
EOF
  mkdir -p "$home/data/ready-safe" "$home/data/ideas/pitches" "$home/data/active-task/decisions" "$home/data/secondary-task/decisions"
  cat > "$home/data/ready-safe/brief.md" <<'EOF'
# Task
Ship the gamma feature so gamma users get streaming exports.

Acceptance criteria:
bounded regression tests pass and the export path stays backward compatible.

# Setup
Standard worktree setup.
EOF
  printf 'pr=https://github.com/purple-phoenix/firstmate/pull/999\nproject=%s/projects/gamma\nmode=no-mistakes\n' "$home" > "$home/state/ready-safe.meta"
  printf 'working: preview at https://demo.tailebcf61.ts.net:5300/\n' > "$home/state/ready-safe.status"
  cat > "$home/data/ideas/idea-backlog.md" <<'EOF'
# Idea backlog

## IDEA-01 - Faster onboarding
New crew homes should self-provision in one command.

## IDEA-02 - Nightly digest
Send the captain a nightly fleet digest.
EOF
  printf '# Faster onboarding pitch\n\nOne command provisions a ready home.\n' > "$home/data/ideas/pitches/IDEA-01.md"
  cat > "$home/data/active-task/decisions/rollout-policy.md" <<'EOF'
# Choose the rollout policy

Pick the alpha rollout pace before dependent work starts.

## Options

- [recommended] Conservative rollout - Slower delivery with the lowest regression risk.
- Fast rollout - Reaches everyone this week with higher regression risk.
EOF
  cat > "$home/data/active-task/decisions/runtime-policy.md" <<'EOF'
# Choose the runtime policy

Choose how the active rollout should continue.

## Options

- [recommended] Conservative rollout - Slower delivery with the lowest regression risk.
- Fast rollout - Reaches everyone this week with higher regression risk.
EOF
  cat > "$home/data/secondary-task/decisions/rollout-policy.md" <<'EOF'
# Choose the secondary rollout policy

Choose the independent secondary rollout pace.

## Options

- [recommended] Staged secondary rollout - Keeps secondary users isolated during validation.
- Immediate secondary rollout - Moves faster with broader secondary exposure.
EOF
}

write_config() {
  local home=$1 port=$2
  cat > "$home/config/dash.json" <<EOF
{"port": $port, "captain_logins": ["$CAPTAIN"]}
EOF
}

pick_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});'
}

start_server() {
  local home=$1 port=$2 fixture_args=${3:-}
  FM_HOME="$home" FM_DASH_CAPACITY_ARGS="$fixture_args" FM_DASH_QUOTA_AXI="$QUOTA_STUB" node "$SERVE" --port "$port" > "$TMP_ROOT/serve.log" 2>&1 &
  SERVER_PID=$!
  local tries=0
  while ! curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "dashboard service did not start (see $TMP_ROOT/serve.log)"
    sleep 0.1
  done
}

stop_server() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

REQ_STATUS=""
RESP=""
req() {
  # req <method> <url> [login] [body] -> sets REQ_STATUS and RESP
  local method=$1 url=$2 login=${3:-} body=${4:-}
  local args=(-s -o "$TMP_ROOT/resp.body" -w '%{http_code}' -X "$method")
  [ -z "$login" ] || args+=(-H "Tailscale-User-Login: $login")
  [ -z "$body" ] || args+=(-H "content-type: application/json" -d "$body")
  REQ_STATUS=$(curl "${args[@]}" "$url")
  RESP=$(cat "$TMP_ROOT/resp.body")
}

HOME_DIR="$TMP_ROOT/home"
SNAPSHOT="$TMP_ROOT/snapshot.json"
ENVIRONMENT="$TMP_ROOT/environment.json"
make_fixture "$HOME_DIR" "$SNAPSHOT" "$ENVIRONMENT"
cat > "$QUOTA_STUB" <<'EOF'
#!/bin/sh
printf '%s\n' '{"schemaVersion":2,"providers":[{"provider":"claude","label":"Claude","windows":[{"label":"session","percentUsed":42,"resetsAt":"2026-07-29T10:00:00Z"}]},{"provider":"codex","label":"Codex","windows":[{"label":"week","percentUsed":61,"resetsAt":"2026-08-01T10:00:00Z"}]},{"provider":"grok","label":"Grok","windows":[{"label":"credits","percentUsed":7,"resetsAt":"2026-07-30T10:00:00Z"}]},{"provider":"cursor","label":"Cursor","windows":[{"label":"month","percentUsed":99,"resetsAt":"2026-08-28T10:00:00Z"}]}]}'
EOF
chmod 700 "$QUOTA_STUB"
FM_HOME="$HOME_DIR" "$CAPACITY" --snapshot "$SNAPSHOT" --environment "$ENVIRONMENT" \
  --output "$HOME_DIR/data/capacity-dashboard.html" --refs "$HOME_DIR/state/dash-refs.json" >/dev/null \
  || fail "could not render the fixture dashboard with its refs sidecar"
PORT=$(pick_port)
write_config "$HOME_DIR" "$PORT"

test_identity_fails_closed() {
  local body
  start_server "$HOME_DIR" "$PORT"
  req GET "http://127.0.0.1:$PORT/healthz"
  [ "$REQ_STATUS" = 200 ] || fail "healthz should not require identity (got $REQ_STATUS)"
  req GET "http://127.0.0.1:$PORT/"
  [ "$REQ_STATUS" = 403 ] || fail "identity-less page read was not refused (got $REQ_STATUS)"
  req GET "http://127.0.0.1:$PORT/" "mallory@example.com"
  [ "$REQ_STATUS" = 403 ] || fail "unauthorized tailnet identity was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "mallory@example.com" '{"id":"CAP-06"}'
  [ "$REQ_STATUS" = 403 ] || fail "unauthorized dispatch was not refused (got $REQ_STATUS)"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -name '*.json' 2>/dev/null)" ] \
    || fail "a refused dispatch still wrote an inbox record"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "authorized captain read failed (got $REQ_STATUS)"
  pass "every route except healthz requires the configured captain identity"
}

test_browser_posts_require_same_origin() {
  REQ_STATUS=$(curl -s -o "$TMP_ROOT/resp.body" -w '%{http_code}' -X POST \
    -H "Tailscale-User-Login: $CAPTAIN" \
    -H 'Origin: https://evil.example' \
    -H 'Sec-Fetch-Site: cross-site' \
    -H 'content-type: application/json' \
    -d '{"id":"CAP-06"}' \
    "http://127.0.0.1:$PORT/api/dispatch")
  [ "$REQ_STATUS" = 403 ] || fail "cross-site browser dispatch was not refused (got $REQ_STATUS)"
  REQ_STATUS=$(curl -s -o "$TMP_ROOT/resp.body" -w '%{http_code}' -X POST \
    -H "Tailscale-User-Login: $CAPTAIN" \
    -H 'Sec-Fetch-Site: same-origin' \
    -H 'content-type: application/json' \
    -d '{"id":"CAP-06"}' \
    "http://127.0.0.1:$PORT/api/dispatch")
  [ "$REQ_STATUS" = 403 ] || fail "browser dispatch without Origin was not refused (got $REQ_STATUS)"
  REQ_STATUS=$(curl -s -o "$TMP_ROOT/resp.body" -w '%{http_code}' -X POST \
    -H "Tailscale-User-Login: $CAPTAIN" \
    -H "Origin: http://127.0.0.1:$PORT" \
    -H 'Sec-Fetch-Site: same-origin' \
    -H 'content-type: application/json' \
    -d '{"id":"CAP-02"}' \
    "http://127.0.0.1:$PORT/api/dispatch")
  [ "$REQ_STATUS" = 409 ] || fail "same-origin browser dispatch did not reach normal validation (got $REQ_STATUS)"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' 2>/dev/null)" ] \
    || fail "refused browser dispatch wrote an inbox record"
  pass "authenticated browser posts require a matching same origin"
}

test_served_page_wears_dashboard_with_interactive_layer() {
  local body
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'Firstmate capacity dashboard' "served page is not the producer dashboard"
  assert_contains "$RESP" 'fmdash-bar' "served page lacks the injected service bar"
  assert_contains "$RESP" 'Refresh capacity' "served page lacks the refresh control"
  assert_contains "$RESP" '>Live agents<' "served page lacks the live-agents section"
  assert_contains "$RESP" '"label":"Run the active rollout"' "served live-agent data lacks the task's plain title"
  assert_contains "$RESP" 'Approve & send' "served page lacks the dispatch control script"
  assert_contains "$RESP" 'data-copy' "producer copy layer was lost in serving"
  assert_contains "$RESP" '"ready-safe"' "served page config lacks the de-anonymized work item id"
  assert_contains "$RESP" 'IDEA-01' "served page config lacks the idea backlog"
  assert_contains "$RESP" 'postJson({ id })' "served prompt actions still require copy-paste"
  assert_contains "$RESP" 'Blocked by item-' "served dashboard does not render the blocked dependency chain"
  pass "served page is the producer dashboard wearing the injected interactive layer"
}

test_subscription_usage_panel() {
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'Subscription usage' "served page lacks the subscription usage panel"
  assert_contains "$RESP" '"label":"Claude"' "usage panel lacks Claude"
  assert_contains "$RESP" '"label":"Codex"' "usage panel lacks Codex"
  assert_contains "$RESP" '"label":"Grok"' "usage panel lacks Grok"
  assert_not_contains "$RESP" '"label":"Cursor"' "usage panel included a forbidden provider"
  assert_contains "$RESP" 'percentUsed":42' "usage panel lacks percent-used data"
  assert_contains "$RESP" 'toLocaleString()' "usage reset time is not rendered in the captain local timezone"
  assert_contains "$RESP" 'resets in ' "usage panel lacks reset-distance rendering"
  stop_server
  rm -f "$QUOTA_STUB"
  start_server "$HOME_DIR" "$PORT"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"usage":{"status":"unavailable","providers":[]}' "missing quota-axi did not degrade gracefully"
  pass "subscription usage is bounded to Claude, Codex, and Grok"
}

test_inline_config_is_script_safe() {
  cat >> "$HOME_DIR/data/ideas/idea-backlog.md" <<'EOF'

## IDEA-03 - </script><script>globalThis.fmdashPwned=true</script>&
Inline configuration must remain data.
EOF
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "page with hostile operational data failed (got $REQ_STATUS)"
  assert_not_contains "$RESP" '</script><script>globalThis.fmdashPwned=true</script>' "operational data broke out of the inline script"
  assert_contains "$RESP" '\u003c/script\u003e\u003cscript\u003eglobalThis.fmdashPwned=true\u003c/script\u003e\u0026' "inline script data was not safely escaped"
  pass "operational data cannot break out of the inline configuration script"
}

ref_for() {
  # ref_for <kind-owner-prefix> e.g. "main/ready-safe" or "decision/main/active-task/runtime-policy"
  node -e '
    const refs = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).refs;
    const wanted = process.argv[2];
    for (const [ref, entry] of Object.entries(refs)) {
      if (entry.kind === "item" && entry.value === wanted) { console.log(ref); process.exit(0); }
    }
    process.exit(1);
  ' "$HOME_DIR/state/dash-refs.json" "$1"
}

test_refs_sidecar_and_rich_work_item_detail() {
  local ref decision_ref same_key_ref
  assert_present "$HOME_DIR/state/dash-refs.json" "producer did not write the refs sidecar"
  assert_grep 'fm-capacity-refs.v1' "$HOME_DIR/state/dash-refs.json" "refs sidecar lacks its schema"
  decision_ref=$(ref_for "decision/main/active-task/rollout-policy") || fail "captain hold ref did not preserve its filed decision identity"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$decision_ref" "$CAPTAIN"
  assert_contains "$RESP" 'Conservative rollout' "filed captain hold did not resolve its options document"
  same_key_ref=$(ref_for "decision/main/secondary-task/rollout-policy") || fail "second same-home decision did not retain its origin-qualified ref"
  [ "$same_key_ref" != "$decision_ref" ] || fail "same-key decisions from distinct origins shared one opaque ref"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$same_key_ref" "$CAPTAIN"
  assert_contains "$RESP" 'Staged secondary rollout' "second same-key decision did not resolve its own options document"
  ref=$(ref_for "main/ready-safe") || fail "refs sidecar does not map the main work item"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "work item detail failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'streaming exports' "detail lacks the brief description"
  assert_contains "$RESP" 'backward compatible' "detail lacks the test plan"
  assert_contains "$RESP" 'pull/999' "detail lacks the PR link"
  assert_contains "$RESP" 'demo.tailebcf61.ts.net' "detail lacks the tailnet preview link"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$ref"
  [ "$REQ_STATUS" = 403 ] || fail "identity-less detail read was not refused (got $REQ_STATUS)"
  pass "clickable work items serve rich detail from briefs, metadata, and previews"
}

test_decision_detail_options_and_validated_approval() {
  local ref record
  ref=$(ref_for "decision/main/active-task/runtime-policy") || fail "refs sidecar does not map an origin-qualified non-backlog decision key"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "decision detail failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'Conservative rollout' "decision detail lacks its first option"
  assert_contains "$RESP" 'higher regression risk' "decision detail lacks the option impact"
  assert_contains "$RESP" '"recommended":true' "decision detail lacks its recommended marker"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":7}"
  [ "$REQ_STATUS" = 400 ] || fail "an off-record option was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":\"length\"}"
  [ "$REQ_STATUS" = 400 ] || fail "an array property was accepted as an option index (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":\"constructor\"}"
  [ "$REQ_STATUS" = 400 ] || fail "an inherited property was accepted as an option index (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":0}"
  [ "$REQ_STATUS" = 200 ] || fail "decision approval failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$ref.json" | head -1)")
  assert_contains "$record" '"decision"' "decision record lacks its kind"
  assert_contains "$record" 'runtime-policy' "decision record lacks the decision key"
  assert_contains "$record" 'Conservative rollout' "decision record lacks the chosen option"
  assert_contains "$record" 'chat confirmation' "decision record lacks the destructive-consequence boundary"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":1}"
  assert_contains "$RESP" 'already-queued' "a second choice for the same decision was not coalesced"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$ref.json" -delete
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"answer\":\"Use a 10% canary for 48 hours\"}"
  [ "$REQ_STATUS" = 200 ] || fail "custom decision answer failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$ref.json" | head -1)")
  assert_contains "$record" 'Use a 10% canary for 48 hours' "decision record lacks the custom answer"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$ref.json" -delete
  mv "$HOME_DIR/data/active-task/decisions/runtime-policy.md" "$HOME_DIR/data/active-task/decisions/runtime-policy.md.off"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$ref" "$CAPTAIN"
  assert_contains "$RESP" 'legacy decision' "legacy decision does not route to captain chat"
  assert_contains "$RESP" '"options":[]' "legacy backlog bullets were treated as structured decision options"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"answer\":\"unsafe fallback\"}"
  [ "$REQ_STATUS" = 400 ] || fail "legacy decision accepted free text without an options document"
  mv "$HOME_DIR/data/active-task/decisions/runtime-policy.md.off" "$HOME_DIR/data/active-task/decisions/runtime-policy.md"
  pass "decision documents validate option picks and bounded custom answers"
}

test_supervisor_decision_detail_uses_bounded_projection() {
  local remote_ref unavailable_ref main_ref generation record
  cp "$HOME_DIR/data/capacity-dashboard.html" "$TMP_ROOT/dashboard.remote-decision.bak"
  cp "$HOME_DIR/state/dash-refs.json" "$TMP_ROOT/refs.remote-decision.bak"
  jq --arg remote_home "$HOME_DIR/design" '
    .secondmate_current.registry.records = [{"id":"design","scope":"domain decisions","projects":["delta"]}]
    | .secondmate_current.records = [{
      "id":"design",
      "home":$remote_home,
      "current":{"state":"captain_decision","reason":null},
      "provenance":{"selected":"structured-home"},
      "active_children":[],
      "decisions_open":[
      {
        "id":"remote-origin-decision-rollout",
        "origin":"remote-origin",
        "key":"rollout",
        "verb":"captain-hold",
        "summary":"Choose the domain rollout",
        "source":"backlog",
        "detail":{
          "available":true,
          "title":"Choose the domain rollout",
          "context":"Pick the rollout that keeps every remote destination reachable.",
          "options":[
            {"text":"Bounded rollout","impact":"Preserves reachability with the smallest change.","recommended":true},
            {"text":"Expanded rollout","impact":"Adds a broader surface and more validation.","recommended":false}
          ]
        }
      },
      {
        "id":"remote-origin-decision-unreadable",
        "origin":"remote-origin",
        "key":"unreadable",
        "verb":"captain-hold",
        "summary":"Choose the unavailable-record fallback",
        "source":"backlog",
        "detail":{"available":false,"reason":"decision record could not be read (EACCES): data/remote-origin/decisions/unreadable.md"}
      }
      ],
      "holds":[],
      "queued":[
      {"id":"remote-origin-decision-rollout","title":"Choose the domain rollout","repo":"delta","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"captain choice pending","body_excerpt":"Origin: remote-origin\nDecision key: rollout"},
      {"id":"remote-origin-decision-unreadable","title":"Choose the unavailable-record fallback","repo":"delta","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"captain choice pending","body_excerpt":"Origin: remote-origin\nDecision key: unreadable"}
      ],
      "landed":[],
      "counts":{"active_children":0,"decisions_open":2,"holds":0,"queued":2},
      "omitted":[]
    }]
    | .secondmate_current.total = 1
    | .secondmate_current.shown = 1
    | .secondmate_current.truncated = 0
  ' "$SNAPSHOT" > "$TMP_ROOT/remote-decision-snapshot.json"
  FM_HOME="$HOME_DIR" "$CAPACITY" --snapshot "$TMP_ROOT/remote-decision-snapshot.json" --environment "$ENVIRONMENT" \
    --output "$HOME_DIR/data/capacity-dashboard.html" --refs "$HOME_DIR/state/dash-refs.json" >/dev/null \
    || fail "could not render the supervisor decision fixture dashboard"
  remote_ref=$(ref_for "decision/design/remote-origin/rollout") \
    || fail "refs sidecar omitted the supervisor decision: $(jq -c '.refs | to_entries | map(.value.value)' "$HOME_DIR/state/dash-refs.json")"
  unavailable_ref=$(ref_for "decision/design/remote-origin/unreadable") || fail "refs sidecar omitted the unreadable supervisor decision"
  main_ref=$(ref_for "decision/main/active-task/runtime-policy") || fail "refs sidecar lost the main-home decision"
  generation=$(jq -r '.generated' "$HOME_DIR/state/dash-refs.json")

  req GET "http://127.0.0.1:$PORT/api/detail?ref=$remote_ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "supervisor decision detail failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'Choose the domain rollout' "supervisor decision detail lacks its title"
  assert_contains "$RESP" 'keeps every remote destination reachable' "supervisor decision detail lacks its context"
  assert_contains "$RESP" 'Bounded rollout' "supervisor decision detail lacks its options"
  assert_contains "$RESP" '"recommended":true' "supervisor decision detail lacks its recommendation marker"
  assert_contains "$RESP" 'lives with a domain supervisor' "supervisor decision detail lacks its small provenance note"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$remote_ref\",\"option\":0}"
  [ "$REQ_STATUS" = 200 ] || fail "supervisor decision option failed (got $REQ_STATUS: $RESP)"
  record=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$remote_ref.json" | head -1)
  [ -n "$record" ] || fail "supervisor decision option did not write a command"
  rm -f "$record"

  req GET "http://127.0.0.1:$PORT/api/detail?ref=$unavailable_ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "unreadable supervisor decision detail failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'Decision details unavailable' "unreadable supervisor decision did not degrade honestly"
  assert_contains "$RESP" 'EACCES' "unreadable supervisor decision omitted its concrete reason"
  assert_contains "$RESP" '"options":[]' "unreadable supervisor decision invented options"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$unavailable_ref\",\"action\":\"go\",\"dashboard_generated\":\"$generation\"}"
  [ "$REQ_STATUS" = 200 ] || fail "unreadable supervisor decision generic action failed (got $REQ_STATUS: $RESP)"
  record=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$unavailable_ref.json" | head -1)
  [ -n "$record" ] || fail "unreadable supervisor decision generic action did not write a command"
  rm -f "$record"

  req GET "http://127.0.0.1:$PORT/api/detail?ref=$main_ref" "$CAPTAIN"
  assert_contains "$RESP" 'Choose how the active rollout should continue.' "main-home decision context changed"
  assert_contains "$RESP" 'Conservative rollout' "main-home decision options changed"
  assert_not_contains "$RESP" 'domain supervisor' "main-home decision gained remote provenance"

  mv "$TMP_ROOT/dashboard.remote-decision.bak" "$HOME_DIR/data/capacity-dashboard.html"
  mv "$TMP_ROOT/refs.remote-decision.bak" "$HOME_DIR/state/dash-refs.json"
  pass "supervisor decisions use bounded full detail, unavailable records stay actionable, and main-home detail is unchanged"
}

test_decision_answers_are_qualified_by_home_and_origin() {
  local main_ref same_home_ref mate_ref files records file
  mkdir -p "$HOME_DIR/data/origin-alpha/decisions" "$HOME_DIR/data/origin-beta/decisions" "$HOME_DIR/design/data/design-origin/decisions"
  printf 'home=%s\n' "$HOME_DIR/design" > "$HOME_DIR/state/design.meta"
  cp "$HOME_DIR/data/active-task/decisions/runtime-policy.md" "$HOME_DIR/data/origin-alpha/decisions/shared-policy.md"
  cp "$HOME_DIR/data/active-task/decisions/rollout-policy.md" "$HOME_DIR/data/origin-beta/decisions/shared-policy.md"
  cp "$HOME_DIR/data/active-task/decisions/runtime-policy.md" "$HOME_DIR/design/data/design-origin/decisions/shared-policy.md"
  # JavaScript template literals are intentionally single-quoted for the shell.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const refs = JSON.parse(fs.readFileSync(file, "utf8"));
    refs.refs["item-90"] = { kind: "item", value: "decision/main/origin-alpha/shared-policy" };
    refs.refs["item-91"] = { kind: "item", value: "decision/main/origin-beta/shared-policy" };
    refs.refs["item-92"] = {
      kind: "item",
      value: "decision/design/design-origin/shared-policy",
      decision_detail: {
        available: true,
        title: "Choose the runtime policy",
        context: "Choose how the active rollout should continue.",
        options: [
          { text: "Conservative rollout", impact: "Slower delivery with the lowest regression risk.", recommended: true },
          { text: "Fast rollout", impact: "Reaches everyone this week with higher regression risk.", recommended: false }
        ]
      }
    };
    fs.writeFileSync(file, `${JSON.stringify(refs, null, 2)}\n`);
  ' "$HOME_DIR/state/dash-refs.json"
  main_ref=item-90
  same_home_ref=item-91
  mate_ref=item-92
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$main_ref\",\"option\":0}"
  [ "$REQ_STATUS" = 200 ] || fail "main-home decision answer failed (got $REQ_STATUS: $RESP)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$same_home_ref\",\"option\":0}"
  [ "$REQ_STATUS" = 200 ] || fail "same-key same-home decision was wrongly coalesced (got $REQ_STATUS: $RESP)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$mate_ref\",\"option\":0}"
  [ "$REQ_STATUS" = 200 ] || fail "same-key secondmate decision was wrongly coalesced (got $REQ_STATUS: $RESP)"
  files=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*item-9[012].json')
  [ "$(printf '%s\n' "$files" | grep -c .)" = 3 ] || fail "origin-qualified decision answers did not produce three records"
  records=''
  while IFS= read -r file; do
    records="$records$(cat "$file")"
    rm -f "$file"
  done <<EOF
$files
EOF
  assert_contains "$records" '"decision_identity": "main/origin-alpha/shared-policy"' "first main decision record lacks durable origin identity"
  assert_contains "$records" '"decision_identity": "main/origin-beta/shared-policy"' "same-home decision record lacks distinct origin identity"
  assert_contains "$records" '"decision_identity": "design/design-origin/shared-policy"' "secondmate decision record lacks durable owner identity"
  pass "equal decision keys remain distinct across origins and homes"
}

test_stale_refs_are_disabled() {
  local ref
  ref=$(ref_for "decision/main/active-task/runtime-policy") || fail "refs sidecar does not map the decision"
  # JavaScript template literals are intentionally single-quoted for the shell.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const refs = JSON.parse(fs.readFileSync(file, "utf8"));
    refs.generated = "stale-generation";
    fs.writeFileSync(file, `${JSON.stringify(refs, null, 2)}\n`);
  ' "$HOME_DIR/state/dash-refs.json"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"refs":{}' "stale refs still de-anonymized the served page"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 404 ] || fail "stale refs still resolved detail (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":0}"
  [ "$REQ_STATUS" = 400 ] || fail "stale refs still authorized an approval (got $REQ_STATUS)"
  # JavaScript template literals are intentionally single-quoted for the shell.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const refs = JSON.parse(fs.readFileSync(file, "utf8"));
    refs.generated = "2026-07-28T10:00:00Z";
    fs.writeFileSync(file, `${JSON.stringify(refs, null, 2)}\n`);
  ' "$HOME_DIR/state/dash-refs.json"
  pass "refs are usable only for their matching dashboard generation"
}

test_idea_pitch_and_verdicts() {
  local record prior_name
  req GET "http://127.0.0.1:$PORT/api/detail?idea=IDEA-01" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "idea pitch failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'One command provisions' "idea detail lacks the pitch file content"
  req GET "http://127.0.0.1:$PORT/api/detail?idea=IDEA-02" "$CAPTAIN"
  assert_contains "$RESP" 'nightly fleet digest' "pitchless idea lacks its concept summary"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-01","verdict":"approve"}'
  [ "$REQ_STATUS" = 200 ] || fail "idea approval failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-01.json' | head -1)")
  assert_contains "$record" '"idea"' "idea record lacks its kind"
  assert_contains "$record" 'normal backlog lifecycle' "idea approval does not route creation through firstmate"
  prior_name=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-01.json' | head -1)
  mkdir -p "$HOME_DIR/state/dash-inbox/archive"
  cp "$prior_name" "$HOME_DIR/state/dash-inbox/archive/$(basename "$prior_name")"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-01","verdict":"deny"}'
  assert_contains "$RESP" '"replaced"' "newest contradictory idea verdict did not replace the pending verdict"
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-01.json' | wc -l | tr -d ' ')" = 1 ] \
    || fail "verdict replacement left contradictory pending records"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-01.json' | head -1)")
  assert_contains "$record" '"verdict": "deny"' "verdict replacement did not retain the newest choice"
  [ "$(basename "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-01.json' | head -1)")" != "$(basename "$prior_name")" ] \
    || fail "verdict replacement reused a claimable inbox identity"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-99","verdict":"approve"}'
  [ "$REQ_STATUS" = 404 ] || fail "an unlisted idea was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-02","verdict":"suggest","suggestion":"scope it to weekdays only"}'
  [ "$REQ_STATUS" = 200 ] || fail "idea suggestion failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-02.json' | head -1)")
  assert_contains "$record" 'scope it to weekdays only' "suggestion text was not recorded for firstmate"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-02","verdict":"suggest","suggestion":"include landed work"}'
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-02.json' | wc -l | tr -d ' ')" = 2 ] \
    || fail "additive idea suggestions were coalesced"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-02","verdict":"suggest","suggestion":""}'
  [ "$REQ_STATUS" = 400 ] || fail "an empty suggestion was not refused (got $REQ_STATUS)"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*IDEA-*.json' -delete
  pass "ideas render their pitches and verdicts flow through the durable inbox"
}

test_parking_lot_enrichment_and_unpark() {
  local ref record
  cp "$HOME_DIR/data/capacity-dashboard.html" "$TMP_ROOT/dashboard.parked.bak"
  cp "$HOME_DIR/state/dash-refs.json" "$TMP_ROOT/refs.parked.bak"
  cp "$HOME_DIR/data/backlog.md" "$TMP_ROOT/backlog.parked.bak"
  jq '.backlog.records += [
    {"order":9,"state":"queued","structured":true,"id":"parked-rest","title":"Refresh the omicron gateway","repo":"omicron","project_resolved":true,"kind":"ship","since":"2026-07-10","hold_kind":"parked","hold_reason":"Captain parked omicron work until the retreat","body_excerpt":"Acceptance criteria: omicron gateway upgraded."}
  ]' "$SNAPSHOT" > "$TMP_ROOT/parked-snapshot.json"
  printf -- '- [ ] parked-rest - Refresh the omicron gateway (repo: omicron) (kind: ship) (since 2026-07-10) (hold: Captain parked omicron work until the retreat) (hold-kind: parked)\n' >> "$HOME_DIR/data/backlog.md"
  FM_HOME="$HOME_DIR" "$CAPACITY" --snapshot "$TMP_ROOT/parked-snapshot.json" --environment "$ENVIRONMENT" \
    --output "$HOME_DIR/data/capacity-dashboard.html" --refs "$HOME_DIR/state/dash-refs.json" >/dev/null \
    || fail "could not render the parked fixture dashboard"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'Parking lot (1)' "served page lacks the parking lot"
  assert_contains "$RESP" '"title":"Refresh the omicron gateway"' "parked entry was not enriched with its real title"
  assert_contains "$RESP" '"reason":"Captain parked omicron work until the retreat"' "parked entry was not enriched with the park reason"
  assert_contains "$RESP" '"since":"2026-07-10"' "parked entry was not enriched with its date"
  assert_contains "$RESP" 'meta.textContent = "on the books since " + info.since' "served parking metadata does not render the parsed date"
  assert_contains "$RESP" 'Unpark' "parked entry lacks the unpark control"
  ref=$(ref_for "main/parked-rest") || fail "refs sidecar does not map the parked item"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"unpark":"item-99"}'
  [ "$REQ_STATUS" = 409 ] || fail "an unlisted unpark reference was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"unpark":"nonsense"}'
  [ "$REQ_STATUS" = 400 ] || fail "a malformed unpark reference was not refused (got $REQ_STATUS)"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' 2>/dev/null)" ] \
    || fail "a refused unpark still wrote an inbox record"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"unpark\":\"$ref\"}"
  [ "$REQ_STATUS" = 200 ] || fail "unpark dispatch failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$ref.json" | head -1)")
  assert_contains "$record" '"kind": "unpark"' "unpark record lacks its kind"
  assert_contains "$record" '"work_id": "parked-rest"' "unpark record lacks the real work id"
  assert_contains "$record" '"work_home": "main"' "unpark record lacks the owning home"
  assert_contains "$record" 'normal backlog lifecycle' "unpark record does not route the lift through firstmate"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"unpark\":\"$ref\"}"
  assert_contains "$RESP" 'already-queued' "a repeated unpark was not coalesced"
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
    || fail "repeated unpark clicks wrote duplicate records"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' -delete
  mv "$TMP_ROOT/dashboard.parked.bak" "$HOME_DIR/data/capacity-dashboard.html"
  mv "$TMP_ROOT/refs.parked.bak" "$HOME_DIR/state/dash-refs.json"
  mv "$TMP_ROOT/backlog.parked.bak" "$HOME_DIR/data/backlog.md"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"unpark\":\"$ref\"}"
  [ "$REQ_STATUS" = 409 ] || fail "an unpark for a no-longer-parked item was not refused (got $REQ_STATUS)"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"parked":[]' "an empty parking lot still carried parked entries"
  assert_not_contains "$RESP" 'Parking lot (' "an empty parking lot still rendered a section"
  pass "the parking lot is enriched for the captain and unpark clicks become one durable lifted-through-firstmate command"
}

test_recurring_enrichment_and_run_now() {
  local ref scout_ref mate_scout_ref record
  cp "$HOME_DIR/data/capacity-dashboard.html" "$TMP_ROOT/dashboard.recurring.bak"
  cp "$HOME_DIR/state/dash-refs.json" "$TMP_ROOT/refs.recurring.bak"
  cp "$HOME_DIR/data/backlog.md" "$TMP_ROOT/backlog.recurring.bak"
  jq '.backlog.records += [
    {"order":9,"state":"queued","structured":true,"id":"research-w9","title":"Weekly gamma market research","repo":"gamma","project_resolved":true,"kind":"scout","since":"2026-07-14","hold_kind":"future","hold_reason":"weekly cadence while gamma ships","hold_until":"2026-08-04","body_excerpt":"Acceptance criteria: report is filed."},
    {"order":10,"state":"queued","structured":true,"id":"scout-r5","title":"Weekly scout research","repo":"gamma","project_resolved":true,"kind":"scout","since":"2026-07-15","hold_kind":"future","hold_reason":"weekly scout cadence","hold_until":"2026-08-04","body_excerpt":"Acceptance criteria: report is filed."},
    {"order":11,"state":"done","structured":true,"id":"research-w8","title":"Weekly gamma market research","repo":"gamma","project_resolved":true,"kind":"scout","pr_url":"https://github.com/purple-phoenix/firstmate/pull/900","links":["https://github.com/purple-phoenix/firstmate/pull/900"],"completion":{"verb":"merged","date":"2026-07-21"}},
    {"order":12,"state":"done","structured":true,"id":"scout-r4","title":"Weekly scout research","repo":"gamma","project_resolved":true,"kind":"scout","report_path":"data/scout-r4/report.md","completion":{"verb":"reported","date":"2026-07-22"}}
  ]' "$SNAPSHOT" > "$TMP_ROOT/recurring-snapshot.json"
  {
    printf -- '- [ ] research-w9 - Weekly gamma market research (repo: gamma) (kind: scout) (since 2026-07-14) (hold: weekly cadence while gamma ships) (hold-kind: future) (hold-until: 2026-08-04)\n'
    printf -- '- [ ] scout-r5 - Weekly scout research (repo: gamma) (kind: scout) (since 2026-07-15) (hold: weekly scout cadence) (hold-kind: future) (hold-until: 2026-08-04)\n'
    printf -- '- [x] research-w8 - Weekly gamma market research https://github.com/purple-phoenix/firstmate/pull/900 (merged 2026-07-21)\n'
    printf -- '- [x] scout-r4 - Weekly scout research data/scout-r4/report.md (reported 2026-07-22)\n'
  } >> "$HOME_DIR/data/backlog.md"
  mkdir -p "$HOME_DIR/data/scout-r4"
  printf '%s\n' '# Weekly scout report' 'The recorded scout findings are available here.' > "$HOME_DIR/data/scout-r4/report.md"
  FM_HOME="$HOME_DIR" "$CAPACITY" --snapshot "$TMP_ROOT/recurring-snapshot.json" --environment "$ENVIRONMENT" \
    --output "$HOME_DIR/data/capacity-dashboard.html" --refs "$HOME_DIR/state/dash-refs.json" >/dev/null \
    || fail "could not render the recurring fixture dashboard"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'Recurring (2)' "served page lacks the recurring section"
  assert_contains "$RESP" 'next: Aug 4' "served page lacks the next-run date"
  assert_contains "$RESP" '"title":"Weekly gamma market research"' "recurring entry was not enriched with its real title"
  assert_contains "$RESP" '"reason":"weekly cadence while gamma ships"' "recurring entry was not enriched with the schedule reason"
  assert_contains "$RESP" '"next":"2026-08-04"' "recurring entry was not enriched with its next-run date"
  assert_contains "$RESP" '"link":"https://github.com/purple-phoenix/firstmate/pull/900"' "recurring entry was not enriched with the last run artifact link"
  assert_contains "$RESP" '"title":"Weekly scout research"' "scout recurring entry was not enriched with its clean title"
  scout_ref=$(ref_for "main/scout-r4") || fail "refs sidecar does not map the completed scout run"
  assert_contains "$RESP" "\"date\":\"2026-07-22\",\"link\":null,\"detail_ref\":\"$scout_ref\"" "scout recurring entry did not route its report through completed-run detail"
  assert_contains "$RESP" 'link.href = "/api/detail?ref=" + encodeURIComponent(detailRef)' "scout report control does not target the existing detail endpoint"
  assert_not_contains "$RESP" '"link":"data/scout-r4/report.md"' "scout report still exposes a dead relative href"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$scout_ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "completed scout detail failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'The recorded scout findings are available here.' "completed scout detail lacks its report excerpt"
  mate_scout_ref=item-9999
  mkdir -p "$HOME_DIR/design/data/mate-scout-r4"
  printf 'home=%s\n' "$HOME_DIR/design" > "$HOME_DIR/state/design.meta"
  printf '%s\n' '# Domain scout report' 'The domain supervisor recorded these scout findings.' > "$HOME_DIR/design/data/mate-scout-r4/report.md"
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const refs = JSON.parse(fs.readFileSync(file, "utf8"));
    refs.refs[process.argv[2]] = { kind: "item", value: "design/mate-scout-r4" };
    fs.writeFileSync(file, JSON.stringify(refs));
  ' "$HOME_DIR/state/dash-refs.json" "$mate_scout_ref"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$mate_scout_ref" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "secondmate scout detail failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'The domain supervisor recorded these scout findings.' "secondmate scout detail lacks its bounded report excerpt"
  assert_contains "$RESP" 'lives with a domain supervisor' "secondmate scout detail lost its ownership boundary"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'Run now' "recurring entry lacks the run-now control"
  ref=$(ref_for "main/research-w9") || fail "refs sidecar does not map the recurring item"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"run_now":"item-99"}'
  [ "$REQ_STATUS" = 409 ] || fail "an unlisted run-now reference was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"run_now":"nonsense"}'
  [ "$REQ_STATUS" = 400 ] || fail "a malformed run-now reference was not refused (got $REQ_STATUS)"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' 2>/dev/null)" ] \
    || fail "a refused run-now still wrote an inbox record"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"run_now\":\"$ref\"}"
  [ "$REQ_STATUS" = 200 ] || fail "run-now dispatch failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$ref.json" | head -1)")
  assert_contains "$record" '"kind": "run-now"' "run-now record lacks its kind"
  assert_contains "$record" '"work_id": "research-w9"' "run-now record lacks the real work id"
  assert_contains "$record" '"work_home": "main"' "run-now record lacks the owning home"
  assert_contains "$record" 'normal backlog lifecycle' "run-now record does not route the hold lift through firstmate"
  assert_contains "$record" 'authority checks' "run-now record does not preserve normal dispatch authority"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"run_now\":\"$ref\"}"
  assert_contains "$RESP" 'already-queued' "a repeated run-now was not coalesced"
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
    || fail "repeated run-now clicks wrote duplicate records"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' -delete
  rm "$HOME_DIR/data/scout-r4/report.md"
  rmdir "$HOME_DIR/data/scout-r4"
  rm "$HOME_DIR/design/data/mate-scout-r4/report.md"
  rmdir "$HOME_DIR/design/data/mate-scout-r4"
  mv "$TMP_ROOT/dashboard.recurring.bak" "$HOME_DIR/data/capacity-dashboard.html"
  mv "$TMP_ROOT/refs.recurring.bak" "$HOME_DIR/state/dash-refs.json"
  mv "$TMP_ROOT/backlog.recurring.bak" "$HOME_DIR/data/backlog.md"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"run_now\":\"$ref\"}"
  [ "$REQ_STATUS" = 409 ] || fail "a run-now for a no-longer-recurring item was not refused (got $REQ_STATUS)"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"recurring":[]' "an empty recurring section still carried entries"
  assert_not_contains "$RESP" 'Recurring (' "an empty recurring section still rendered"
  pass "the recurring section is enriched for the captain and run-now clicks become one durable through-firstmate command"
}

test_your_go_controls_for_captain_awaiting_items() {
  local go_ref consent_ref option_ref generation record archived
  cp "$HOME_DIR/data/capacity-dashboard.html" "$TMP_ROOT/dashboard.yourgo.bak"
  cp "$HOME_DIR/state/dash-refs.json" "$TMP_ROOT/refs.yourgo.bak"
  cp "$HOME_DIR/data/backlog.md" "$TMP_ROOT/backlog.yourgo.bak"
  jq '.backlog.records += [
    {"order":9,"state":"queued","structured":true,"id":"audit-idea-w6","title":"Feature idea: unified workspace","repo":"gamma","project_resolved":true,"kind":"ship","since":"2026-07-29","hold_kind":"captain","hold_reason":"Audit feature opportunity - queued for captain prioritization","body_excerpt":"Acceptance criteria: workspace carries context."},
    {"order":10,"state":"queued","structured":true,"id":"astro-tests-decision-consent","title":"Supply testimonials consent","repo":"alpha","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"supply the astro testimonials and consent text","body_excerpt":"Origin: astro-tests\nDecision key: consent\nState: awaiting captain decision."}
  ]' "$SNAPSHOT" > "$TMP_ROOT/yourgo-snapshot.json"
  {
    printf -- '- [ ] audit-idea-w6 - Feature idea: unified workspace (repo: gamma) (kind: ship) (since 2026-07-29) (hold: Audit feature opportunity - queued for captain prioritization) (hold-kind: captain)\n'
    printf -- '- [ ] astro-tests-decision-consent - Supply testimonials consent (repo: alpha) (kind: captain) (hold: supply the astro testimonials and consent text) (hold-kind: captain)\n'
  } >> "$HOME_DIR/data/backlog.md"
  FM_HOME="$HOME_DIR" "$CAPACITY" --snapshot "$TMP_ROOT/yourgo-snapshot.json" --environment "$ENVIRONMENT" \
    --output "$HOME_DIR/data/capacity-dashboard.html" --refs "$HOME_DIR/state/dash-refs.json" >/dev/null \
    || fail "could not render the your-go fixture dashboard"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'data-your-go-ref="item-' "needs-you rows lack their your-go interaction anchors"
  assert_contains "$RESP" 'data-your-go-kind="review"' "the your-go prioritization hold row lacks its review anchor"
  assert_contains "$RESP" 'data-your-go-kind="decision"' "decision rows lack their your-go anchors"
  assert_contains "$RESP" '"has_options":true' "an options-backed decision lost its per-option path marker"
  assert_contains "$RESP" '"has_options":false' "a hold without an options document was not marked for generic controls"
  assert_contains "$RESP" '"ask":"supply the astro testimonials and consent text"' "the captain-deliverable hold did not surface its ask"
  assert_contains "$RESP" '"ask":null' "a plain prioritization hold wrongly carried a deliverable ask"
  assert_contains "$RESP" 'Go ahead' "generic controls lack the go-ahead button"
  assert_contains "$RESP" 'Not now' "generic controls lack the not-now button"
  assert_contains "$RESP" 'Send guidance' "generic controls lack the guidance button"
  assert_contains "$RESP" 'Provide it' "the deliverable ask lacks its provide control"
  assert_contains "$RESP" 'openGuidance(info.ask + ": ", "Send")' "the provide control does not prefill the guidance box with the ask"
  assert_contains "$RESP" 'openDetail(info.ref, entry)' "the options-backed decision row does not open its per-option detail"
  assert_contains "$RESP" 'dashboard_generated: cfg.generated' "your-go dispatches do not carry the served page generation"
  go_ref=$(ref_for "main/audit-idea-w6") || fail "refs sidecar does not map the your-go hold"
  consent_ref=$(ref_for "decision/main/astro-tests/consent") || fail "refs sidecar does not map the optionless decision"
  option_ref=$(ref_for "decision/main/active-task/rollout-policy") || fail "refs sidecar does not map the options-backed decision"
  generation=$(jq -r '.generated' "$HOME_DIR/state/dash-refs.json")
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"your_go":"nonsense","action":"go"}'
  [ "$REQ_STATUS" = 400 ] || fail "a malformed your-go reference was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"item-99\",\"action\":\"go\",\"dashboard_generated\":\"$generation\"}"
  [ "$REQ_STATUS" = 409 ] || fail "an unlisted your-go reference was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"discard\"}"
  [ "$REQ_STATUS" = 400 ] || fail "an unknown your-go action was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"guidance\",\"text\":\"\"}"
  [ "$REQ_STATUS" = 400 ] || fail "empty guidance was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"go\",\"dashboard_generated\":\"stale-generation\"}"
  [ "$REQ_STATUS" = 409 ] || fail "a your-go from a stale dashboard generation was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$option_ref\",\"action\":\"go\",\"dashboard_generated\":\"$generation\"}"
  [ "$REQ_STATUS" = 409 ] || fail "an options-backed decision accepted a generic your-go action (got $REQ_STATUS)"
  assert_contains "$RESP" 'per-option approval flow' "options-backed decision refusal does not direct the captain to its options"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' 2>/dev/null)" ] \
    || fail "a refused your-go still wrote an inbox record"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"go\",\"dashboard_generated\":\"$generation\"}"
  [ "$REQ_STATUS" = 200 ] || fail "your-go go-ahead dispatch failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$go_ref.json" | head -1)")
  assert_contains "$record" '"kind": "your-go"' "your-go record lacks its kind"
  assert_contains "$record" '"action": "go"' "your-go record lacks the chosen action"
  assert_contains "$record" '"work_identity": "main/audit-idea-w6"' "your-go record lacks the hold identity"
  assert_contains "$record" 'normal backlog lifecycle' "your-go record does not route the hold lift through firstmate"
  assert_contains "$record" 'chat confirmation' "your-go record lacks the destructive-consequence boundary"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"go\",\"dashboard_generated\":\"$generation\"}"
  assert_contains "$RESP" 'already-queued' "a repeated your-go was not coalesced"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"park\",\"dashboard_generated\":\"$generation\"}"
  assert_contains "$RESP" '"replaced"' "a newer your-go verdict did not replace the pending one"
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
    || fail "verdict replacement left contradictory pending your-go records"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$go_ref.json" | head -1)")
  assert_contains "$record" '"action": "park"' "verdict replacement did not retain the newest action"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"ack":{"status":"pending"' "a pending your-go does not acknowledge on its row"
  archived="$HOME_DIR/state/dash-inbox/archive/review-yourgo.json"
  mkdir -p "$(dirname "$archived")"
  mv "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$go_ref.json" | head -1)" "$archived"
  # JavaScript template literals are intentionally single-quoted for the shell.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const record = JSON.parse(fs.readFileSync(file, "utf8"));
    record.dashboard_generated = "a-previous-generation";
    record.requested_at = new Date().toISOString();
    fs.writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
  ' "$archived"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"kind":"your-go","action":"park"' "a prior your-go acknowledgment lost its selected action"
  assert_contains "$RESP" 'Previously parked' "the acknowledgment layer lacks an action-appropriate parked label"
  assert_contains "$RESP" 'Guidance previously sent' "the acknowledgment layer lacks an action-appropriate guidance label"
  rm "$archived"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$consent_ref\",\"action\":\"guidance\",\"text\":\"Use the April quotes only\",\"dashboard_generated\":\"$generation\"}"
  [ "$REQ_STATUS" = 200 ] || fail "guidance for the optionless decision failed (got $REQ_STATUS: $RESP)"
  record=$(cat "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name "*$consent_ref.json" | head -1)")
  assert_contains "$record" '"decision_identity": "main/astro-tests/consent"' "decision-targeted your-go lacks the durable decision identity"
  assert_contains "$record" 'Use the April quotes only' "guidance text was not recorded for firstmate"
  assert_contains "$record" 'decision lifecycle' "decision-targeted guidance does not route through the decision lifecycle"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' -delete
  mv "$TMP_ROOT/dashboard.yourgo.bak" "$HOME_DIR/data/capacity-dashboard.html"
  mv "$TMP_ROOT/refs.yourgo.bak" "$HOME_DIR/state/dash-refs.json"
  mv "$TMP_ROOT/backlog.yourgo.bak" "$HOME_DIR/data/backlog.md"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"your_go\":\"$go_ref\",\"action\":\"go\",\"dashboard_generated\":\"$generation\"}"
  [ "$REQ_STATUS" = 409 ] || fail "a your-go for a no-longer-listed item was not refused (got $REQ_STATUS)"
  pass "every item awaiting the captain carries validated interaction controls through the durable inbox"
}

test_dispatch_writes_one_durable_record() {
  local body record file
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"CAP-06"}'
  [ "$REQ_STATUS" = 200 ] || fail "captain dispatch failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" '"queued"' "dispatch did not report queued"
  file=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*CAP-06.json' | head -1)
  [ -n "$file" ] || fail "dispatch wrote no durable inbox record"
  case "$(uname)" in
    Darwin) [ "$(stat -f %Lp "$file")" = 600 ] || fail "inbox record is not mode 0600" ;;
    *) [ "$(stat -c %a "$file")" = 600 ] || fail "inbox record is not mode 0600" ;;
  esac
  record=$(cat "$file")
  assert_contains "$record" '"fm-dash-command.v1"' "inbox record lacks its schema"
  assert_contains "$record" '"CAP-06"' "inbox record lacks the action id"
  assert_contains "$record" 'Approve CAP-06' "inbox record lacks the model prompt"
  assert_contains "$record" "$CAPTAIN" "inbox record lacks the requesting identity"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"CAP-06"}'
  assert_contains "$RESP" 'already-queued' "duplicate dispatch was not coalesced"
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*CAP-06.json' | wc -l | tr -d ' ')" = 1 ] \
    || fail "duplicate dispatch wrote a second record"
  pass "a click becomes exactly one durable captain command record"
}

test_dispatch_refuses_unknown_and_uncurrent_actions() {
  local body
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"rm -rf /"}'
  [ "$REQ_STATUS" = 400 ] || fail "free-text dispatch was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"CAP-99"}'
  [ "$REQ_STATUS" = 403 ] || fail "an action outside the one-click allowlist was not refused (got $REQ_STATUS)"
  assert_contains "$RESP" 'captain chat' "the allowlist refusal does not route to captain chat"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"CAP-02"}'
  [ "$REQ_STATUS" = 409 ] || fail "an action absent from the current dashboard was not refused (got $REQ_STATUS)"
  pass "dispatch refuses free text, non-allowlisted actions, and stale actions"
}

test_refresh_reruns_producer_server_side() {
  local body before after
  before=$(grep -o 'generated [^<]*' "$HOME_DIR/data/capacity-dashboard.html" | head -1)
  stop_server
  start_server "$HOME_DIR" "$PORT" "--snapshot $SNAPSHOT --environment $ENVIRONMENT"
  rm -f "$HOME_DIR/data/capacity-dashboard.html"
  req POST "http://127.0.0.1:$PORT/api/refresh" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "refresh failed (got $REQ_STATUS: $RESP)"
  assert_contains "$RESP" 'refreshed' "refresh did not report success"
  [ -f "$HOME_DIR/data/capacity-dashboard.html" ] || fail "refresh did not regenerate the dashboard"
  after=$(grep -o 'generated [^<]*' "$HOME_DIR/data/capacity-dashboard.html" | head -1)
  [ -n "$after" ] || fail "regenerated dashboard has no generated stamp"
  : "$before"
  pass "refresh reruns the capacity producer server-side and replaces the dashboard"
}

test_inbox_list_claim_and_archive() {
  local archived_file archived_mtime out pending_file stub_bin
  out=$(FM_HOME="$HOME_DIR" "$INBOX_SH" pending-count)
  [ "$out" = 1 ] || fail "pending-count expected 1, got: $out"
  out=$(FM_HOME="$HOME_DIR" "$INBOX_SH" list)
  assert_contains "$out" 'CAP-06' "list omits the pending action"
  assert_contains "$out" "$CAPTAIN" "list omits the requesting identity"
  stub_bin="$TMP_ROOT/failing-mv"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/mv" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod 700 "$stub_bin/mv"
  out=$(PATH="$stub_bin:$PATH" FM_HOME="$HOME_DIR" "$INBOX_SH" claim)
  assert_contains "$out" 'Approve CAP-06' "claim did not deliver before attempting archive"
  assert_contains "$out" 'delivered: 1' "failed archive did not report the delivered command"
  assert_contains "$out" 'archived: 0' "failed archive did not report its archive count"
  assert_contains "$out" 'idempotency checks' "failed archive omitted the replay handling reminder"
  pending_file=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*CAP-06.json' 2>/dev/null | head -1)
  [ -n "$pending_file" ] \
    || fail "failed archive silently removed the delivered command"
  touch -t 202001010000 "$pending_file"
  out=$(FM_HOME="$HOME_DIR" "$INBOX_SH" claim)
  assert_contains "$out" 'delivered: 1' "claim did not report the delivered command"
  assert_contains "$out" 'archived: 1' "claim did not report the archived command"
  assert_contains "$out" 'Approve CAP-06' "claim omits the command prompt"
  assert_contains "$out" 'authority limits apply' "claim omits the authority boundary reminder"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' 2>/dev/null)" ] \
    || fail "claim left the record pending"
  archived_file=$(find "$HOME_DIR/state/dash-inbox/archive" -name '*CAP-06.json' 2>/dev/null | head -1)
  [ -n "$archived_file" ] \
    || fail "claim did not archive the record"
  archived_mtime=$(node -e 'console.log(require("node:fs").statSync(process.argv[1]).mtimeMs)' "$archived_file")
  node -e 'if (Number(process.argv[1]) < Date.now() - 60000) process.exit(1)' "$archived_mtime" \
    || fail "archive mtime retained enqueue time instead of recording claim time"
  out=$(FM_HOME="$HOME_DIR" "$INBOX_SH" claim)
  assert_contains "$out" 'no pending dashboard commands' "second claim re-surfaced the archived command"
  pass "inbox claim delivers before archive and safely permits replay"
}

test_click_ack_and_handled_states() {
  local before_backlog marker_refreshes ref detail_ref tries
  before_backlog=$(cat "$HOME_DIR/data/backlog.md")
  # A record claimed under the currently served generation acknowledges as
  # received, with the claim time, straight from the archive.
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"acks":{"CAP-06":{"status":"claimed"' "claimed CAP click does not acknowledge as received"
  assert_contains "$RESP" 'Received - being worked' "served layer lacks the received-state copy"
  assert_contains "$RESP" 'Sent to firstmate - in progress' "served layer lacks the sent-state copy"
  assert_contains "$RESP" 'Previously approved' "served layer lacks the previously-approved copy"
  # Claiming marks the model stale, and the running service regenerates promptly.
  rm -f "$HOME_DIR/state/dash-inbox/.model-stale"
  printf '{"schema":"fm-dash-command.v1","id":"CAP-06","prompt":"x","requested_at":"%s","dashboard_generated":"2026-07-28T10:00:00Z"}\n' \
    "$(node -e 'console.log(new Date().toISOString())')" > "$HOME_DIR/state/dash-inbox/2-ack-CAP-06.json"
  FM_HOME="$HOME_DIR" "$INBOX_SH" claim >/dev/null || fail "ack-claim failed"
  [ -f "$HOME_DIR/state/dash-inbox/.model-stale" ] || fail "claim did not mark the model stale"
  stop_server
  export FM_DASH_STALE_POLL_MS=100
  start_server "$HOME_DIR" "$PORT" "--snapshot $SNAPSHOT --environment $ENVIRONMENT"
  unset FM_DASH_STALE_POLL_MS
  tries=0
  while [ -e "$HOME_DIR/state/dash-inbox/.model-stale" ] || [ -e "$HOME_DIR/state/dash-inbox/.model-stale.refreshing" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "the stale marker did not trigger a prompt regeneration"
    sleep 0.1
  done
  # A newly enqueued click acknowledges immediately as pending, and the
  # acknowledgment persists across reloads because it reads the durable record.
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"CAP-06"}'
  [ "$REQ_STATUS" = 200 ] || fail "re-dispatch after claim failed (got $REQ_STATUS: $RESP)"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"acks":{"CAP-06":{"status":"pending"' "pending click does not acknowledge as sent"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"acks":{"CAP-06":{"status":"pending"' "pending acknowledgment did not survive a reload"
  FM_HOME="$HOME_DIR" "$INBOX_SH" claim >/dev/null || fail "cleanup claim failed"
  # A regeneration that re-emits the same stable action ID within the recent
  # window renders previously approved, not a bare Approve button.
  # JavaScript template literals are intentionally single-quoted for the shell.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const archive = process.argv[1];
    for (const name of fs.readdirSync(archive)) {
      if (!name.endsWith(".json")) continue;
      const file = path.join(archive, name);
      const record = JSON.parse(fs.readFileSync(file, "utf8"));
      record.dashboard_generated = "a-previous-generation";
      record.requested_at = new Date(Date.now() - 30 * 60000).toISOString();
      fs.writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
    }
  ' "$HOME_DIR/state/dash-inbox/archive"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"acks":{"CAP-06":{"status":"prior"' "a recent click behind a regenerated model lost its acknowledgment"
  # Beyond the window the same stable ID is a genuinely new context: fresh.
  # JavaScript template literals are intentionally single-quoted for the shell.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const archive = process.argv[1];
    for (const name of fs.readdirSync(archive)) {
      if (!name.endsWith(".json")) continue;
      const file = path.join(archive, name);
      const record = JSON.parse(fs.readFileSync(file, "utf8"));
      record.requested_at = new Date(Date.now() - 10 * 3600000).toISOString();
      fs.writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
    }
  ' "$HOME_DIR/state/dash-inbox/archive"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"acks":{}' "an old click outside the window still suppressed a fresh action"
  # A pending decision answer acknowledges in its detail view and on its
  # de-anonymized reference chip; a different decision stays fresh.
  ref=$(ref_for "decision/main/active-task/runtime-policy") || fail "refs sidecar does not map the decision"
  detail_ref=$(ref_for "decision/main/active-task/rollout-policy") || fail "refs sidecar does not map the second decision"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" "{\"ref\":\"$ref\",\"option\":0}"
  [ "$REQ_STATUS" = 200 ] || fail "decision approval failed (got $REQ_STATUS: $RESP)"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$ref" "$CAPTAIN"
  assert_contains "$RESP" '"ack":{"status":"pending"' "an approved decision still renders as undecided in its detail view"
  req GET "http://127.0.0.1:$PORT/api/detail?ref=$detail_ref" "$CAPTAIN"
  assert_contains "$RESP" '"ack":null' "a genuinely different decision inherited another decision's acknowledgment"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"label":"active-task/runtime-policy","ack":{"status":"pending"' "the decision reference chip does not carry its acknowledgment"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' -delete
  # Idea suggestions stay additive: they never acknowledge or suppress a verdict.
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-02","verdict":"suggest","suggestion":"only weekdays"}'
  [ "$REQ_STATUS" = 200 ] || fail "idea suggestion failed (got $REQ_STATUS: $RESP)"
  req GET "http://127.0.0.1:$PORT/api/detail?idea=IDEA-02" "$CAPTAIN"
  assert_contains "$RESP" '"ack":null' "an additive suggestion wrongly acknowledged the idea verdict"
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' -delete
  rm -f "$HOME_DIR/state/dash-inbox/.model-stale"
  # The acknowledgment layer only reads: fleet state is untouched.
  [ "$before_backlog" = "$(cat "$HOME_DIR/data/backlog.md")" ] || fail "serving acknowledgments mutated the backlog"
  stop_server
  cat > "$HOME_DIR/config/dash.json" <<EOF
{"port": $PORT, "captain_logins": ["$CAPTAIN"], "auto_refresh_seconds": 3600}
EOF
  rm -f "$HOME_DIR/state/dash-inbox/.model-stale" "$TMP_ROOT/stale-snapshot.fifo"
  mkfifo "$TMP_ROOT/stale-snapshot.fifo"
  export FM_DASH_STALE_POLL_MS=50
  start_server "$HOME_DIR" "$PORT" "--snapshot $TMP_ROOT/stale-snapshot.fifo --environment $ENVIRONMENT"
  unset FM_DASH_STALE_POLL_MS
  touch "$HOME_DIR/state/dash-inbox/.model-stale"
  marker_refreshes=0
  tries=0
  while [ "$marker_refreshes" -lt 1 ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "the stale marker did not start a regeneration"
    sleep 0.05
    marker_refreshes=$(grep -c 'claimed captain commands marked the model stale' "$TMP_ROOT/serve.log" 2>/dev/null || true)
  done
  [ -f "$HOME_DIR/state/dash-inbox/.model-stale.refreshing" ] || fail "the stale refresh did not atomically claim its marker"
  [ ! -e "$HOME_DIR/state/dash-inbox/.model-stale" ] || fail "the live stale marker remained aliased to the in-progress refresh"
  printf '{"schema":"fm-dash-command.v1","id":"CAP-06","prompt":"x","requested_at":"%s","dashboard_generated":"2026-07-28T10:00:00Z"}\n' \
    "$(node -e 'console.log(new Date().toISOString())')" > "$HOME_DIR/state/dash-inbox/3-race-CAP-06.json"
  FM_HOME="$HOME_DIR" "$INBOX_SH" claim >/dev/null || fail "race claim failed"
  [ -f "$HOME_DIR/state/dash-inbox/.model-stale" ] || fail "a claim during refresh did not create a distinct live marker"
  cp "$SNAPSHOT" "$TMP_ROOT/stale-snapshot.fifo"
  marker_refreshes=0
  tries=0
  while [ "$marker_refreshes" -lt 2 ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "a claim during refresh did not schedule a post-claim regeneration"
    sleep 0.05
    marker_refreshes=$(grep -c 'claimed captain commands marked the model stale' "$TMP_ROOT/serve.log" 2>/dev/null || true)
  done
  cp "$SNAPSHOT" "$TMP_ROOT/stale-snapshot.fifo"
  tries=0
  while [ -e "$HOME_DIR/state/dash-inbox/.model-stale" ] || [ -e "$HOME_DIR/state/dash-inbox/.model-stale.refreshing" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "post-claim regeneration did not consume the unchanged marker"
    sleep 0.05
  done
  pass "clicks acknowledge instantly, survive reloads and claims, and re-emitted recent actions stay acknowledged"
}

test_read_only_mode_fails_safe() {
  stop_server
  cat > "$HOME_DIR/config/dash.json" <<EOF
{"port": $PORT, "captain_logins": ["$CAPTAIN"], "read_only": true, "auto_refresh_seconds": 0}
EOF
  start_server "$HOME_DIR" "$PORT"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "read-only page read failed (got $REQ_STATUS)"
  assert_contains "$RESP" '"readOnly":true' "read-only page does not declare read-only mode"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"id":"CAP-06"}'
  [ "$REQ_STATUS" = 403 ] || fail "read-only dispatch was not refused (got $REQ_STATUS)"
  req POST "http://127.0.0.1:$PORT/api/dispatch" "$CAPTAIN" '{"idea":"IDEA-01","verdict":"approve"}'
  [ "$REQ_STATUS" = 403 ] || fail "read-only idea verdict was not refused (got $REQ_STATUS)"
  stop_server
  write_config "$HOME_DIR" "$PORT"
  pass "read-only mode serves the page and refuses every mutation"
}

test_check_shim_wakes_only_when_pending() {
  local out pending_record
  FM_HOME="$HOME_DIR" "$INSTALL_SH" write-check >/dev/null || fail "write-check failed"
  [ -f "$HOME_DIR/state/fm-dash.check-trust" ] || fail "write-check did not register the check"
  out=$(sh "$HOME_DIR/state/fm-dash.check.sh")
  [ -z "$out" ] || fail "check shim woke with an empty inbox: $out"
  pending_record="$HOME_DIR/state/dash-inbox/1-test-CAP-06.json"
  printf '{"schema":"fm-dash-command.v1","id":"CAP-06","prompt":"x"}\n' > "$pending_record"
  out=$(sh "$HOME_DIR/state/fm-dash.check.sh")
  assert_contains "$out" '1 captain command(s) pending' "check shim did not report the pending command"
  assert_contains "$out" 'fm-dash-inbox.sh claim' "check shim does not name the claim helper"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "check shim printed more than one line"
  FM_HOME="$HOME_DIR" "$INSTALL_SH" unregister-check >/dev/null || fail "unregister-check failed"
  [ ! -e "$HOME_DIR/state/fm-dash.check.sh" ] || fail "unregister-check left the watcher check installed"
  [ ! -e "$HOME_DIR/state/fm-dash.check-trust" ] || fail "unregister-check left the watcher trust registration installed"
  [ -f "$pending_record" ] || fail "unregister-check removed a pending inbox record"
  rm -f "$pending_record"
  pass "watcher registration follows writable mode without deleting pending commands"
}

test_installer_plist_and_funnel_stance() {
  local escaped_home funnel_check plist
  plist=$(FM_HOME="$HOME_DIR" "$INSTALL_SH" print-plist) || fail "print-plist failed"
  assert_contains "$plist" 'io.firstmate.dashboard.' "plist lacks the per-home label"
  assert_contains "$plist" 'fm-dash-serve.mjs' "plist does not run the dashboard service"
  assert_contains "$plist" '<key>KeepAlive</key><true/>' "plist does not keep the service alive"
  assert_contains "$plist" '<key>RunAtLoad</key><true/>' "plist does not start at load"
  assert_contains "$plist" "<string>$HOME_DIR</string>" "plist does not pin FM_HOME"
  printf '%s' "$plist" | grep -qi funnel && fail "plist mentions funnel"
  grep -n 'tailscale funnel' "$INSTALL_SH" && fail "installer invokes tailscale funnel"
  assert_grep 'assert_no_funnel' "$INSTALL_SH" "installer does not verify funnel is off"
  assert_grep 'never enables Funnel' "$INSTALL_SH" "installer does not declare the funnel boundary"
  funnel_check=$(sed -n '/^assert_no_funnel()/,/^write_config_file()/p' "$INSTALL_SH")
  assert_contains "$funnel_check" 'unsupported tailscale serve status schema' "Funnel verification does not reject unexpected schemas"
  assert_contains "$funnel_check" 'could not verify Funnel state' "Funnel verification does not report unreadable status"
  assert_contains "$funnel_check" 'process.exit(1)' "Funnel verification does not fail closed"
  assert_contains "$(sed -n '/if ! assert_no_funnel/,/fi/p' "$INSTALL_SH")" 'fail_install' "failed Funnel verification does not enter transactional rollback"
  # The single-quoted assertion is intentionally literal.
  # shellcheck disable=SC2016
  assert_contains "$(sed -n '/^rollback_install()/,/^fail_install()/p' "$INSTALL_SH")" 'disable_serve_port "$TX_NEW_SERVE_PORT"' "transactional rollback does not tear down the replacement mapping"
  assert_contains "$(sed -n '/^cmd_install()/,/^cmd_uninstall()/p' "$INSTALL_SH")" 'unregister_check' "read-only install does not unregister a prior writable watcher"
  assert_contains "$(sed -n '/^cmd_uninstall()/,/^cmd_status()/p' "$INSTALL_SH")" 'unregister_check' "uninstall does not unregister the watcher"
  escaped_home="$HOME_DIR/xml & < >"
  plist=$(FM_HOME="$escaped_home" FM_ROOT_OVERRIDE="$HOME_DIR/root & < >" "$INSTALL_SH" print-plist) || fail "print-plist with XML metacharacters failed"
  assert_contains "$plist" "$HOME_DIR/xml &amp; &lt; &gt;" "plist did not XML-escape FM_HOME"
  assert_contains "$plist" "$HOME_DIR/root &amp; &lt; &gt;/bin/fm-dash-serve.mjs" "plist did not XML-escape the executable path"
  pass "the launchd agent survives reboots and the installer is structurally funnel-free"
}

test_installer_tracks_custom_serve_port() {
  local fake_bin install_home launch_home launchctl_log launchctl_state occupied_error prior_config real_mv tailscale_log tailscale_state uninstall_output
  fake_bin="$TMP_ROOT/fake-bin"
  install_home="$TMP_ROOT/install-home"
  launch_home="$TMP_ROOT/launch-home"
  launchctl_log="$TMP_ROOT/launchctl.log"
  launchctl_state="$TMP_ROOT/launchctl.state"
  prior_config="$TMP_ROOT/prior-dash.json"
  real_mv=$(command -v mv)
  tailscale_log="$TMP_ROOT/tailscale.log"
  tailscale_state="$TMP_ROOT/tailscale.state"
  mkdir -p "$fake_bin" "$install_home" "$launch_home"
  cat > "$fake_bin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
  cat > "$fake_bin/launchctl" <<'EOF'
#!/bin/sh
case "$1" in
  print)
    [ -f "$LAUNCHCTL_STATE" ] && [ "$(cat "$LAUNCHCTL_STATE")" = loaded ]
    ;;
  bootout)
    : > "$LAUNCHCTL_STATE"
    printf 'bootout\n' >> "$LAUNCHCTL_LOG"
    ;;
  bootstrap)
    if [ -n "${LAUNCHCTL_FAIL_ONCE:-}" ] && [ ! -e "$LAUNCHCTL_FAIL_ONCE" ]; then
      : > "$LAUNCHCTL_FAIL_ONCE"
      printf 'bootstrap-failed\n' >> "$LAUNCHCTL_LOG"
      exit 1
    fi
    printf 'loaded\n' > "$LAUNCHCTL_STATE"
    printf 'bootstrap\n' >> "$LAUNCHCTL_LOG"
    ;;
  kickstart)
    printf 'kickstart\n' >> "$LAUNCHCTL_LOG"
    ;;
  *) exit 1 ;;
esac
EOF
  cat > "$fake_bin/mv" <<'EOF'
#!/bin/sh
last=""
for arg in "$@"; do last=$arg; done
if [ -n "${MV_FAIL_DEST:-}" ] && [ "$last" = "$MV_FAIL_DEST" ] && [ ! -e "$MV_FAIL_MARKER" ]; then
  : > "$MV_FAIL_MARKER"
  exit 1
fi
exec "$REAL_MV" "$@"
EOF
  cat > "$fake_bin/tailscale" <<'EOF'
#!/bin/sh
if [ "$1" = status ] && [ "${2:-}" = --json ]; then
  printf '%s\n' '{"Self":{"UserID":1,"DNSName":"dash.tail.ts.net."},"User":{"1":{"LoginName":"captain@example.com"}}}'
elif [ "$1" = serve ] && [ "${2:-}" = status ] && [ "${3:-}" = --json ]; then
  if [ "${TAILSCALE_INVALID_SERVE_STATUS:-}" = 1 ]; then
    printf '{\n'
    exit 0
  fi
  node -e '
    const fs = require("node:fs");
    const state = fs.existsSync(process.argv[1]) ? fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean) : [];
    const payload = { TCP: {}, Web: {}, AllowFunnel: {} };
    for (const record of state) {
      const [port, target, shape] = record.split("|");
      const hostport = "dash.tail.ts.net:" + port;
      payload.TCP[port] = { HTTPS: true };
      payload.Web[hostport] = shape === "complex"
        ? { Handlers: { "/api": { Proxy: target }, "/": { Text: "foreign service" } } }
        : { Handlers: { "/": { Proxy: target } } };
      payload.AllowFunnel[hostport] = process.argv[2] === port;
    }
    console.log(JSON.stringify(payload));
  ' "$TAILSCALE_STATE" "${TAILSCALE_FUNNEL_PORT:-}"
elif [ "$1" = serve ] && [ "${2:-}" = --bg ]; then
  port=${3#--https=}
  if [ "${TAILSCALE_FAIL_MAP_PORT:-}" = "$port" ]; then
    printf 'map-failed %s\n' "$port" >> "$TAILSCALE_LOG"
    exit 1
  fi
  awk -F '|' -v port="$port" '$1 != port' "$TAILSCALE_STATE" > "$TAILSCALE_STATE.next"
  printf '%s|%s\n' "$port" "$4" >> "$TAILSCALE_STATE.next"
  mv "$TAILSCALE_STATE.next" "$TAILSCALE_STATE"
  printf 'map %s\n' "$port" >> "$TAILSCALE_LOG"
elif [ "$1" = serve ] && [ "${2#--https=}" != "$2" ] && [ "${3:-}" = off ]; then
  port=${2#--https=}
  if [ "${TAILSCALE_FAIL_OFF_PORT:-}" = "$port" ] && [ ! -e "$TAILSCALE_FAIL_OFF_MARKER" ]; then
    : > "$TAILSCALE_FAIL_OFF_MARKER"
    printf 'off-failed %s\n' "$port" >> "$TAILSCALE_LOG"
    exit 1
  fi
  printf 'off %s\n' "$port" >> "$TAILSCALE_LOG"
  awk -F '|' -v port="$port" '$1 != port' "$TAILSCALE_STATE" > "$TAILSCALE_STATE.next"
  mv "$TAILSCALE_STATE.next" "$TAILSCALE_STATE"
else
  exit 1
fi
EOF
  chmod 700 "$fake_bin/uname" "$fake_bin/launchctl" "$fake_bin/mv" "$fake_bin/tailscale"
  : > "$tailscale_state"
  HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --read-only --port 18847 --serve-port 19443 --captain "$CAPTAIN" >/dev/null \
    || fail "custom-port install failed"
  node -e 'const c=require(process.argv[1]); if(c.serve_port !== 19443) process.exit(1)' "$install_home/config/dash.json" \
    || fail "install did not persist the custom serve port"
  cp "$install_home/config/dash.json" "$prior_config"
  : > "$tailscale_log"
  printf '%s\n' '20553|http://127.0.0.1:29999' >> "$tailscale_state"
  occupied_error=$(HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --read-only --port 18847 --serve-port 20553 --captain "$CAPTAIN" 2>&1) && fail "occupied replacement port was reported as installed"
  assert_contains "$occupied_error" 'requested dashboard serve port 20553 carries a non-dashboard mapping' "occupied replacement port refusal was unclear"
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "occupied replacement port mutated the dashboard config"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "occupied replacement port mutated the launchd service"
  assert_no_grep 'map 20553' "$tailscale_log" "occupied replacement port was overwritten"
  assert_no_grep 'off 20553' "$tailscale_log" "occupied replacement port was removed"
  HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$fake_bin/tailscale" serve --https=20553 off >/dev/null || fail "could not remove the foreign mapping fixture"
  : > "$tailscale_log"
  if HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" TAILSCALE_FAIL_MAP_PORT=19663 PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --port 18848 --serve-port 19663 --captain "other@example.com" >/dev/null 2>&1; then
    fail "failed replacement mapping was reported as installed"
  fi
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "failed replacement mapping did not restore the full prior config"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "failed replacement mapping did not restore the prior launchd service"
  assert_grep 'map 19443' "$tailscale_log" "failed replacement mapping did not restore the prior mapping"
  assert_no_grep 'off 19443' "$tailscale_log" "failed replacement mapping removed the recorded active mapping"
  : > "$tailscale_log"
  if HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" TAILSCALE_FUNNEL_PORT=19664 PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --port 18848 --serve-port 19664 --captain "other@example.com" >/dev/null 2>&1; then
    fail "Funnel-exposed replacement mapping was reported as installed"
  fi
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "failed Funnel verification did not restore the full prior config"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "failed Funnel verification did not restore the prior launchd service"
  assert_grep 'off 19664' "$tailscale_log" "failed Funnel verification did not remove the replacement mapping"
  assert_grep 'map 19443' "$tailscale_log" "failed Funnel verification did not restore the prior mapping"
  assert_no_grep 'off 19443' "$tailscale_log" "failed Funnel verification removed the recorded active mapping"
  : > "$tailscale_log"
  if HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_FAIL_ONCE="$TMP_ROOT/bootstrap-failed" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --port 18848 --serve-port 19665 --captain "other@example.com" >/dev/null 2>&1; then
    fail "failed launchd replacement was reported as installed"
  fi
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "failed launchd replacement did not restore the full prior config"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "failed launchd replacement did not restore the prior service"
  assert_grep 'map 19443' "$tailscale_log" "failed launchd replacement did not restore the prior mapping"
  : > "$tailscale_log"
  if HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" MV_FAIL_DEST="$install_home/config/dash.json" MV_FAIL_MARKER="$TMP_ROOT/config-mv-failed" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --port 18848 --serve-port 19666 --captain "other@example.com" >/dev/null 2>&1; then
    fail "failed config activation was reported as installed"
  fi
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "failed config activation did not restore the full prior config"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "failed config activation did not restore the prior service"
  assert_grep 'map 19443' "$tailscale_log" "failed config activation did not restore the prior mapping"
  : > "$tailscale_log"
  if HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_FAIL_OFF_MARKER="$TMP_ROOT/off-failed" TAILSCALE_FAIL_OFF_PORT=19443 TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --port 18848 --serve-port 19667 --captain "other@example.com" >/dev/null 2>&1; then
    fail "failed old-mapping teardown was reported as installed"
  fi
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "failed old-mapping teardown did not restore the full prior config"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "failed old-mapping teardown did not restore the prior service"
  assert_grep 'off 19667' "$tailscale_log" "failed old-mapping teardown did not remove the replacement mapping"
  assert_grep 'map 19443' "$tailscale_log" "failed old-mapping teardown did not restore the prior mapping"
  : > "$tailscale_log"
  HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --read-only --port 18847 --serve-port 19553 --captain "$CAPTAIN" >/dev/null \
    || fail "custom-port replacement install failed"
  assert_grep 'off 19443' "$tailscale_log" "port-change install did not remove the recorded previous mapping"
  node -e 'const c=require(process.argv[1]); if(c.serve_port !== 19553) process.exit(1)' "$install_home/config/dash.json" \
    || fail "replacement install did not persist the active serve port"
  : > "$tailscale_log"
  uninstall_output=$(HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_INVALID_SERVE_STATUS=1 TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" uninstall 2>&1) && fail "uninstall accepted unreadable serve status"
  assert_contains "$uninstall_output" 'could not inspect or remove the dashboard mapping for port 19553' "uninstall did not fail clearly on unreadable serve status"
  [ "$(cat "$launchctl_state")" = loaded ] || fail "unreadable serve status removed the launchd service"
  assert_no_grep 'off 19553' "$tailscale_log" "unreadable serve status removed the dashboard mapping"
  : > "$tailscale_log"
  HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" uninstall >/dev/null || fail "plain uninstall failed"
  assert_grep 'off 19553' "$tailscale_log" "plain uninstall did not remove the recorded active mapping"
  printf '%s\n' '19553|http://127.0.0.1:29998' '20554|http://127.0.0.1:29999|complex' >> "$tailscale_state"
  : > "$tailscale_log"
  uninstall_output=$(HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" uninstall --serve-port 20554) || fail "repeated uninstall with foreign mappings failed"
  assert_contains "$uninstall_output" 'kept: serve port 20554 carries a non-dashboard mapping' "uninstall did not report the foreign requested mapping"
  assert_contains "$uninstall_output" 'kept: serve port 19553 carries a non-dashboard mapping' "uninstall did not report the foreign configured mapping"
  assert_no_grep 'off 20554' "$tailscale_log" "uninstall removed a foreign requested mapping"
  assert_no_grep 'off 19553' "$tailscale_log" "uninstall removed a foreign configured mapping"
  assert_grep '19553|http://127.0.0.1:29998' "$tailscale_state" "uninstall mutated the foreign configured mapping"
  assert_grep '20554|http://127.0.0.1:29999|complex' "$tailscale_state" "uninstall mutated the complex foreign requested mapping"
  HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$fake_bin/tailscale" serve --https=19553 off >/dev/null || fail "could not remove the configured foreign mapping fixture"
  HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" PATH="$fake_bin:$PATH" \
    "$fake_bin/tailscale" serve --https=20554 off >/dev/null || fail "could not remove the requested foreign mapping fixture"
  cp "$install_home/config/dash.json" "$prior_config"
  : > "$tailscale_log"
  if HOME="$launch_home" FM_HOME="$install_home" LAUNCHCTL_LOG="$launchctl_log" LAUNCHCTL_STATE="$launchctl_state" REAL_MV="$real_mv" TAILSCALE_LOG="$tailscale_log" TAILSCALE_STATE="$tailscale_state" TAILSCALE_FAIL_MAP_PORT=19668 PATH="$fake_bin:$PATH" \
    "$INSTALL_SH" install --read-only --port 18848 --serve-port 19668 --captain "$CAPTAIN" >/dev/null 2>&1; then
    fail "failed reinstall after uninstall was reported as installed"
  fi
  cmp -s "$prior_config" "$install_home/config/dash.json" || fail "failed reinstall after uninstall did not restore the retained config"
  [ ! -s "$launchctl_state" ] || fail "failed reinstall after uninstall restored an absent launchd service"
  [ ! -s "$tailscale_state" ] || fail "failed reinstall after uninstall recreated an absent mapping"
  assert_no_grep 'map 19553' "$tailscale_log" "failed reinstall after uninstall recreated the removed prior mapping"
  pass "custom serve ports persist and old mappings are removed"
}

test_launchd_env_and_degraded_render_selfcheck() {
  local plist rows non_worker_rows
  stop_server
  start_server "$HOME_DIR" "$PORT"
  plist=$(FM_HOME="$HOME_DIR" "$INSTALL_SH" print-plist) || fail "print-plist failed"
  assert_contains "$plist" '<key>PATH</key>' "plist does not pin the installing PATH for launchd (states degrade to unknown without it)"
  assert_contains "$plist" "$(dirname "$(command -v node)")" "plist PATH does not carry the node tool directory"
  cp "$HOME_DIR/data/capacity-dashboard.html" "$TMP_ROOT/dashboard.bak"
  rows=""
  non_worker_rows=""
  for _ in 1 2 3 4; do
    rows="$rows<li class=\"mrow\"><span class=\"mreason\">Authoritative current state: unknown</span></li>"
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    non_worker_rows="$non_worker_rows<li class=\"mrow\"><span class=\"mreason\">Queued backlog item</span></li>"
  done
  printf '%s' "$(sed "s|</body>|$rows$non_worker_rows</body>|" "$TMP_ROOT/dashboard.bak")" > "$HOME_DIR/data/capacity-dashboard.html"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'RENDER DEGRADED' "a mostly-unknown render is presented as truth instead of loudly degraded"
  assert_contains "$RESP" 'state reader could not resolve a current source' "degraded banner must name unresolved state sources"
  assert_contains "$RESP" 'missing tools' "degraded banner must still mention missing tools without blaming only PATH"
  printf '%s' "$(sed "s|</body>|<li class=\"mrow\"><span class=\"mreason\">Authoritative current state: unknown</span></li>$non_worker_rows</body>|" "$TMP_ROOT/dashboard.bak")" > "$HOME_DIR/data/capacity-dashboard.html"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'RENDER DEGRADED' "a one-worker all-unknown fleet is presented as healthy"
  sed 's/Authoritative current state:/Observed worker state:/g' "$TMP_ROOT/dashboard.bak" > "$HOME_DIR/data/capacity-dashboard.html"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  case "$RESP" in *'"degraded":true'*) fail "an empty authoritative worker set is marked degraded" ;; esac
  cp "$TMP_ROOT/dashboard.bak" "$HOME_DIR/data/capacity-dashboard.html"
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  case "$RESP" in *'"degraded":true'*) fail "a healthy render is marked degraded" ;; esac
  pass "launchd env is pinned and a mostly-unknown render is loudly marked degraded"
}

test_served_page_has_zero_copy_affordances() {
  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" 'copyButton.replaceWith(send)' "dispatch does not replace the copy button"
  assert_contains "$RESP" 'copyButton.remove()' "read-only and non-action copy buttons are not removed"
  case "$RESP" in *"copyButton.after(send)"*) fail "copy buttons are supplemented instead of replaced" ;; esac
  pass "every copy-prompt affordance on the served page is replaced by direct dispatch"
}

test_service_contract_docs_and_ownership() {
  assert_present "$ROOT/docs/dashboard-service.md" "dashboard service doc is missing"
  assert_grep 'dash-inbox' "$ROOT/docs/dashboard-service.md" "service doc omits the inbound channel"
  assert_grep 'fm-dash' "$ROOT/AGENTS.md" "AGENTS.md lacks the dashboard command wake trigger"
  assert_grep 'dash-inbox' "$ROOT/AGENTS.md" "AGENTS.md state map lacks dash-inbox"
  assert_grep 'config/dash.json' "$ROOT/.gitignore" "config/dash.json is not gitignored"
  assert_grep 'dashboard service' "$ROOT/.agents/skills/capacity/SKILL.md" "capacity skill does not own dashboard command handling"
  assert_grep 'never Funnel' "$ROOT/.agents/skills/capacity/SKILL.md" "capacity skill does not carry the funnel boundary"
  assert_grep 'data/<origin>/decisions/<key>.md' "$ROOT/docs/dashboard-service.md" "service doc does not own the origin-qualified decision-options format"
  assert_grep 'hold --options-file' "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "decision lifecycle does not own options-document filing"
  # The single-quoted assertion is intentionally literal.
  # shellcheck disable=SC2016
  assert_grep 'bounded read-only excerpt from a resolved `data/<id>/report.md`' "$ROOT/docs/dashboard-service.md" "service doc omits the sanctioned secondmate report exception"
  assert_grep 'bounded home snapshot reads that exact structured record' "$ROOT/docs/dashboard-service.md" "service doc omits supervisor decision projection"
  assert_grep 'Secondmate briefs, metadata, status tails, and chat remain prohibited' "$ROOT/docs/dashboard-service.md" "service doc broadens secondmate detail ingestion"
  assert_grep 'only free text accepted anywhere is bounded captain-authored content' "$ROOT/docs/dashboard-service.md" "service doc omits the bounded free-text boundary"
  assert_grep 'at-least-once' "$INBOX_SH" "inbox consumer omits its delivery contract"
  pass "the service is documented and wired into the operating contract"
}

test_identity_fails_closed
test_browser_posts_require_same_origin
test_served_page_wears_dashboard_with_interactive_layer
test_subscription_usage_panel
test_inline_config_is_script_safe
test_refs_sidecar_and_rich_work_item_detail
test_decision_detail_options_and_validated_approval
test_supervisor_decision_detail_uses_bounded_projection
test_decision_answers_are_qualified_by_home_and_origin
test_stale_refs_are_disabled
test_idea_pitch_and_verdicts
test_parking_lot_enrichment_and_unpark
test_recurring_enrichment_and_run_now
test_your_go_controls_for_captain_awaiting_items
test_dispatch_writes_one_durable_record
test_dispatch_refuses_unknown_and_uncurrent_actions
test_refresh_reruns_producer_server_side
test_inbox_list_claim_and_archive
test_click_ack_and_handled_states
test_read_only_mode_fails_safe
test_check_shim_wakes_only_when_pending
test_installer_plist_and_funnel_stance
test_installer_tracks_custom_serve_port
test_launchd_env_and_degraded_render_selfcheck
test_served_page_has_zero_copy_affordances
test_service_contract_docs_and_ownership

echo "fm-dash tests passed"
