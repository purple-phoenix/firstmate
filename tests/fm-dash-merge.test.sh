#!/usr/bin/env bash
# Behavior tests for the exact dashboard PR merge approval flow:
# bin/fm-dash-pr-evidence.mjs (read-only typed evidence), the dashboard
# service's /api/merge/preview and /api/merge/approve routes (eligibility,
# echo cross-check, typed bound records), and bin/fm-dash-merge.sh (every
# binding validation, one-time crash-safe nonce consumption, independent live
# recheck, and delegation to the guarded merge owner). No real forge, PR, or
# merge is ever touched: gh, the evidence probe, and the merge owner are
# fixture fakes, and the click-through path runs end to end against them.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVE="$ROOT/bin/fm-dash-serve.mjs"
INBOX_SH="$ROOT/bin/fm-dash-inbox.sh"
MERGE_SH="$ROOT/bin/fm-dash-merge.sh"
EVIDENCE="$ROOT/bin/fm-dash-pr-evidence.mjs"
TMP_ROOT=$(fm_test_tmproot fm-dash-merge)

command -v node >/dev/null 2>&1 || { echo "skip: node is required"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl is required"; exit 0; }

CAPTAIN="captain@example.com"
PR_URL="https://github.com/example/repo/pull/12"
HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SERVER_PID=""
BROWSER_PROXY_PID=""
BROWSER_PID=""

cleanup() {
  [ -z "$BROWSER_PID" ] || kill "$BROWSER_PID" 2>/dev/null || true
  [ -z "$BROWSER_PROXY_PID" ] || kill "$BROWSER_PROXY_PID" 2>/dev/null || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

find_chrome() {
  local candidate
  for candidate in \
    "${FM_CHROME_BIN:-}" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    google-chrome chromium chromium-browser; do
    [ -n "$candidate" ] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"

GH_FIXTURE="$TMP_ROOT/gh-fixture.json"
export GH_FIXTURE
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/fake-gh" <<'SH'
#!/bin/sh
[ -n "${GH_FIXTURE:-}" ] && [ -f "$GH_FIXTURE" ] || exit 1
[ "${GH_FAIL:-}" != 1 ] || exit 1
cat "$GH_FIXTURE"
SH
chmod 700 "$FAKE_BIN/fake-gh"
cat > "$FAKE_BIN/fake-evidence" <<'SH'
#!/bin/sh
[ -n "${EVIDENCE_FIXTURE:-}" ] && [ -f "$EVIDENCE_FIXTURE" ] || exit 1
cat "$EVIDENCE_FIXTURE"
SH
chmod 700 "$FAKE_BIN/fake-evidence"
MERGE_LOG="$TMP_ROOT/merge-owner.log"
export MERGE_LOG
cat > "$FAKE_BIN/fake-merge-owner" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MERGE_LOG"
exit "${MERGE_RC:-0}"
SH
chmod 700 "$FAKE_BIN/fake-merge-owner"

write_meta() {
  printf 'window=fm-ready-safe\nworktree=%s\nproject=%s\nmode=no-mistakes\nrisk=low\npr=%s\n' \
    "$TMP_ROOT/wt" "$TMP_ROOT/project" "${1:-$PR_URL}" > "$HOME_DIR/state/ready-safe.meta"
  chmod 600 "$HOME_DIR/state/ready-safe.meta"
}
write_meta

# Fixture gh payloads. statusCheckRollup mixes a CheckRun and a legacy
# StatusContext so both shapes are exercised.
gh_payload() {
  local state=$1 draft=$2 mergeable=$3 head=$4 check_status=$5 check_conclusion=$6 context_state=$7
  cat > "$GH_FIXTURE" <<EOF
{
  "url": "$PR_URL",
  "number": 12,
  "title": "feat: add exact merge review",
  "baseRefName": "main",
  "state": "$state",
  "isDraft": $draft,
  "mergeable": "$mergeable",
  "headRefOid": "$head",
  "statusCheckRollup": [
    {"name": "no-mistakes / validate", "status": "$check_status", "conclusion": "$check_conclusion"},
    {"context": "ci/legacy", "state": "$context_state"}
  ]
}
EOF
}

DASHBOARD="$HOME_DIR/data/capacity-dashboard.html"
REFS="$HOME_DIR/state/dash-refs.json"
GENERATED="2026-08-04 10:00 UTC"
# The fixture mirrors the producer's markup contract: the generated stamp, the
# dashboard-nav with hash routing, data-dashboard-page sections, and the
# data-your-go anchors the serve layer keys on.
cat > "$DASHBOARD" <<EOF
<!doctype html><html><body>
<main id="main">
<nav class="dashboard-nav" aria-label="Dashboard pages"><a href="#brief" data-dashboard-link="brief" aria-current="page">Brief</a></nav>
<section class="dashboard-page band" id="brief" data-dashboard-page="brief">
<p class="kicker">One fleet reading · generated $GENERATED</p>
<ul>
<li data-your-go-ref="item-01" data-your-go-kind="approval"><span class="why">ready work awaiting your approval</span></li>
<li data-your-go-ref="item-02" data-your-go-kind="review"><span class="why">captain gate</span></li>
</ul>
</section>
</main>
<script>
const showDashboardPage = () => {
  const requested = location.hash.slice(1);
  const target = document.querySelector('[data-dashboard-page="' + requested + '"]') ? requested : "brief";
  document.querySelectorAll("[data-dashboard-page]").forEach((section) => { section.hidden = section.dataset.dashboardPage !== target; });
  document.querySelectorAll("[data-dashboard-link]").forEach((link) => {
    if (link.dataset.dashboardLink === target) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
};
window.addEventListener("hashchange", showDashboardPage);
showDashboardPage();
</script>
</body></html>
EOF
cat > "$REFS" <<EOF
{"schema":"fm-capacity-refs.v1","generated":"$GENERATED","refs":{
  "item-01":{"kind":"item","value":"main/ready-safe"},
  "item-02":{"kind":"item","value":"main/other-task"}
}}
EOF
cat > "$HOME_DIR/config/dash.json" <<EOF
{"port": 0, "captain_logins": ["$CAPTAIN"], "auto_refresh_seconds": 0}
EOF

pick_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});'
}
PORT=$(pick_port)

start_server() {
  FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" FM_DASH_MERGE_TTL_SECS="${TTL_OVERRIDE:-900}" \
    node "$SERVE" --port "$PORT" > "$TMP_ROOT/serve.log" 2>&1 &
  SERVER_PID=$!
  local tries=0
  while ! curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "service did not start; see $TMP_ROOT/serve.log"
    sleep 0.1
  done
}

REQ_STATUS=""
RESP=""
req() {
  local method=$1 url=$2 login=${3:-} body=${4:-}
  local args=(-s -o "$TMP_ROOT/resp.body" -w '%{http_code}' -X "$method")
  [ -z "$login" ] || args+=(-H "Tailscale-User-Login: $login")
  [ -z "$body" ] || args+=(-H 'content-type: application/json' -d "$body")
  REQ_STATUS=$(curl "${args[@]}" "$url")
  RESP=$(cat "$TMP_ROOT/resp.body")
}

json_field() {
  printf '%s' "$1" | node -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      const value = process.argv[1].split(".").reduce((acc, key) => acc?.[key], JSON.parse(raw));
      console.log(typeof value === "object" ? JSON.stringify(value) : String(value));
    });
  ' "$2"
}

