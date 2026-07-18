#!/usr/bin/env bash
# Behavior and contract tests for the captain-invocable /capacity skill.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPACITY="$ROOT/bin/fm-capacity.mjs"
SKILL="$ROOT/.agents/skills/capacity/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-capacity)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_fixture() {
  local home=$1 snapshot=$2 environment=$3
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$home/data/backlog.md" <<'EOF'
sentinel backlog content
EOF
  cat > "$snapshot" <<EOF
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-07-17T16:00:00Z",
  "fm_home": "$home",
  "roots": {"fm_root":"$ROOT","state":"$home/state","data":"$home/data","config":"$home/config","projects":"$home/projects"},
  "backlog": {
    "path": "$home/data/backlog.md",
    "present": true,
    "records": [
      {"order":1,"state":"in_flight","structured":true,"id":"build-old","title":"Build the alpha subsystem","repo":"alpha","kind":"ship","since":"2026-07-01","body_excerpt":"Acceptance criteria: alpha behavior is tested."},
      {"order":2,"state":"in_flight","structured":true,"id":"validate-now","title":"Validate the beta delivery","repo":"beta","kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: CI is green."},
      {"order":3,"state":"queued","structured":true,"id":"ready-safe","title":"Ship <script>alert(1)</script> token=topsecret AKIAIOSFODNN7EXAMPLE xoxb-123456789012-123456789012-abcdefghijklmnop https://user:pass@example.com 212-555-0199","repo":"gamma","kind":"ship","body_excerpt":"Acceptance criteria: bounded regression tests pass."},
      {"order":4,"state":"queued","structured":true,"id":"overlap-alpha","title":"Improve the active alpha subsystem","repo":"alpha","kind":"ship","body_excerpt":"Acceptance criteria: alpha remains compatible."},
      {"order":5,"state":"queued","structured":true,"id":"vague","title":"TBD","repo":null,"kind":null,"body_excerpt":"Contact patient@example.com about password=hunter2"},
      {"order":6,"state":"queued","structured":true,"id":"dependency","title":"Publish the dependent release","repo":"epsilon","kind":"ship","blocked_by":"build-old","blocked_reason":"wait for alpha landing","body_excerpt":"Acceptance criteria: release is published."},
      {"order":7,"state":"queued","structured":true,"id":"captain-choice","title":"Choose the rollout policy","repo":"alpha","kind":"captain","hold_kind":"captain","hold_reason":"pick conservative or fast rollout for Jane Doe oncology record"},
      {"order":8,"state":"queued","structured":true,"id":"future-gate","title":"Run the migration after 2026-08-01","repo":"zeta","kind":"ship","body_excerpt":"Acceptance criteria: migration checks pass."},
      {"order":9,"state":"done","structured":true,"id":"landed-one","title":"Landed useful work","repo":"alpha","kind":"ship","pr_url":"https://github.com/purple-phoenix/firstmate/pull/10","completion":{"verb":"merged","date":"2026-07-16"}}
    ]
  },
  "tasks": [
    {"id":"build-old","kind":"ship","project":"alpha","current_state":{"state":"working","source":"pane","detail":"harness busy"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"build-old","title":"Build the alpha subsystem","repo":"alpha","kind":"ship","since":"2026-07-01"}},
    {"id":"validate-now","kind":"ship","project":"beta","current_state":{"state":"working","source":"run-step","detail":"validating (fixing)"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":"https://github.com/purple-phoenix/firstmate/pull/11"},"paths":{"report":{"present":false}},"backlog":{"id":"validate-now","title":"Validate the beta delivery","repo":"beta","kind":"ship","since":"2026-07-16"}}
  ],
  "scout_reports": [],
  "secondmate_current": {
    "registry": {"available":true,"complete":true,"records":[
      {"id":"design","scope":"design systems","projects":["delta"]},
      {"id":"quiet","scope":"documentation","projects":["docs"]},
      {"id":"unknown-mate","scope":"operations","projects":["ops"]}
    ]},
    "records": [
      {"id":"design","home":"$home/design","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[{"id":"design-ready","title":"Refresh the delta design tokens","repo":"delta","kind":"ship","body_excerpt":"Acceptance criteria: token snapshots pass."}],"landed":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":1},"omitted":[]},
      {"id":"quiet","home":"$home/quiet","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[],"landed":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":0},"omitted":[]},
      {"id":"unknown-mate","home":"$home/unknown","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[],"landed":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":0},"omitted":[]}
    ],
    "total": 3,
    "shown": 3,
    "truncated": 0
  },
  "secondmate_landed": {"records":[],"truncated":[],"unreadable":["$home/unknown"]}
}
EOF
  cat > "$environment" <<'EOF'
{
  "backend": {"name":"tmux","available":true,"evidence":"required runtime tools present","owner":"fixture"},
  "github_auth": {"status":"available","evidence":"authenticated","owner":"fixture"},
  "dispatch": {"config_present":true,"valid":true,"reason":null,"lanes":[
    {"harness":"codex","model":"gpt-test","effort":"high","when":"default","available":true,"availability_evidence":"executable present","quota":"not observed - capacity never guesses quota"}
  ]}
}
EOF
}