test_evidence_probe_matrix() {
  local out
  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" available)" = true ] || fail "green PR evidence unavailable: $out"
  [ "$(json_field "$out" eligible)" = true ] || fail "green PR not eligible: $out"
  [ "$(json_field "$out" head_sha)" = "$HEAD_A" ] || fail "evidence lost the exact head"
  [ "$(json_field "$out" all_checks_green)" = true ] || fail "green checks not recognized"
  CHECKS_IDENTITY=$(json_field "$out" checks_identity)
  [ "${#CHECKS_IDENTITY}" = 64 ] || fail "checks identity is not a sha256"

  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED FAILURE SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" eligible)" = false ] || fail "red check still eligible"
  gh_payload OPEN false MERGEABLE "$HEAD_A" IN_PROGRESS "" SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" eligible)" = false ] || fail "pending check still eligible"
  gh_payload OPEN true MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" eligible)" = false ] || fail "draft PR still eligible"
  gh_payload MERGED false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" eligible)" = false ] || fail "merged PR still eligible"
  gh_payload CLOSED false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" eligible)" = false ] || fail "closed PR still eligible"
  gh_payload OPEN false CONFLICTING "$HEAD_A" COMPLETED SUCCESS SUCCESS
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" eligible)" = false ] || fail "conflicting PR still eligible"

  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" GH_FAIL=1 node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" available)" = false ] || fail "unreadable forge still available"
  write_meta "https://gitlab.example.com/group/project/-/merge_requests/9"
  out=$(FM_HOME="$HOME_DIR" node "$EVIDENCE" ready-safe)
  [ "$(json_field "$out" available)" = false ] || fail "non-GitHub PR still available"
  assert_contains "$out" "GitHub only" "GitLab refusal reason missing"
  write_meta
  out=$(FM_HOME="$HOME_DIR" node "$EVIDENCE" no-such-task)
  [ "$(json_field "$out" available)" = false ] || fail "missing task still available"
  pass "the evidence probe grants eligibility only to an open, non-draft, mergeable, all-green GitHub PR"
}

test_preview_and_approve_validation() {
  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  start_server
  req GET "http://127.0.0.1:$PORT/api/merge/preview?ref=item-01"
  [ "$REQ_STATUS" = 403 ] || fail "identity-less merge preview was not refused"
  req GET "http://127.0.0.1:$PORT/api/merge/preview?ref=item-02" "$CAPTAIN"
  [ "$REQ_STATUS" = 409 ] || fail "a non-approval row got a merge preview (got $REQ_STATUS)"
  req GET "http://127.0.0.1:$PORT/api/merge/preview?ref=item-99" "$CAPTAIN"
  [ "$REQ_STATUS" = 409 ] || fail "an unlisted ref got a merge preview"
  req GET "http://127.0.0.1:$PORT/api/merge/preview?ref=item-01" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "eligible merge preview failed (got $REQ_STATUS): $RESP"
  assert_contains "$RESP" "$HEAD_A" "preview lacks the exact head"
  assert_contains "$RESP" '"eligible":true' "preview does not report eligibility"
  local checks_identity
  checks_identity=$(json_field "$RESP" evidence.checks_identity)

  req POST "http://127.0.0.1:$PORT/api/merge/approve" "$CAPTAIN" \
    "{\"ref\":\"item-01\",\"url\":\"$PR_URL\",\"head_sha\":\"$HEAD_B\",\"checks_identity\":\"$checks_identity\",\"merge_method\":\"squash\"}"
  [ "$REQ_STATUS" = 409 ] || fail "a stale-head echo was not refused (got $REQ_STATUS)"
  assert_contains "$RESP" 'changed while you were reviewing' "stale echo refusal is not explicit"
  [ -z "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' 2>/dev/null)" ] || fail "a refused approval left a record"

  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED FAILURE SUCCESS
  req POST "http://127.0.0.1:$PORT/api/merge/approve" "$CAPTAIN" \
    "{\"ref\":\"item-01\",\"url\":\"$PR_URL\",\"head_sha\":\"$HEAD_A\",\"checks_identity\":\"$checks_identity\",\"merge_method\":\"squash\"}"
  [ "$REQ_STATUS" = 409 ] || fail "an approval against a freshly red PR was not refused"
  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS

  req POST "http://127.0.0.1:$PORT/api/merge/approve" "" \
    "{\"ref\":\"item-01\",\"url\":\"$PR_URL\",\"head_sha\":\"$HEAD_A\",\"checks_identity\":\"$checks_identity\",\"merge_method\":\"squash\"}"
  [ "$REQ_STATUS" = 403 ] || fail "identity-less approval was not refused"

  req POST "http://127.0.0.1:$PORT/api/merge/approve" "$CAPTAIN" \
    "{\"ref\":\"item-01\",\"url\":\"$PR_URL\",\"head_sha\":\"$HEAD_A\",\"checks_identity\":\"$checks_identity\",\"merge_method\":\"squash\"}"
  [ "$REQ_STATUS" = 200 ] || fail "valid approval failed (got $REQ_STATUS): $RESP"
  assert_contains "$RESP" '"status":"queued"' "valid approval did not queue"
  local record_file record
  record_file=$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' | head -1)
  [ -n "$record_file" ] || fail "approval left no durable record"
  [ "$(stat -f %Lp "$record_file" 2>/dev/null || stat -c %a "$record_file")" = 600 ] || fail "approval record is not mode 0600"
  record=$(cat "$record_file")
  assert_contains "$record" '"kind": "merge-approval"' "record lacks its kind"
  assert_contains "$record" '"task": "ready-safe"' "record lacks the task binding"
  assert_contains "$record" "\"url\": \"$PR_URL\"" "record lacks the canonical URL"
  assert_contains "$record" '"repo": "example/repo"' "record lacks the repository"
  assert_contains "$record" '"number": 12' "record lacks the PR number"
  assert_contains "$record" "\"head_sha\": \"$HEAD_A\"" "record lacks the exact head"
  assert_contains "$record" '"merge_method": "squash"' "record lacks the merge method"
  assert_contains "$record" "\"checks_identity\": \"$checks_identity\"" "record lacks the check-set identity"
  assert_contains "$record" "\"requested_by\": \"$CAPTAIN\"" "record lacks the captain login"
  assert_contains "$record" '"expires_at"' "record lacks its expiry"
  assert_contains "$record" '"nonce"' "record lacks its one-time nonce"
  assert_contains "$record" 'fm-dash-merge.sh ready-safe' "record prompt does not route to the guarded consumer"

  req POST "http://127.0.0.1:$PORT/api/merge/approve" "$CAPTAIN" \
    "{\"ref\":\"item-01\",\"url\":\"$PR_URL\",\"head_sha\":\"$HEAD_A\",\"checks_identity\":\"$checks_identity\",\"merge_method\":\"squash\"}"
  [ "$REQ_STATUS" = 200 ] || fail "duplicate approval errored"
  assert_contains "$RESP" '"status":"already-queued"' "duplicate approval was not coalesced"
  [ "$(find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' | grep -c .)" = 1 ] || fail "duplicate approval wrote a second record"

  req GET "http://127.0.0.1:$PORT/" "$CAPTAIN"
  assert_contains "$RESP" '"merge_candidate":true' "approval row is not offered the merge review"
  assert_contains "$RESP" '"merge_state"' "served page does not carry the live approval state"
  assert_contains "$RESP" 'Review merge' "served layer lacks the merge review control"
  assert_contains "$RESP" 'Approve this exact merge' "served layer lacks the explicit confirmation action"
  pass "merge preview and approval validate identity, currency, echo, and eligibility, and bind one typed record"
}