test_skill_discovery_and_read_mostly_contract() {
  assert_present "$SKILL" "capacity SKILL.md is missing"
  assert_grep 'name: capacity' "$SKILL" "capacity skill frontmatter has the wrong name"
  assert_grep 'user-invocable: true' "$SKILL" "capacity skill is not captain-invocable"
  assert_grep 'capacity, bottlenecks, pipeline utilization, work supply, idle lanes, or maximizing fleet throughput' "$SKILL" "capacity natural-language trigger is incomplete"
  assert_grep "single owner of Firstmate's conditional capacity procedure" "$SKILL" "capacity skill does not declare its one-owner contract"
  assert_grep 'load `capacity`' "$ROOT/AGENTS.md" "AGENTS.md lacks the capacity load trigger"
  assert_grep 'must never invent work, dispatch for utilization, or weaken lifecycle safety' "$ROOT/AGENTS.md" "AGENTS.md lacks the capacity safety stub"
  assert_grep '| `/capacity`' "$ROOT/README.md" "README does not list /capacity"
  assert_grep 'Do not invoke, depend on, open, poll, share, or embed Lavish' "$SKILL" "capacity skill does not forbid Lavish"
  assert_grep 'must not dispatch, merge, tear down, mutate task state, edit the backlog' "$SKILL" "capacity read-mostly boundary is incomplete"
  pass "capacity is discoverable and its conditional read-mostly procedure has one owner"
}

test_classification_priority_overlap_and_idle_semantics() {
  local home="$TMP_ROOT/model-home" snapshot="$TMP_ROOT/model-snapshot.json" environment="$TMP_ROOT/model-environment.json" output="$TMP_ROOT/model.html" json ids
  make_fixture "$home" "$snapshot" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "capacity fixture run failed"
  printf '%s' "$json" | jq -e '
    .schema == "fm-capacity.v1"
    and .measures.useful_ready_work == 2
    and .readiness.independent_start_count == 2
    and .readiness.available == true
    and (.pipeline.ready | length) == 2
    and (.readiness.conservative_overlap_gates | length) == 1
    and (.readiness.explicit_gates | any(.reason == "dependency or structured hold"))
    and (.readiness.explicit_gates | any(.reason == "time gate until 2026-08-01"))
    and (.readiness.definition_gaps | any(.gaps | index("project unresolved")))
    and (.lanes.persistent_secondmates | any(.utilization == "idle with grounded ready in-scope work"))
    and ([.lanes.persistent_secondmates[] | select(.utilization | startswith("healthy idle"))] | length) == 2
    and .primary_bottleneck.id == "CAP-09"
    and (.recommendations | any(.id == "CAP-01" and .classification == "captain-held decisions"))
    and (.recommendations | any(.id == "CAP-04" and .classification == "definition shortage"))
    and (.recommendations | any(.id == "CAP-05" and .classification == "overlap serialization"))
    and (.recommendations | any(.id == "CAP-06" and .classification == "grounded ready supply"))
    and (.recommendations | any(.id == "CAP-07" and .classification == "validation, CI, or approval"))
    and (.recommendations | any(.id == "CAP-10" and .classification == "aging flow"))
  ' >/dev/null || fail "capacity classifications or priority are wrong: $json"
  ids=$(printf '%s' "$json" | jq -c '[.recommendations[].id]')
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "capacity repeat run failed"
  [ "$ids" = "$(printf '%s' "$json" | jq -c '[.recommendations[].id]')" ] || fail "capacity action IDs are not deterministic"
  pass "capacity classifies supply, overlap, blockers, secondmate idle state, aging, and stable action priority"
}