# Consume the durable record written above through the REAL inbox claim, then
# the guarded consumer with fake evidence and a fake merge owner: the full
# click-to-merge path with refusal-first semantics.
test_guarded_consumer_end_to_end() {
  local out rc nonce
  FM_HOME="$HOME_DIR" "$INBOX_SH" claim > "$TMP_ROOT/claim.out" || fail "inbox claim failed"
  assert_grep 'fm-dash-merge.sh' "$TMP_ROOT/claim.out" "claim guidance does not route merge approvals to the guarded consumer"
  # shellcheck disable=SC2016 # JavaScript template literals, not shell
  nonce=$(node -e '
    const fs = require("node:fs");
    const dir = process.argv[1];
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith(".json")) continue;
      const r = JSON.parse(fs.readFileSync(`${dir}/${name}`, "utf8"));
      if (r.kind === "merge-approval") { console.log(r.nonce); break; }
    }
  ' "$HOME_DIR/state/dash-inbox/archive")
  [ -n "$nonce" ] || fail "claimed merge approval not found in the archive"

  cat > "$TMP_ROOT/live-evidence.json" <<EOF
{"schema":"fm-dash-pr-evidence.v1","task":"ready-safe","available":true,"eligible":true,"reason":null,
 "url":"$PR_URL","repo":"example/repo","number":12,"head_sha":"$HEAD_A","checks_identity":"$CHECKS_LIVE",
 "state":"OPEN","is_draft":false,"mergeable":"MERGEABLE","all_checks_green":true,"merge_method":"squash","checks":[]}
EOF
  : > "$MERGE_LOG"
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_EVIDENCE_BIN="$FAKE_BIN/fake-evidence" FM_DASH_PR_MERGE_BIN="$FAKE_BIN/fake-merge-owner" \
    EVIDENCE_FIXTURE="$TMP_ROOT/live-evidence.json" "$MERGE_SH" ready-safe 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "guarded consumer refused a valid approval (rc $rc): $out"
  assert_contains "$out" "merged: $PR_URL at $HEAD_A" "consumer did not report the merged outcome"
  [ "$(grep -c . "$MERGE_LOG")" = 1 ] || fail "the merge owner was not called exactly once"
  assert_grep "ready-safe $PR_URL -- --squash" "$MERGE_LOG" "the merge owner call lost its bindings"
  [ -f "$HOME_DIR/state/dash-merge/consumed/$nonce" ] || fail "consumption ledger record missing"
  assert_grep 'outcome=merged' "$HOME_DIR/state/dash-merge/consumed/$nonce" "consumption outcome not recorded"

  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_EVIDENCE_BIN="$FAKE_BIN/fake-evidence" FM_DASH_PR_MERGE_BIN="$FAKE_BIN/fake-merge-owner" \
    EVIDENCE_FIXTURE="$TMP_ROOT/live-evidence.json" "$MERGE_SH" ready-safe 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a replayed consumed approval was not refused with exit 3 (rc $rc): $out"
  [ "$(grep -c . "$MERGE_LOG")" = 1 ] || fail "a replay caused a second merge attempt"
  pass "one approval merges exactly once through the guarded owner and can never merge again"
}

# Handcraft archived approvals to exercise the refusal matrix without the
# service. Helper writes one archived record and echoes its nonce.
write_archived_approval() {
  local nonce=$1 head=${2:-$HEAD_A} url=${3:-$PR_URL} by=${4:-$CAPTAIN} expires=${5:-2099-01-01T00:00:00.000Z} method=${6:-squash} checks=${7:-$CHECKS_LIVE}
  mkdir -p "$HOME_DIR/state/dash-inbox/archive"
  cat > "$HOME_DIR/state/dash-inbox/archive/9-$nonce-merge-ready-safe.json" <<EOF
{"schema":"fm-dash-command.v1","kind":"merge-approval","id":"merge-ready-safe","task":"ready-safe",
 "url":"$url","repo":"example/repo","number":12,"head_sha":"$head","merge_method":"$method",
 "checks_identity":"$checks","requested_by":"$by","requested_at":"2026-08-04T10:00:00.000Z",
 "expires_at":"$expires","nonce":"$nonce","prompt":"x"}
EOF
  chmod 600 "$HOME_DIR/state/dash-inbox/archive/9-$nonce-merge-ready-safe.json"
}

run_consumer() {
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_EVIDENCE_BIN="$FAKE_BIN/fake-evidence" FM_DASH_PR_MERGE_BIN="$FAKE_BIN/fake-merge-owner" \
    EVIDENCE_FIXTURE="$TMP_ROOT/live-evidence.json" "$MERGE_SH" ready-safe 2>&1) || rc=$?
}

test_consumer_refusal_matrix() {
  local out rc
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete
  : > "$MERGE_LOG"

  run_consumer
  [ "$rc" = 2 ] || fail "no-record run did not refuse (rc $rc)"

  write_archived_approval "00000000000000000000000000000001" "$HEAD_A" "$PR_URL" "$CAPTAIN" "2020-01-01T00:00:00.000Z"
  run_consumer
  [ "$rc" = 2 ] || fail "an expired approval was not refused (rc $rc): $out"
  assert_contains "$out" 'expired' "expiry refusal is not explicit"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  write_archived_approval "00000000000000000000000000000002" "$HEAD_A" "$PR_URL" "mallory@example.com"
  run_consumer
  [ "$rc" = 2 ] || fail "a non-captain approval was not refused (rc $rc)"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  write_archived_approval "00000000000000000000000000000003" "$HEAD_A" "https://gitlab.example.com/g/p/-/merge_requests/9"
  run_consumer
  [ "$rc" = 2 ] || fail "a non-GitHub approval was not refused (rc $rc)"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  write_archived_approval "00000000000000000000000000000004" "$HEAD_A" "https://github.com/example/repo/pull/13"
  run_consumer
  [ "$rc" = 2 ] || fail "an approval for a different PR than the task records was not refused (rc $rc)"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  write_archived_approval "00000000000000000000000000000005"
  mv "$HOME_DIR/state/dash-inbox/archive/9-00000000000000000000000000000005-merge-ready-safe.json" "$TMP_ROOT/linktarget.json"
  ln -s "$TMP_ROOT/linktarget.json" "$HOME_DIR/state/dash-inbox/archive/9-00000000000000000000000000000005-merge-ready-safe.json"
  run_consumer
  [ "$rc" = 2 ] || fail "a symlinked approval record was not refused (rc $rc)"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete
  rm -f "$TMP_ROOT/linktarget.json"

  printf 'not json' > "$HOME_DIR/state/dash-inbox/archive/9-malformed-merge.json"
  chmod 600 "$HOME_DIR/state/dash-inbox/archive/9-malformed-merge.json"
  run_consumer
  [ "$rc" = 2 ] || fail "a malformed approval record was not refused (rc $rc)"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  # Live recheck failures: head moved, then checks changed. Both consume the
  # approval (it can never be retried) but attempt no merge.
  write_archived_approval "00000000000000000000000000000006" "$HEAD_B"
  run_consumer
  [ "$rc" = 4 ] || fail "a moved head at recheck was not invalidated (rc $rc): $out"
  assert_contains "$out" 'head moved' "head-move invalidation is not explicit"
  assert_grep 'outcome=invalidated' "$HOME_DIR/state/dash-merge/consumed/00000000000000000000000000000006" "invalidation was not recorded"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  write_archived_approval "00000000000000000000000000000007" "$HEAD_A" "$PR_URL" "$CAPTAIN" "2099-01-01T00:00:00.000Z" squash "1111111111111111111111111111111111111111111111111111111111111111"
  run_consumer
  [ "$rc" = 4 ] || fail "a changed check set at recheck was not invalidated (rc $rc): $out"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  # Crash between nonce claim and merge: the claim exists, so a rerun refuses
  # rather than attempting a merge whose outcome it cannot know.
  write_archived_approval "00000000000000000000000000000008"
  mkdir -p "$HOME_DIR/state/dash-merge/consumed"
  printf 'task=ready-safe\noutcome=claimed\n' > "$HOME_DIR/state/dash-merge/consumed/00000000000000000000000000000008"
  run_consumer
  [ "$rc" = 3 ] || fail "a crash-claimed approval was retried (rc $rc): $out"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete

  # A failing merge owner is reported, recorded, and never auto-retried.
  write_archived_approval "00000000000000000000000000000009"
  : > "$MERGE_LOG"
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_EVIDENCE_BIN="$FAKE_BIN/fake-evidence" FM_DASH_PR_MERGE_BIN="$FAKE_BIN/fake-merge-owner" \
    EVIDENCE_FIXTURE="$TMP_ROOT/live-evidence.json" MERGE_RC=1 "$MERGE_SH" ready-safe 2>&1) || rc=$?
  [ "$rc" = 5 ] || fail "a failed merge attempt was not reported (rc $rc): $out"
  assert_grep 'outcome=attempt-failed' "$HOME_DIR/state/dash-merge/consumed/00000000000000000000000000000009" "failed attempt was not recorded"
  run_consumer
  [ "$rc" = 3 ] || fail "a failed attempt was auto-retried (rc $rc)"
  [ "$(grep -c . "$MERGE_LOG")" = 1 ] || fail "the failed merge owner was called more than once"
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete
  pass "every broken binding refuses, every recheck change invalidates, and no path ever merges twice"
}