test_cross_home_overlap_holds_supersession_and_active_count() {
  local home="$TMP_ROOT/cross-home" snapshot="$TMP_ROOT/cross-snapshot.json" environment="$TMP_ROOT/cross-environment.json" output="$TMP_ROOT/cross.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records += [
      {"order":10,"state":"in_flight","structured":true,"id":"main-held","title":"Hold the lambda delivery","repo":"lambda","kind":"ship","since":"2026-07-10","body_excerpt":"Acceptance criteria: lambda is complete."},
      {"order":11,"state":"queued","structured":true,"id":"main-held-overlap","title":"Extend the held lambda delivery","repo":"lambda","kind":"ship","body_excerpt":"Acceptance criteria: lambda remains compatible."},
      {"order":12,"state":"queued","structured":true,"id":"mate-held-overlap","title":"Extend the held iota delivery","repo":"iota","kind":"ship","body_excerpt":"Acceptance criteria: iota remains compatible."}
    ]
    | .tasks += [
      {"id":"main-held","kind":"ship","project":"lambda","current_state":{"state":"blocked","source":"run-step","detail":"external wait"},"endpoint":{"exists":true},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"main-held","title":"Hold the lambda delivery","repo":"lambda","kind":"ship","since":"2026-07-10"}}
    ]
    | .secondmate_current.records[0].active_children = [
      {"id":"child-gamma","repo":"gamma","kind":"ship","state":"working","doing":"working"},
      {"id":"child-theta","repo":"theta","kind":"ship","state":"working","doing":"working"}
    ]
    | .secondmate_current.records[0].holds = [
      {"id":"held-old","title":"Sensitive held work","repo":"iota","kind":"ship","since":"2026-07-01","reason":"external dependency","source":"child-state"}
    ]
    | .secondmate_current.records[0].queued += [
      {"id":"held-old","title":"Sensitive held work","repo":"iota","kind":"ship","since":"2026-07-01","blocked_by":"external"},
      {"id":"superseded","title":"Do not start this deferred item","repo":"kappa","kind":"ship","body_excerpt":"DEFERRED. Acceptance criteria: none."}
    ]
    | .secondmate_current.records[0].counts = {"active_children":2,"decisions_open":0,"holds":1,"queued":3}
    | .secondmate_current.records[0].omitted = []
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "cross-home capacity run failed"
  printf '%s' "$json" | jq -e '
    .readiness.available == true
    and .measures.useful_ready_work == 1
    and .measures.active_independent_work == 4
    and (.readiness.conservative_overlap_gates | length) == 4
    and (.pipeline.blocked | length) == 5
    and (.aging | any(.state == "held" and .age_days == 16))
    and (.aging | any(.state == "blocked" and .age_days == 7))
    and .readiness.queued_considered == 9
  ' >/dev/null || fail "cross-home overlap, held work, supersession, or active flow count is wrong: $json"
  pass "capacity serializes projects fleet-wide and retains held secondmate flow without superseded work"
}

test_secondmate_readiness_uses_final_serialized_supply() {
  local home="$TMP_ROOT/final-ready-home" snapshot="$TMP_ROOT/final-ready-snapshot.json" environment="$TMP_ROOT/final-ready-environment.json" output="$TMP_ROOT/final-ready.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_current.records[0].queued[0].repo = "alpha"' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "serialized secondmate capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.useful_ready_work == 1
    and (.lanes.persistent_secondmates | any(.ready_in_scope == 0 and (.utilization | startswith("healthy idle"))))
    and (.recommendations | any(.id == "CAP-09") | not)
  ' >/dev/null || fail "secondmate lane readiness was not derived from final serialized supply: $json"
  pass "secondmate readiness reflects final fleet-wide serialization"
}

test_incomplete_sources_fail_closed() {
  local home="$TMP_ROOT/incomplete-home" snapshot="$TMP_ROOT/incomplete-snapshot.json" environment="$TMP_ROOT/incomplete-environment.json" output="$TMP_ROOT/incomplete.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_current.truncated = 1' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "truncated capacity run failed"
  printf '%s' "$json" | jq -e '
    .readiness.available == false
    and .measures.useful_ready_work == 0
    and (.recommendations | any(.id == "CAP-03"))
    and (.recommendations | any(.id == "CAP-06") | not)
    and (.recommendations | any(.id == "CAP-08") | not)
  ' >/dev/null || fail "truncated secondmate inventory did not suppress readiness: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_current.records[0].omitted = [{"surface":"queued","count":1}]' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "omitted-home capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false and .measures.useful_ready_work == 0' >/dev/null ||
    fail "per-home omitted queue did not suppress readiness: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_current.records[0].omitted = [{"surface":"decisions_open","count":1}]' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "omitted-decision capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false and .measures.useful_ready_work == 0' >/dev/null ||
    fail "per-home omitted decisions did not suppress readiness: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_current.records[0].counts.decisions_open = 1' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "mismatched-decision capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false and .measures.useful_ready_work == 0' >/dev/null ||
    fail "per-home decision count mismatch did not suppress readiness: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.backlog.present = false | .backlog.records = []' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "missing-backlog capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false and (.recommendations | any(.id == "CAP-08") | not)' >/dev/null ||
    fail "missing main backlog produced a demand-shortage conclusion: $json"
  pass "capacity suppresses readiness and demand claims for incomplete bounded sources"
}

test_unresolved_active_projects_fail_closed() {
  local home="$TMP_ROOT/project-gap-home" snapshot="$TMP_ROOT/project-gap-snapshot.json" environment="$TMP_ROOT/project-gap-environment.json" output="$TMP_ROOT/project-gap.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records[0].repo = null
    | .tasks[0].project = null
    | .tasks[0].backlog.repo = null
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "unresolved main project capacity run failed"
  printf '%s' "$json" | jq -e '
    .readiness.available == false
    and .measures.useful_ready_work == 0
    and (.recommendations | any(.id == "CAP-03"))
    and (.recommendations | any(.id == "CAP-06") | not)
  ' >/dev/null || fail "unresolved main project did not suppress readiness: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .secondmate_current.records[0].active_children = [
      {"id":"child-without-project","kind":"ship","state":"working","doing":"working"}
    ]
    | .secondmate_current.records[0].counts.active_children = 1
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "unresolved secondmate project capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false and .measures.useful_ready_work == 0' >/dev/null ||
    fail "unresolved secondmate child project did not suppress readiness: $json"
  pass "capacity fails closed when active project provenance is unresolved"
}

test_definition_and_time_markers_require_whole_evidence() {
  local home="$TMP_ROOT/markers-home" snapshot="$TMP_ROOT/markers-snapshot.json" environment="$TMP_ROOT/markers-environment.json" output="$TMP_ROOT/markers.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records += [
      {"order":10,"state":"queued","structured":true,"id":"latest-only","title":"Use the latest version safely","repo":"eta","kind":"ship","body_excerpt":"Use the latest version with compatibility checks."},
      {"order":11,"state":"queued","structured":true,"id":"version-date","title":"Support Version 2026-08-01 compatibility","repo":"theta","kind":"ship","body_excerpt":"Acceptance criteria: compatibility remains intact."},
      {"order":12,"state":"queued","structured":true,"id":"word-substrings","title":"Support the nondeferred aftercare workflow","repo":"iota","kind":"ship","body_excerpt":"Acceptance criteria: aftercare remains compatible with the nondeferred workflow."}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "definition-marker capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.useful_ready_work == 4
    and ([.readiness.definition_gaps[] | select(.gaps | index("acceptance criteria missing"))] | length) == 2
    and ([.readiness.explicit_gates[] | select(.reason == "time gate until 2026-08-01")] | length) == 1
  ' >/dev/null || fail "acceptance or time-gate substring produced false evidence: $json"
  pass "capacity requires explicit acceptance and whole-word time-gate markers"
}