# Compute the live checks identity once from the evidence probe so the
# handcrafted approvals and the fake live evidence agree exactly.
gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
CHECKS_LIVE=$(FM_HOME="$HOME_DIR" FM_DASH_PR_GH_BIN="$FAKE_BIN/fake-gh" node "$EVIDENCE" ready-safe | node -e '
  let raw = "";
  process.stdin.on("data", (c) => { raw += c; });
  process.stdin.on("end", () => { console.log(JSON.parse(raw).checks_identity); });
')
[ -n "$CHECKS_LIVE" ] || { echo "not ok - could not derive the fixture checks identity" >&2; exit 1; }

# Synthetic browser preview: a real Chrome drives the served page - a chat
# message sent at 390px renders safely and lands as a durable record, a fake
# ready-PR approval clicks through review, attestation, and confirmation into
# a durable typed record consumed by the fake merge owner, and a red PR gets a
# refusal with no active control. No real PR, forge, or merge is involved.
test_browser_preview_chat_and_exact_merge() {
  local chrome browser_port debug_port tries=0 result rc out nonce
  chrome=$(find_chrome) || {
    pass "browser preview skipped because Chrome is unavailable"
    return
  }
  find "$HOME_DIR/state/dash-inbox" -maxdepth 1 -name '*.json' -delete 2>/dev/null || true
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete 2>/dev/null || true
  find "$HOME_DIR/state/dash-chat" -name '*.json' -delete 2>/dev/null || true
  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  browser_port=$(pick_port)
  node - "$PORT" "$browser_port" "$CAPTAIN" <<'JS' &
const http = require("node:http");
const [upstreamPort, proxyPort, login] = process.argv.slice(2);
http.createServer((request, response) => {
  const upstream = http.request({
    host: "127.0.0.1",
    port: upstreamPort,
    method: request.method,
    path: request.url,
    headers: {
      ...request.headers,
      host: `127.0.0.1:${upstreamPort}`,
      ...(request.headers.origin ? { origin: `http://127.0.0.1:${upstreamPort}` } : {}),
      "Tailscale-User-Login": login,
    },
  }, (incoming) => {
    const chunks = [];
    incoming.on("data", (chunk) => chunks.push(chunk));
    incoming.on("end", () => {
      response.writeHead(incoming.statusCode || 502, { ...incoming.headers });
      response.end(Buffer.concat(chunks));
    });
  });
  upstream.on("error", () => {
    response.writeHead(502, { "content-type": "text/plain" });
    response.end("upstream unavailable");
  });
  request.pipe(upstream);
}).listen(Number(proxyPort), "127.0.0.1");
JS
  BROWSER_PROXY_PID=$!
  while ! curl -sf "http://127.0.0.1:$browser_port/healthz" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "browser preview proxy did not start"
    sleep 0.1
  done
  debug_port=$(pick_port)
  "$chrome" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --remote-debugging-port="$debug_port" \
    --user-data-dir="$TMP_ROOT/chrome-preview-profile" \
    "http://127.0.0.1:$browser_port/" >/dev/null 2>&1 &
  BROWSER_PID=$!
  tries=0
  while ! curl -sf "http://127.0.0.1:$debug_port/json/list" >/dev/null 2>&1; do
    kill -0 "$BROWSER_PID" 2>/dev/null || fail "Chrome stopped before DevTools was ready"
    [ "$tries" -lt 100 ] || fail "Chrome DevTools endpoint did not become ready"
    sleep 0.1
    tries=$((tries + 1))
  done
  result=$(node --experimental-websocket --input-type=module - "$debug_port" <<'JS'
const port = process.argv[2];
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const target = targets.find((entry) => entry.type === "page");
if (!target) process.exit(1);
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});
let sequence = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (!message.id || !pending.has(message.id)) return;
  const { resolve, reject } = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) reject(new Error(message.error.message));
  else resolve(message.result);
});
const command = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++sequence;
  pending.set(id, { resolve, reject });
  socket.send(JSON.stringify({ id, method, params }));
});
let step = "start";
const evaluate = async (expression) => {
  const out = await command("Runtime.evaluate", { awaitPromise: true, returnByValue: true, expression });
  if (out.exceptionDetails) throw new Error(`[${step}] ` + (out.exceptionDetails.exception?.description || out.exceptionDetails.text));
  return out.result.value;
};
const waitFor = (body) => evaluate(`new Promise((resolve, reject) => {
  const deadline = performance.now() + 8000;
  const poll = () => {
    try {
      const value = (() => { ${body} })();
      if (value !== undefined && value !== null && value !== false) { resolve(value); return; }
    } catch (error) { reject(error); return; }
    if (performance.now() >= deadline) { reject(new Error("timed out waiting for a preview condition")); return; }
    setTimeout(poll, 50);
  };
  poll();
})`);