test_secondmate_captain_holds_are_pipeline_waiting_work() {
  local home="$TMP_ROOT/captain-hold-home" snapshot="$TMP_ROOT/captain-hold-snapshot.json" environment="$TMP_ROOT/captain-hold-environment.json" output="$TMP_ROOT/captain-hold.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .secondmate_current.records[0].decisions_open = [
      {"id":"mate-choice","key":"mate-choice","verb":"captain-hold","summary":"Sensitive choice","source":"backlog"}
    ]
    | .secondmate_current.records[0].queued += [
      {"id":"mate-choice","title":"Choose the secondmate rollout","repo":"delta","kind":"captain","hold_kind":"captain","hold_reason":"Sensitive reason"}
    ]
    | .secondmate_current.records[0].counts = {"active_children":0,"decisions_open":1,"holds":0,"queued":2}
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "secondmate captain-hold capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.blocked | length) == 4
    and .measures.open_captain_actions == 2
    and (.recommendations[] | select(.id == "CAP-01") | .evidence | startswith("2 structured captain"))
  ' >/dev/null || fail "secondmate captain hold was missing or double-counted: $json"
  pass "secondmate captain holds appear once in decisions and pipeline waiting work"
}

test_approval_signal_and_max_effort_survive_safe_normalization() {
  local home="$TMP_ROOT/approval-home" snapshot="$TMP_ROOT/approval-snapshot.json" environment="$TMP_ROOT/approval-environment.json" output="$TMP_ROOT/approval.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [
      {"order":1,"state":"in_flight","structured":true,"id":"approval-ready","title":"Finish the approval-ready delivery","repo":"omega","kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: CI passes."}
    ]
    | .tasks = [
      {"id":"approval-ready","kind":"ship","project":"omega","current_state":{"state":"done","source":"run-step","detail":"PR checks green for Jane Doe"},"endpoint":{"exists":true},"hints":{"open_decisions":[]},"pr":{"url":"https://example.invalid/private"},"paths":{"report":{"present":false}},"backlog":{"id":"approval-ready","title":"Finish the approval-ready delivery","repo":"omega","kind":"ship","since":"2026-07-16"}}
    ]
    | .secondmate_current.registry.records = []
    | .secondmate_current.records = []
    | .secondmate_current.total = 0
    | .secondmate_current.shown = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  jq '.dispatch.lanes = [{"harness":"pi","effort":"max","when":"default","available":true}]' "$environment" > "$environment.tmp"
  mv "$environment.tmp" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "approval-ready capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.pr_ci_approval | any(.approval_ready == true))
    and (.recommendations | any(.id == "CAP-07"))
    and .lanes.ephemeral_workers.configured_dispatch.lanes[0].effort == "max"
  ' >/dev/null || fail "approval-ready or max-effort signal was lost: $json"
  case "$json" in
    *"Jane Doe"*) fail "privacy-safe approval signal leaked raw status detail" ;;
  esac

  jq '
    .tasks[0].mode = "direct-PR"
    | .tasks[0].current_state.detail = "PR opened"
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "direct-PR approval capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.pr_ci_approval | any(.approval_ready == true))
    and .measures.open_captain_actions == 1
    and (.recommendations | any(.id == "CAP-07"))
  ' >/dev/null || fail "direct-PR terminal readiness was not an approval signal: $json"

  jq '
    .tasks[0].mode = "local-only"
    | .tasks[0].pr.url = null
    | .tasks[0].current_state.detail = "ready in branch"
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "local-only approval capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.pr_ci_approval | any(.approval_ready == true))
    and .measures.open_captain_actions == 1
    and (.recommendations | any(.id == "CAP-07"))
  ' >/dev/null || fail "local-only terminal readiness was not an approval signal: $json"
  pass "approval readiness and supported max effort survive safe normalization"
}

test_unavailable_lanes_and_demand_shortage_are_distinct() {
  local home="$TMP_ROOT/empty-home" snapshot="$TMP_ROOT/empty-snapshot.json" environment="$TMP_ROOT/empty-environment.json" output="$TMP_ROOT/empty.html" json
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$snapshot" <<EOF
{"schema":"fm-fleet-snapshot.v1","generated":"2026-07-17T16:00:00Z","fm_home":"$home","roots":{"fm_root":"$ROOT","state":"$home/state","data":"$home/data","config":"$home/config","projects":"$home/projects"},"backlog":{"present":true,"records":[]},"tasks":[],"scout_reports":[],"secondmate_current":{"registry":{"available":true,"complete":true,"records":[]},"records":[],"total":0,"shown":0,"truncated":0},"secondmate_landed":{"records":[],"truncated":[],"unreadable":[]}}
EOF
  cat > "$environment" <<'EOF'
{"backend":{"name":"orca","available":false,"evidence":"orca executable missing"},"github_auth":{"status":"unavailable","evidence":"login required"},"dispatch":{"config_present":true,"valid":true,"lanes":[{"harness":"codex","available":false,"availability_evidence":"configured harness executable missing","quota":"not observed - capacity never guesses quota"}]}}
EOF
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "empty capacity run failed"
  printf '%s' "$json" | jq -e '
    .primary_bottleneck.id == "CAP-02"
    and (.recommendations | any(.id == "CAP-08" and .classification == "demand shortage"))
    and (.recommendations | any(.id == "CAP-09" and .classification == "lane mismatch"))
    and (.recommendations[] | select(.id == "CAP-09") | .safety_authority_boundary | contains("Quota is explicitly unobserved"))
  ' >/dev/null || fail "credentials, demand shortage, and lane mismatch were conflated: $json"
  pass "capacity keeps credentials, lane mismatch, and true demand shortage distinct"
}

test_html_is_private_escaped_accessible_and_responsive() {
  local home="$TMP_ROOT/html-home" snapshot="$TMP_ROOT/html-snapshot.json" environment="$TMP_ROOT/html-environment.json" output before
  output="$home/data/capacity-dashboard.html"
  make_fixture "$home" "$snapshot" "$environment"
  before=$(cksum "$home/data/backlog.md")
  "$CAPACITY" --snapshot "$snapshot" --environment "$environment" --output "$output" >/dev/null || fail "capacity HTML run failed"
  assert_present "$output" "capacity dashboard was not written"
  [ "$before" = "$(cksum "$home/data/backlog.md")" ] || fail "capacity run mutated the backlog"
  assert_grep '<meta name="viewport"' "$output" "dashboard lacks responsive viewport metadata"
  assert_grep 'grid-template-columns:repeat(4,minmax(0,1fr))' "$output" "dashboard pipeline lacks shrink-safe grid tracks"
  assert_grep 'overflow-wrap:anywhere' "$output" "dashboard lacks long-token containment"
  assert_grep '@media(max-width:760px)' "$output" "dashboard lacks narrow-width safeguards"
  assert_grep 'class="skip" href="#main"' "$output" "dashboard lacks a keyboard skip link"
  for stage in queued ready building validating_fixing pr_ci_approval blocked recently_landed; do
    assert_grep "id=\"stage-$stage\"" "$output" "dashboard is missing stage $stage"
  done
  assert_no_grep 'alert(1)' "$output" "dashboard rendered uncontrolled backlog title text"
  assert_no_grep 'topsecret' "$output" "dashboard leaked a token-like value"
  assert_no_grep 'hunter2' "$output" "dashboard leaked a password-like value"
  assert_no_grep 'patient@example.com' "$output" "dashboard leaked an email address"
  assert_no_grep 'pick conservative or fast rollout' "$output" "dashboard leaked a hold reason"
  assert_no_grep 'AKIAIOSFODNN7EXAMPLE' "$output" "dashboard leaked an AWS-style credential"
  assert_no_grep 'xoxb-' "$output" "dashboard leaked a Slack-style credential"
  assert_no_grep 'user:pass' "$output" "dashboard leaked a credential-bearing URL"
  assert_no_grep '212-555-0199' "$output" "dashboard leaked a phone number"
  assert_no_grep 'Jane Doe' "$output" "dashboard leaked a person name"
  assert_no_grep 'oncology' "$output" "dashboard leaked medical detail"
  assert_no_grep "$home" "$output" "dashboard leaked a private filesystem path"
  assert_no_grep 'src="http' "$output" "dashboard loads a remote script or image"
  assert_no_grep '@import' "$output" "dashboard imports a remote stylesheet"
  assert_no_grep 'lavish' "$output" "dashboard contains a Lavish dependency"
  assert_grep 'data-copy=' "$output" "dashboard lacks copyable action prompts"
  pass "dashboard is offline, escaped, privacy-bounded, accessible, responsive, and read-mostly"
}