// --- phone: chat at 390px ---------------------------------------------------
await command("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: false });
await command("Page.reload", { ignoreCache: true });
step = "chat-nav"; await waitFor(`return document.querySelector('[data-dashboard-link="chat"]') && true;`);
step = "open-chat"; await evaluate(`location.hash = "#chat"; true;`);
step = "chat-visible"; await waitFor(`const page = document.getElementById("chat"); return page && !page.hidden;`);
step = "chat-send"; const chatProbe = await evaluate(`(async () => {
  const input = document.querySelector(".fmdash-composer textarea");
  const send = document.querySelector(".fmdash-composer-row .fmdash-send");
  input.value = "Preview probe <img src=x onerror=window.__xss=1> https://example.ts.net/report";
  send.click();
  return true;
})()`);
if (!chatProbe) throw new Error("chat composer not interactive");
step = "chat-bubble"; const chatResult = await waitFor(`
  const bubble = document.querySelector(".fmdash-msg-captain");
  if (!bubble) return false;
  const text = bubble.querySelector(".fmdash-msg-text");
  const link = text.querySelector("a");
  return {
    text: text.textContent,
    injected: window.__xss === 1 || !!text.querySelector("img"),
    linkHref: link ? link.href : null,
    state: bubble.querySelector(".fmdash-msg-state").textContent,
    noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth,
    privacy: document.querySelector(".fmdash-chat-note").textContent.includes("not end-to-end application encryption"),
    width: window.innerWidth,
  };`);

// --- desktop: exact merge review ---------------------------------------------
await command("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
await evaluate(`location.hash = "#brief"; true;`);
await command("Page.reload", { ignoreCache: true });
await waitFor(`const buttons = [...document.querySelectorAll("button")]; return buttons.some((b) => b.textContent === "Review merge…");`);
await evaluate(`[...document.querySelectorAll("button")].find((b) => b.textContent === "Review merge…").click(); true;`);
const reviewFacts = await waitFor(`
  const panel = document.querySelector(".fmdash-panel");
  if (!panel || !panel.querySelector(".fmdash-merge-facts")) return false;
  const approve = panel.querySelector(".fmdash-merge-approve");
  if (!approve) return false;
  return {
    facts: panel.querySelector(".fmdash-merge-facts").textContent,
    approveDisabled: approve.disabled,
  };`);
await evaluate(`
  const panel = document.querySelector(".fmdash-panel");
  const box = panel.querySelector(".fmdash-merge-confirm input");
  box.checked = true;
  box.dispatchEvent(new Event("change"));
  true;`);
const enabledAfterAttest = await waitFor(`
  const approve = document.querySelector(".fmdash-merge-approve");
  return approve && !approve.disabled ? { enabled: true } : false;`);
await evaluate(`document.querySelector(".fmdash-merge-approve").click(); true;`);
const approved = await waitFor(`
  const heading = [...document.querySelectorAll(".fmdash-panel h2")].map((h) => h.textContent);
  return heading.includes("Merge approval sent") ? { confirmed: true } : false;`);
socket.close();
process.stdout.write(JSON.stringify({ chat: chatResult, review: reviewFacts, attested: enabledAfterAttest, approved }));
JS
  ) || fail "browser preview probe failed"
  kill "$BROWSER_PID" 2>/dev/null || true
  wait "$BROWSER_PID" 2>/dev/null || true
  BROWSER_PID=""
  kill "$BROWSER_PROXY_PID" 2>/dev/null || true
  wait "$BROWSER_PROXY_PID" 2>/dev/null || true
  BROWSER_PROXY_PID=""
  printf '%s' "$result" | node -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      const r = JSON.parse(raw);
      const ok = r.chat.width === 390
        && r.chat.text.includes("Preview probe <img src=x onerror=window.__xss=1>")
        && r.chat.injected === false
        && r.chat.linkHref === "https://example.ts.net/report"
        && r.chat.state.includes("Sent to firstmate")
        && r.chat.noPageOverflow === true
        && r.chat.privacy === true
        && r.review.facts.includes("https://github.com/example/repo/pull/12")
        && r.review.facts.includes("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        && r.review.facts.includes("squash")
        && r.review.approveDisabled === true
        && r.attested.enabled === true
        && r.approved.confirmed === true;
      if (!ok) { console.error(raw); process.exit(1); }
    });
  ' || fail "browser preview assertions failed: $result"
  [ -n "$(find "$HOME_DIR/state/dash-chat/messages" -name '*.json' 2>/dev/null)" ] || fail "the browser chat send left no durable record"
  # The browser click became a durable typed approval; consume it through the
  # real claim and the guarded consumer against the fake merge owner.
  FM_HOME="$HOME_DIR" "$INBOX_SH" claim >/dev/null || fail "claim after browser approval failed"
  : > "$MERGE_LOG"
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_DASH_PR_EVIDENCE_BIN="$FAKE_BIN/fake-evidence" FM_DASH_PR_MERGE_BIN="$FAKE_BIN/fake-merge-owner" \
    EVIDENCE_FIXTURE="$TMP_ROOT/live-evidence.json" "$MERGE_SH" ready-safe 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "the browser-approved record did not merge through the fake owner (rc $rc): $out"
  [ "$(grep -c . "$MERGE_LOG")" = 1 ] || fail "the browser-approved record merged more than once"

  # Refusal preview: a freshly red PR renders an honest refusal with no
  # active merge control.
  find "$HOME_DIR/state/dash-inbox/archive" -name '*.json' -delete
  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED FAILURE SUCCESS
  req GET "http://127.0.0.1:$PORT/api/merge/preview?ref=item-01" "$CAPTAIN"
  [ "$REQ_STATUS" = 200 ] || fail "red-PR preview failed"
  assert_contains "$RESP" '"eligible":false' "a red PR still previews as eligible"
  assert_contains "$RESP" 'not every current check is terminal green' "the red-PR refusal reason is missing"
  gh_payload OPEN false MERGEABLE "$HEAD_A" COMPLETED SUCCESS SUCCESS
  pass "a real browser sends chat safely at 390px and click-approves one exact merge through the fake guarded owner"
}

test_evidence_probe_matrix
test_preview_and_approve_validation
test_guarded_consumer_end_to_end
test_consumer_refusal_matrix
test_browser_preview_chat_and_exact_merge

echo "fm-dash-merge tests passed"