test_output_replacement_rejects_symlinks_and_enforces_mode() {
  local home="$TMP_ROOT/output-home" snapshot="$TMP_ROOT/output-snapshot.json" environment="$TMP_ROOT/output-environment.json"
  local output="$home/data/capacity-dashboard.html" target="$TMP_ROOT/symlink-target" mode
  make_fixture "$home" "$snapshot" "$environment"
  printf '%s\n' sentinel > "$target"
  ln -s "$target" "$output"
  if "$CAPACITY" --snapshot "$snapshot" --environment "$environment" --output "$output" >/dev/null 2>&1; then
    fail "capacity followed a symlink dashboard destination"
  fi
  [ "$(cat "$target")" = sentinel ] || fail "capacity changed a symlink target"
  rm "$output"
  printf '%s\n' old > "$output"
  chmod 0644 "$output"
  "$CAPACITY" --snapshot "$snapshot" --environment "$environment" --output "$output" >/dev/null ||
    fail "capacity could not replace an existing regular dashboard"
  mode=$(stat -f '%Lp' "$output" 2>/dev/null || stat -c '%a' "$output")
  [ "$mode" = 600 ] || fail "capacity dashboard mode is $mode, expected 600"
  pass "capacity atomically replaces regular output with mode 0600 and rejects symlinks"
}

test_fleet_snapshot_preserves_registered_scope_provenance() {
  local home="$TMP_ROOT/registry-home" missing="$TMP_ROOT/missing-secondmate" json
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' '- design - design systems domain (home: '"$missing"'; scope: design systems and UI review; projects: alpha, beta; added 2026-07-17)' > "$home/data/secondmates.md"
  json=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-17T16:00:00Z "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "canonical fleet snapshot failed on registry fixture"
  printf '%s' "$json" | jq -e '
    .secondmate_current.registry.records
    | any(.id == "design" and .summary == "design systems domain" and .scope == "design systems and UI review" and .projects == ["alpha","beta"])
  ' >/dev/null || fail "canonical snapshot did not preserve route scope provenance: $json"
  pass "canonical fleet snapshot preserves bounded secondmate summary, scope, and projects"
}

test_skill_discovery_and_read_mostly_contract
test_classification_priority_overlap_and_idle_semantics
test_cross_home_overlap_holds_supersession_and_active_count
test_secondmate_readiness_uses_final_serialized_supply
test_incomplete_sources_fail_closed
test_unresolved_active_projects_fail_closed
test_definition_and_time_markers_require_whole_evidence
test_secondmate_captain_holds_are_pipeline_waiting_work
test_approval_signal_and_max_effort_survive_safe_normalization
test_unavailable_lanes_and_demand_shortage_are_distinct
test_html_is_private_escaped_accessible_and_responsive
test_output_replacement_rejects_symlinks_and_enforces_mode
test_fleet_snapshot_preserves_registered_scope_provenance
