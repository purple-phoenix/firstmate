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
      {"order":1,"state":"in_flight","structured":true,"id":"build-old","title":"Build the alpha subsystem","repo":"alpha","project_resolved":true,"kind":"ship","since":"2026-07-01","body_excerpt":"Acceptance criteria: alpha behavior is tested."},
      {"order":2,"state":"in_flight","structured":true,"id":"validate-now","title":"Validate the beta delivery","repo":"beta","project_resolved":true,"kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: CI is green."},
      {"order":3,"state":"queued","structured":true,"id":"ready-safe","title":"Ship <script>alert(1)</script> token=topsecret AKIAIOSFODNN7EXAMPLE xoxb-123456789012-123456789012-abcdefghijklmnop https://user:pass@example.com 212-555-0199","repo":"gamma","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: bounded regression tests pass."},
      {"order":4,"state":"queued","structured":true,"id":"overlap-alpha","title":"Improve the active alpha subsystem","repo":"alpha","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: alpha remains compatible."},
      {"order":5,"state":"queued","structured":true,"id":"vague","title":"TBD","repo":null,"kind":null,"body_excerpt":"Contact patient@example.com about password=hunter2"},
      {"order":6,"state":"queued","structured":true,"id":"dependency","title":"Publish the dependent release","repo":"epsilon","project_resolved":true,"kind":"ship","blocked_by":"build-old","blocked_reason":"wait for alpha landing","body_excerpt":"Acceptance criteria: release is published."},
      {"order":7,"state":"queued","structured":true,"id":"captain-choice","title":"Choose the rollout policy","repo":"alpha","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"pick conservative or fast rollout for Jane Doe oncology record"},
      {"order":8,"state":"queued","structured":true,"id":"future-gate","title":"Run the migration after 2026-08-01","repo":"zeta","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: migration checks pass."},
      {"order":9,"state":"done","structured":true,"id":"landed-one","title":"Landed useful work","repo":"alpha","project_resolved":true,"kind":"ship","pr_url":"https://github.com/purple-phoenix/firstmate/pull/10","completion":{"verb":"merged","date":"2026-07-16"}}
    ]
  },
  "tasks": [
    {"id":"build-old","kind":"ship","project":"alpha","current_state":{"state":"working","source":"pane","detail":"harness busy"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"build-old","title":"Build the alpha subsystem","repo":"alpha","project_resolved":true,"kind":"ship","since":"2026-07-01"}},
    {"id":"validate-now","kind":"ship","project":"beta","current_state":{"state":"working","source":"run-step","detail":"validating (fixing)"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":"https://github.com/purple-phoenix/firstmate/pull/11"},"paths":{"report":{"present":false}},"backlog":{"id":"validate-now","title":"Validate the beta delivery","repo":"beta","project_resolved":true,"kind":"ship","since":"2026-07-16"}}
  ],
  "scout_reports": [],
  "secondmate_current": {
    "registry": {"available":true,"complete":true,"records":[
      {"id":"design","scope":"design systems","projects":["delta"]},
      {"id":"quiet","scope":"documentation","projects":["docs"]},
      {"id":"unknown-mate","scope":"operations","projects":["ops"]}
    ]},
    "records": [
      {"id":"design","home":"$home/design","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[{"id":"design-ready","title":"Refresh the delta design tokens","repo":"delta","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: token snapshots pass."}],"landed":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":1},"omitted":[]},
      {"id":"quiet","home":"$home/quiet","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[],"landed":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":0},"omitted":[]},
      {"id":"unknown-mate","home":"$home/unknown","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[],"landed":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":0},"omitted":[]}
    ],
    "total": 3,
    "shown": 3,
    "truncated": 0
  },
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
  "secondmates": {
    "design":{"backend":{"name":"tmux","available":true},"github_auth":{"status":"available"},"dispatch":{"config_present":true,"valid":true,"lanes":[{"harness":"codex","effort":"high","when":"default","available":true}]}},
    "quiet":{"backend":{"name":"tmux","available":true},"github_auth":{"status":"available"},"dispatch":{"config_present":true,"valid":true,"lanes":[{"harness":"codex","effort":"high","when":"default","available":true}]}},
    "unknown-mate":{"backend":{"name":"tmux","available":true},"github_auth":{"status":"available"},"dispatch":{"config_present":true,"valid":true,"lanes":[{"harness":"codex","effort":"high","when":"default","available":true}]}}
  }
}
EOF
}

test_skill_discovery_and_read_mostly_contract() {
  local help
  assert_present "$SKILL" "capacity SKILL.md is missing"
  assert_grep 'name: capacity' "$SKILL" "capacity skill frontmatter has the wrong name"
  assert_grep 'user-invocable: true' "$SKILL" "capacity skill is not captain-invocable"
  assert_grep 'capacity, bottlenecks, pipeline utilization, work supply, idle lanes, or maximizing fleet throughput' "$SKILL" "capacity natural-language trigger is incomplete"
  assert_grep "single owner of Firstmate's conditional capacity procedure" "$SKILL" "capacity skill does not declare its one-owner contract"
  assert_grep "load \`capacity\`" "$ROOT/AGENTS.md" "AGENTS.md lacks the capacity load trigger"
  assert_grep 'must never invent work, dispatch for utilization, or weaken lifecycle safety' "$ROOT/AGENTS.md" "AGENTS.md lacks the capacity safety stub"
  assert_grep "| \`/capacity\`" "$ROOT/README.md" "README does not list /capacity"
  assert_grep 'Do not invoke, depend on, open, poll, share, or embed Lavish' "$SKILL" "capacity skill does not forbid Lavish"
  assert_grep 'must not dispatch, merge, tear down, mutate task state, edit the backlog' "$SKILL" "capacity read-mostly boundary is incomplete"
  help=$("$CAPACITY" --help) || fail "capacity help failed"
  assert_contains "$help" 'MODEL fm-capacity.v1' "capacity help omits the model contract"
  assert_contains "$help" 'at most 20' "capacity help omits the inherited home bound"
  assert_contains "$help" 'bound each structured-home read to 8 seconds' "capacity help omits the inherited probe timeout"
  assert_contains "$help" "request each included home's complete landed record" "capacity help omits full recurring-history lookup"
  assert_contains "$help" 'exceeds the time or byte' "capacity help hides the remaining full-history bound"
  assert_contains "$help" 'bound makes that home unavailable' "capacity help hides the full-history bound consequence"
  assert_grep 'FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME: "0"' "$CAPACITY" "capacity does not request complete secondmate landed history"
  assert_contains "$help" 'does not impose a shorter aggregate timeout' "capacity help permits wrapper timeout regression"
  assert_contains "$help" 'share one 30-second fleet-wide' "capacity help omits the environment deadline"
  assert_contains "$help" '10 CAP-02 credentials' "capacity help omits bottleneck priority"
  assert_contains "$help" '80 CAP-08 demand shortage' "capacity help omits the complete priority order"
  assert_contains "$help" 'CAP IDs are discussion handles only' "capacity help omits stable action semantics"
  pass "capacity is discoverable and its conditional read-mostly procedure has one owner"
}

test_classification_priority_overlap_and_idle_semantics() {
  local home="$TMP_ROOT/model-home" snapshot="$TMP_ROOT/model-snapshot.json" environment="$TMP_ROOT/model-environment.json" output="$TMP_ROOT/model-home/data/model.html" json ids
  make_fixture "$home" "$snapshot" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "capacity fixture run failed"
  printf '%s' "$json" | jq -e '
    .schema == "fm-capacity.v1"
    and .measures.useful_ready_work == 2
    and .readiness.independent_start_count == 2
    and .readiness.available == true
    and (.pipeline.ready | length) == 2
    and (.readiness.conservative_overlap_gates | length) == 1
    and (.readiness.explicit_gates | any(.reason == "Blocked by item-01"))
    and (.readiness.explicit_gates | any(.reason == "time gate until 2026-08-01"))
    and (.readiness.definition_gaps | any(.gaps | index("project unresolved")))
    and (.lanes.persistent_secondmates | any(.utilization == "idle with grounded ready in-scope work"))
    and ([.lanes.persistent_secondmates[] | select(.utilization | startswith("healthy idle"))] | length) == 2
    and .primary_bottleneck.id == "CAP-09"
    and (.recommendations | any(.id == "CAP-01" and .classification == "captain-held decisions"))
    and (.recommendations | any(.id == "CAP-04" and .classification == "definition shortage"))
    and (.recommendations | any(.id == "CAP-05" and .classification == "overlap serialization"))
    and (.recommendations | any(.id == "CAP-06" and .classification == "execution shortage"))
    and (.recommendations | any(.id == "CAP-07" and .classification == "validation, CI, or approval"))
    and (.recommendations | any(.id == "CAP-10" and .classification == "aging flow"))
  ' >/dev/null || fail "capacity classifications or priority are wrong: $json"
  ids=$(printf '%s' "$json" | jq -c '[.recommendations[].id]')
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "capacity repeat run failed"
  [ "$ids" = "$(printf '%s' "$json" | jq -c '[.recommendations[].id]')" ] || fail "capacity action IDs are not deterministic"
  pass "capacity classifies supply, overlap, blockers, secondmate idle state, aging, and stable action priority"
}

test_cross_home_overlap_holds_supersession_and_active_count() {
  local home="$TMP_ROOT/cross-home" snapshot="$TMP_ROOT/cross-snapshot.json" environment="$TMP_ROOT/cross-environment.json" output="$TMP_ROOT/cross-home/data/cross.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records += [
      {"order":10,"state":"in_flight","structured":true,"id":"main-held","title":"Hold the lambda delivery","repo":"lambda","project_resolved":true,"kind":"ship","since":"2026-07-10","body_excerpt":"Acceptance criteria: lambda is complete."},
      {"order":11,"state":"queued","structured":true,"id":"main-held-overlap","title":"Extend the held lambda delivery","repo":"lambda","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: lambda remains compatible."},
      {"order":12,"state":"queued","structured":true,"id":"mate-held-overlap","title":"Extend the held iota delivery","repo":"iota","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: iota remains compatible."}
    ]
    | .tasks += [
      {"id":"main-held","kind":"ship","project":"lambda","current_state":{"state":"blocked","source":"run-step","detail":"external wait"},"endpoint":{"exists":true},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"main-held","title":"Hold the lambda delivery","repo":"lambda","project_resolved":true,"kind":"ship","since":"2026-07-10"}}
    ]
    | .secondmate_current.records[0].active_children = [
      {"id":"child-gamma","repo":"gamma","project_resolved":true,"kind":"ship","state":"working","doing":"working"},
      {"id":"child-theta","repo":"theta","project_resolved":true,"kind":"ship","state":"working","doing":"working"}
    ]
    | .secondmate_current.records[0].holds = [
      {"id":"held-old","title":"Sensitive held work","repo":"iota","project_resolved":true,"kind":"ship","since":"2026-07-01","reason":"external dependency","source":"child-state"}
    ]
    | .secondmate_current.records[0].queued += [
      {"id":"held-old","title":"Sensitive held work","repo":"iota","project_resolved":true,"kind":"ship","since":"2026-07-01","blocked_by":"external"},
      {"id":"superseded","title":"Do not start this deferred item","repo":"kappa","project_resolved":true,"kind":"ship","body_excerpt":"DEFERRED. Acceptance criteria: none."}
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
  local home="$TMP_ROOT/final-ready-home" snapshot="$TMP_ROOT/final-ready-snapshot.json" environment="$TMP_ROOT/final-ready-environment.json" output="$TMP_ROOT/final-ready-home/data/final-ready.html" json
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

test_secondmate_readiness_uses_home_owned_runtime_lanes() {
  local home="$TMP_ROOT/mate-lane-home" snapshot="$TMP_ROOT/mate-lane-snapshot.json" environment="$TMP_ROOT/mate-lane-environment.json" output="$TMP_ROOT/mate-lane-home/data/mate-lane.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .secondmates.design.backend.available = false
    | .secondmates.design.dispatch.lanes[0].available = false
  ' "$environment" > "$environment.tmp"
  mv "$environment.tmp" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "secondmate unavailable-lane capacity run failed"
  printf '%s' "$json" | jq -e '
    (.lanes.persistent_secondmates | any(
      .grounded_ready_in_scope == 1
      and .ready_in_scope == 0
      and .runtime.backend.available == false
      and .utilization == "unavailable lane with grounded in-scope work"
    ))
    and (.recommendations | any(.id == "CAP-09"))
    and (.recommendations[] | select(.id == "CAP-09") | .evidence | contains("1 has grounded work on an unavailable home-owned lane"))
  ' >/dev/null || fail "secondmate home-owned runtime lane was not reflected in readiness: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmates.design.github_auth.status = "unavailable"' "$environment" > "$environment.tmp"
  mv "$environment.tmp" "$environment"
  jq '.secondmate_current.records[0].queued[0].delivery_mode = "local-only"' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "secondmate local-only capacity run failed"
  printf '%s' "$json" | jq -e '
    (.lanes.persistent_secondmates | any(
      .grounded_ready_in_scope == 1
      and .ready_in_scope == 1
      and .runtime.github_auth.status == "unavailable"
      and .utilization == "idle with grounded ready in-scope work"
    ))
    and (.pipeline.ready | any(.owner == "persistent home-01"))
  ' >/dev/null || fail "local-only secondmate work was incorrectly gated on GitHub auth: $json"

  jq '.secondmate_current.records[0].queued[0].delivery_mode = "direct-PR"' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "secondmate PR-bound capacity run failed"
  printf '%s' "$json" | jq -e '
    (.lanes.persistent_secondmates | any(
      .grounded_ready_in_scope == 1
      and .ready_in_scope == 0
      and .runtime.github_auth.status == "unavailable"
      and .utilization == "unavailable lane with grounded in-scope work"
    ))
    and (.recommendations[] | select(.id == "CAP-02") | .evidence | contains("persistent home-01 (unavailable)"))
    and (.recommendations[] | select(.id == "CAP-09") | .evidence | contains("1 has grounded work on an unavailable home-owned lane"))
  ' >/dev/null || fail "PR-bound secondmate work ignored unavailable GitHub auth: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [.backlog.records[] | select(.state == "done")]
    | .tasks = []
    | .secondmate_current.records[0].queued[0].delivery_mode = "direct-PR"
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  jq '.github_auth.status = "unavailable"' "$environment" > "$environment.tmp"
  mv "$environment.tmp" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "cross-home credential attribution capacity run failed"
  printf '%s' "$json" | jq -e '
    (.recommendations | any(.id == "CAP-02") | not)
    and (.lanes.persistent_secondmates | any(
      .grounded_ready_in_scope == 1
      and .ready_in_scope == 1
      and .runtime.github_auth.status == "available"
    ))
    and (.recommendations | any(.id == "CAP-06"))
  ' >/dev/null || fail "main-home auth was attributed to secondmate-owned PR work: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [.backlog.records[] | select(.state == "done")]
    | .tasks = []
    | .secondmate_current.records[0].current.state = "active_child_work"
    | .secondmate_current.records[0].active_children = [
      {"id":"active-pr","repo":"delta","project_resolved":true,"kind":"ship","delivery_mode":"direct-PR","state":"working","doing":"implementing"}
    ]
    | .secondmate_current.records[0].queued = []
    | .secondmate_current.records[0].counts.active_children = 1
    | .secondmate_current.records[0].counts.queued = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  jq '.secondmates.design.github_auth.status = "unavailable"' "$environment" > "$environment.tmp"
  mv "$environment.tmp" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "active secondmate credential capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.building | any(.delivery_mode == "direct-PR"))
    and (.lanes.persistent_secondmates | any(
      .active_children == 1
      and .utilization == "active with unavailable delivery credentials"
    ))
    and (.recommendations[] | select(.id == "CAP-02") | .evidence | contains("persistent home-01 (unavailable)"))
  ' >/dev/null || fail "active secondmate PR delivery did not retain home-owned credential evidence: $json"

  jq '
    .secondmates.design.github_auth.status = "available"
    | .secondmates.design.backend.available = false
  ' "$environment" > "$environment.tmp"
  mv "$environment.tmp" "$environment"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "active secondmate runtime capacity run failed"
  printf '%s' "$json" | jq -e '
    (.recommendations | any(.id == "CAP-02") | not)
    and (.lanes.persistent_secondmates | any(
      .active_children == 1
      and .utilization == "active with unavailable execution lane"
    ))
    and (.recommendations[] | select(.id == "CAP-09") | .evidence | contains("1 active secondmate has an unavailable home-owned runtime lane"))
  ' >/dev/null || fail "active secondmate runtime lane failure was not surfaced: $json"
  pass "secondmate readiness includes home-owned backend, auth, and dispatch evidence"
}

test_incomplete_sources_fail_closed() {
  local home="$TMP_ROOT/incomplete-home" snapshot="$TMP_ROOT/incomplete-snapshot.json" environment="$TMP_ROOT/incomplete-environment.json" output="$TMP_ROOT/incomplete-home/data/incomplete.html"
  local history="$TMP_ROOT/incomplete-home/data/capacity-wait-history.json" json
  make_fixture "$home" "$snapshot" "$environment"
  printf '%s\n' '{"schema":"fm-capacity-wait-history.v1","active":{"design/missing:validation":{"kind":"validation","first_observed":1000,"last_observed":1600}},"durations":{}}' > "$history"
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
  jq -e '
    .active["design/missing:validation"].last_observed == 1600
    and (.durations.validation == null)
  ' "$history" >/dev/null || fail "truncated inventory retired an unobserved active wait: $(cat "$history")"

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

  make_fixture "$home" "$snapshot" "$environment"
  printf '%s\n' '{"schema":"fm-capacity-wait-history.v1","active":{"main/validate-now:validation":{"kind":"validation","first_observed":1000,"last_observed":1600}},"durations":{}}' > "$history"
  jq '.tasks = [.tasks[] | select(.id != "validate-now")]' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "missing main task capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false' >/dev/null ||
    fail "missing in-flight main task did not suppress readiness: $json"
  jq -e '
    .active["main/validate-now:validation"].last_observed == 1600
    and (.durations.validation == null)
  ' "$history" >/dev/null || fail "missing main task retired an unobserved active wait: $(cat "$history")"

  make_fixture "$home" "$snapshot" "$environment"
  jq '(.tasks[] | select(.id == "validate-now") | .current_state.state) = "unknown"' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "unknown main task state capacity run failed"
  printf '%s' "$json" | jq -e '.readiness.available == false' >/dev/null ||
    fail "unknown main task state did not suppress readiness: $json"
  jq -e '
    .active["main/validate-now:validation"].last_observed == 1600
    and (.durations.validation == null)
  ' "$history" >/dev/null || fail "unknown main task state retired an unobserved active wait: $(cat "$history")"
  pass "capacity suppresses readiness and demand claims for incomplete bounded sources"
}

test_unresolved_active_projects_fail_closed() {
  local home="$TMP_ROOT/project-gap-home" snapshot="$TMP_ROOT/project-gap-snapshot.json" environment="$TMP_ROOT/project-gap-environment.json" output="$TMP_ROOT/project-gap-home/data/project-gap.html" json
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
  local home="$TMP_ROOT/markers-home" snapshot="$TMP_ROOT/markers-snapshot.json" environment="$TMP_ROOT/markers-environment.json" output="$TMP_ROOT/markers-home/data/markers.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records += [
      {"order":10,"state":"queued","structured":true,"id":"latest-only","title":"Use the latest version safely","repo":"eta","project_resolved":true,"kind":"ship","body_excerpt":"Use the latest version with compatibility checks."},
      {"order":11,"state":"queued","structured":true,"id":"version-date","title":"Support Version 2026-08-01 compatibility","repo":"theta","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: compatibility remains intact."},
      {"order":12,"state":"queued","structured":true,"id":"word-substrings","title":"Support the nondeferred aftercare workflow","repo":"iota","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: aftercare remains compatible with the nondeferred workflow."},
      {"order":13,"state":"queued","structured":true,"id":"placeholder-criteria","title":"Implement the placeholder-defined workflow","repo":"kappa","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: TBD"},
      {"order":14,"state":"queued","structured":true,"id":"negated-criteria","title":"Implement the undefined acceptance workflow","repo":"mu","project_resolved":true,"kind":"ship","body_excerpt":"No acceptance criteria defined"},
      {"order":15,"state":"queued","structured":true,"id":"defined-later","title":"Implement the later-defined workflow","repo":"nu","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: to be defined"},
      {"order":16,"state":"queued","structured":true,"id":"forthcoming-criteria","title":"Implement the forthcoming workflow","repo":"omicron","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: forthcoming"},
      {"order":17,"state":"queued","structured":true,"id":"dated-compatibility","title":"Render correctly on 2026-08-01","repo":"pi","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: rendering works on 2026-08-01."},
      {"order":18,"state":"queued","structured":true,"id":"noun-criteria","title":"Protect failover data integrity","repo":"rho","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: zero data loss under failover."},
      {"order":19,"state":"queued","structured":true,"id":"modal-criteria","title":"Export reports as portable documents","repo":"sigma","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: users can export PDF."},
      {"order":20,"state":"queued","structured":true,"id":"todo-with-verb","title":"Implement the unfinished test workflow","repo":"tau","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: TODO: tests pass eventually."},
      {"order":21,"state":"queued","structured":true,"id":"not-defined","title":"Implement the explicitly undefined workflow","repo":"upsilon","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: not defined."},
      {"order":22,"state":"queued","structured":true,"id":"none-defined","title":"Implement the absent criteria workflow","repo":"phi","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: none provided."},
      {"order":23,"state":"queued","structured":true,"id":"not-applicable","title":"Implement the inapplicable criteria workflow","repo":"chi","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: n/a pending review."},
      {"order":24,"state":"queued","structured":true,"id":"after-login","title":"Load the dashboard after login","repo":"psi","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: the dashboard loads after login."},
      {"order":25,"state":"queued","structured":true,"id":"empty-criteria-section","title":"Implement the undecided notes workflow","repo":"omega","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria:\nNotes: pending captain input"},
      {"order":26,"state":"queued","structured":true,"id":"listed-criteria","title":"Implement the listed acceptance workflow","repo":"alpha-two","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria:\n- regression checks pass"}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "definition-marker capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.useful_ready_work == 9
    and ([.readiness.definition_gaps[] | select(.gaps | index("acceptance criteria missing"))] | length) == 11
    and ([.readiness.definition_gaps[] | select(.gaps | index("dependency definition missing"))] | length) == 0
    and ([.readiness.explicit_gates[] | select(.reason == "time gate until 2026-08-01")] | length) == 1
  ' >/dev/null || fail "acceptance or time-gate substring produced false evidence: $json"
  pass "capacity requires explicit acceptance and whole-word time-gate markers"
}

test_secondmate_scope_is_required_for_lane_readiness() {
  local home="$TMP_ROOT/scope-home" snapshot="$TMP_ROOT/scope-snapshot.json" environment="$TMP_ROOT/scope-environment.json" output="$TMP_ROOT/scope-home/data/scope.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_current.registry.records[0].scope = null' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "missing-scope capacity run failed"
  printf '%s' "$json" | jq -e '
    .readiness.available == false
    and .measures.useful_ready_work == 0
    and (.lanes.persistent_secondmates | any(
      .scope == "Registered routing scope unavailable"
      and .ready_in_scope == 0
      and .utilization == "unavailable"
    ))
    and (.recommendations | any(.id == "CAP-03"))
    and (.recommendations | any(.id == "CAP-06") | not)
    and (.recommendations | any(.id == "CAP-09") | not)
  ' >/dev/null || fail "secondmate work was called in-scope without registered scope evidence: $json"
  pass "secondmate lane readiness requires registered scope provenance"
}

test_ready_selection_preserves_priority_and_order() {
  local home="$TMP_ROOT/order-home" snapshot="$TMP_ROOT/order-snapshot.json" environment="$TMP_ROOT/order-environment.json" output="$TMP_ROOT/order-home/data/order.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [
      {"order":1,"priority":"low","state":"queued","structured":true,"id":"lexically-first","title":"Ship the lower priority option","repo":"shared","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: lower option passes."},
      {"order":2,"priority":"high","state":"queued","structured":true,"id":"lexically-second","title":"Ship the higher priority option","repo":"shared","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: higher option passes."}
    ]
    | .tasks = []
    | .secondmate_current.registry.records = []
    | .secondmate_current.records = []
    | .secondmate_current.total = 0
    | .secondmate_current.shown = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "priority selection capacity run failed"
  printf '%s' "$json" | jq -e '.pipeline.ready[0].id == "item-02" and .pipeline.queued[0].id == "item-01"' >/dev/null ||
    fail "higher-priority work did not win conservative serialization: $json"

  jq '
    .backlog.records[0].priority = null
    | .backlog.records[0].order = 2
    | .backlog.records[1].priority = null
    | .backlog.records[1].order = 1
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "backlog-order selection capacity run failed"
  printf '%s' "$json" | jq -e '.pipeline.ready[0].id == "item-02" and .pipeline.queued[0].id == "item-01"' >/dev/null ||
    fail "earlier authoritative backlog order did not win conservative serialization: $json"

  jq '
    .backlog.records = [
      {"order":1,"priority":"low","state":"queued","structured":true,"id":"main-shared","title":"Ship the main shared-project option","repo":"shared","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: main shared option passes."}
    ]
    | .secondmate_current.registry.records = [
      {"id":"design","scope":"design systems","projects":["shared"]}
    ]
    | .secondmate_current.records = [
      {"id":"design","current":{"state":"no_active_work"},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"holds":[],"queued":[
        {"order":1,"priority":"high","id":"mate-shared","title":"Ship the secondmate shared-project option","repo":"shared","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: secondmate shared option passes."}
      ],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":1},"omitted":[]}
    ]
    | .secondmate_current.total = 1
    | .secondmate_current.shown = 1
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "cross-home priority capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.useful_ready_work == 0
    and (.readiness.conservative_overlap_gates | length) == 2
    and ([.readiness.conservative_overlap_gates[] | select(.reason == "cross-home project overlap requires routing decision")] | length) == 2
    and (.recommendations | any(.id == "CAP-06") | not)
  ' >/dev/null || fail "cross-home priorities invented an authoritative fleet-wide winner: $json"
  pass "ready serialization preserves authoritative priority and backlog order"
}

test_recent_landings_report_incomplete_projection() {
  local home="$TMP_ROOT/landings-home" snapshot="$TMP_ROOT/landings-snapshot.json" environment="$TMP_ROOT/landings-environment.json" output="$TMP_ROOT/landings-home/data/landings.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '.secondmate_landed.truncated = ["design"] | .secondmate_landed.unreadable = ["quiet"]' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "incomplete-landings capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.recently_landed_complete == false
    and (.provenance.recent_landings | contains("observed lower bound"))
    and (.omissions | any(contains("observed lower bound")))
  ' >/dev/null || fail "incomplete recent landings were presented as complete: $json"
  assert_grep 'Recently landed (observed; incomplete)' "$output" "dashboard did not qualify incomplete recent landings"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.backlog.present = false | .backlog.records = []' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "missing-main-landings capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.recently_landed_complete == false
    and (.provenance.recent_landings | startswith("Main backlog completion evidence is incomplete"))
    and (.provenance.recent_landings | contains("secondmate") | not)
  ' >/dev/null || fail "missing main landing source was presented as complete: $json"

  make_fixture "$home" "$snapshot" "$environment"
  jq '.backlog.records += [{"order":10,"state":"done","structured":false,"id":null,"raw":"legacy completion"}]' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "unstructured-main-landings capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.recently_landed_complete == false
    and (.provenance.recent_landings | startswith("Main backlog completion evidence is incomplete"))
  ' >/dev/null || fail "omitted unstructured main landing was presented as complete: $json"
  pass "recent landing counts expose bounded projection incompleteness"
}

test_secondmate_captain_holds_are_pipeline_waiting_work() {
  local home="$TMP_ROOT/captain-hold-home" snapshot="$TMP_ROOT/captain-hold-snapshot.json" environment="$TMP_ROOT/captain-hold-environment.json" output="$TMP_ROOT/captain-hold-home/data/captain-hold.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .tasks[0].hints.open_decisions = [
      {"key":"default"},
      {"key":"build-choice-one"},
      {"key":"build-choice-two"}
    ]
    |
    .secondmate_current.records[0].decisions_open = [
      {"id":"mate-question","key":"default","verb":"needs-decision","summary":"Sensitive question","source":"child-state"},
      {"id":"mate-choice","key":"mate-choice","verb":"captain-hold","summary":"Sensitive choice","source":"backlog"}
    ]
    | .secondmate_current.records[0].holds = [
      {"id":"mate-held","title":"Wait for external completion","repo":"delta","project_resolved":true,"kind":"ship","since":"2026-07-20","state":"blocked","source":"child-state"},
      {"id":"mate-pr-held","title":"Wait for pull request approval","repo":"delta","project_resolved":true,"kind":"ship","since":"2026-07-21","state":"paused","reason":"PR awaiting merge approval","pr_present":true,"source":"child-state"},
      {"id":"mate-audit-idea","title":"Feature (queued): shared review workspace","repo":"delta","project_resolved":true,"kind":"ship","since":"2026-07-22","reason":"Audit feature opportunity","source":"backlog"}
    ]
    | .secondmate_current.records[0].queued += [
      {"id":"mate-choice","title":"Choose the secondmate rollout","repo":"delta","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"Sensitive reason"},
      {"id":"mate-audit-idea","title":"Feature (queued): shared review workspace","repo":"delta","project_resolved":true,"kind":"ship","since":"2026-07-22","hold_kind":"captain","hold_reason":"Audit feature opportunity - queued for captain prioritization","body_excerpt":"Acceptance criteria: workspace carries context."},
      {"id":"mate-structured","title":"Wait on a structured hold","repo":"delta","project_resolved":true,"kind":"ship","hold_reason":"Sensitive reason"},
      {"id":"mate-time","title":"Resume after 2026-08-15","repo":"delta","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: resume safely."},
      {"id":"after-mate-held","title":"Continue after held work","repo":"delta","project_resolved":true,"kind":"ship","blocked_by":"mate-held","body_excerpt":"Acceptance criteria: held work clears."}
    ]
    | .secondmate_current.records[0].decisions_open[0].id = "mate-held"
    | .secondmate_current.records[0].counts = {"active_children":0,"decisions_open":2,"holds":3,"queued":6}
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "secondmate captain-hold capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.blocked | length) == 11
    and .measures.open_captain_actions == 6
    and (.recommendations[] | select(.id == "CAP-01") | .evidence | startswith("4 structured captain"))
    and ([.pipeline.blocked[] | select(.owner | contains("persistent"))] | length) == 7
    and ([.pipeline.blocked[] | select(.owner | contains("persistent")) | .what_you_can_do] | all(type == "string" and length > 0))
    and ([.pipeline.blocked[] | select((.owner | contains("persistent")) and .captain_gate == true and .what_you_can_do == "Review and merge its open pull request - this wait is on you, not an automatic process.")] | length) == 1
    and (.pipeline.blocked | any(
      (.owner | contains("persistent"))
      and .captain_gate == true
      and .reason == "Waiting on your go"
      and .wait.class == "needs_actor"
      and ((.waits_on | join(" ")) | contains("held for your prioritization"))
      and (. as $card | $card.what_you_can_do | contains($card.id))
      and ((.what_you_can_do | test("Nothing yet"; "i")) | not)))
    and ([.pipeline.blocked[] | select((.owner | contains("persistent")) and .captain_gate == true) | tostring] | all(contains("http") | not))
    and ([.pipeline.blocked[] | select(.owner | contains("persistent")) | .waits_on // [] | join(" ")] | map(select(contains("worker question"))) | length) == 2
  ' >/dev/null || fail "secondmate captain hold was missing or double-counted: $json"
  [ "$(grep -o 'class="verb verb-decide"' "$output" | wc -l | tr -d ' ')" = 4 ] ||
    fail "captain decisions were collapsed or duplicated in the needs-you roll call"
  [ "$(grep -o '<span class="verb verb-decide">Decide</span><span class="who"><span class="item-id">item-' "$output" | wc -l | tr -d ' ')" = 4 ] ||
    fail "captain decision rows do not each expose an opaque item ID"
  assert_grep 'Open decision raised by work already under way.' "$output" "open captain decisions lack a privacy-safe reason"
  assert_grep 'A queued choice is held for your decision.' "$output" "queued captain hold lacks a privacy-safe reason"
  assert_no_grep '>4 more<' "$output" "captain decisions were replaced by an anonymous aggregate"
  pass "captain actions retain item-level identity and privacy-safe reasons"
}

test_approval_signal_and_max_effort_survive_safe_normalization() {
  local home="$TMP_ROOT/approval-home" snapshot="$TMP_ROOT/approval-snapshot.json" environment="$TMP_ROOT/approval-environment.json" output="$TMP_ROOT/approval-home/data/approval.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [
      {"order":1,"state":"in_flight","structured":true,"id":"approval-ready","title":"Finish the approval-ready delivery","repo":"omega","project_resolved":true,"kind":"ship","since":"2026-07-01","body_excerpt":"Acceptance criteria: CI passes."}
    ]
    | .tasks = [
      {"id":"approval-ready","kind":"ship","mode":"no-mistakes","yolo":"off","project":"omega","current_state":{"state":"done","source":"run-step","detail":"PR checks green for Jane Doe"},"endpoint":{"exists":true},"hints":{"open_decisions":[]},"pr":{"url":"https://example.invalid/private"},"paths":{"report":{"present":false}},"backlog":{"id":"approval-ready","title":"Finish the approval-ready delivery","repo":"omega","project_resolved":true,"kind":"ship","since":"2026-07-01"}}
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
    and (.aging | any(.state == "done" and .age_days == 16))
    and (.recommendations | any(.id == "CAP-10"))
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

  jq '.tasks[0].yolo = "on"' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "yolo approval capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.pr_ci_approval | any(.approval_ready == true and .approval_authority == "firstmate" and .captain_approval_required == false))
    and .measures.open_captain_actions == 0
    and (.recommendations[] | select(.id == "CAP-07") | .evidence | contains("0 require captain approval"))
  ' >/dev/null || fail "yolo approval was misattributed to the captain: $json"
  pass "approval readiness and supported max effort survive safe normalization"
}

test_unavailable_lanes_and_demand_shortage_are_distinct() {
  local home="$TMP_ROOT/empty-home" snapshot="$TMP_ROOT/empty-snapshot.json" environment="$TMP_ROOT/empty-environment.json" output="$TMP_ROOT/empty-home/data/empty.html" json
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$snapshot" <<EOF
{"schema":"fm-fleet-snapshot.v1","generated":"2026-07-17T16:00:00Z","fm_home":"$home","roots":{"fm_root":"$ROOT","state":"$home/state","data":"$home/data","config":"$home/config","projects":"$home/projects"},"backlog":{"present":true,"records":[]},"tasks":[],"scout_reports":[],"secondmate_current":{"registry":{"available":true,"complete":true,"records":[]},"records":[],"total":0,"shown":0,"truncated":0},"secondmate_landed":{"records":[],"truncated":[],"unreadable":[]}}
EOF
  cat > "$environment" <<'EOF'
{"backend":{"name":"orca","available":false,"evidence":"orca executable missing"},"github_auth":{"status":"unavailable","evidence":"login required"},"dispatch":{"config_present":true,"valid":true,"lanes":[{"harness":"codex","available":false,"availability_evidence":"configured harness executable missing","quota":"not observed - capacity never guesses quota"}]}}
EOF
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "empty capacity run failed"
  printf '%s' "$json" | jq -e '
    .primary_bottleneck.id == "CAP-08"
    and (.recommendations | any(.id == "CAP-08" and .classification == "demand shortage"))
    and (.recommendations | any(.id == "CAP-02") | not)
    and (.recommendations | any(.id == "CAP-09") | not)
    and .lanes.ephemeral_workers.github_auth.status == "unavailable"
    and .lanes.ephemeral_workers.backend.available == false
  ' >/dev/null || fail "idle lane maintenance displaced true demand shortage: $json"

  jq '
    .backlog.records = [
      {"order":1,"state":"in_flight","structured":true,"id":"pr-bound","title":"Complete the PR-bound delivery","repo":"omega","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: delivery checks pass."}
    ]
    | .tasks = [
      {"id":"pr-bound","kind":"ship","mode":"no-mistakes","project":"omega","current_state":{"state":"working","source":"pane","detail":"implementing"},"endpoint":{"exists":true},"hints":{"open_decisions":[]},"pr":{"url":null},"backlog":{"id":"pr-bound","repo":"omega","project_resolved":true,"kind":"ship"}}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "blocked-delivery lane capacity run failed"
  printf '%s' "$json" | jq -e '
    .primary_bottleneck.id == "CAP-02"
    and (.recommendations | any(.id == "CAP-02"))
    and (.recommendations | any(.id == "CAP-09"))
    and (.recommendations[] | select(.id == "CAP-09") | .safety_authority_boundary | contains("Quota is explicitly unobserved"))
  ' >/dev/null || fail "lane repairs were not recommended for grounded blocked delivery: $json"

  jq '
    .backlog.records = [
      {"order":1,"state":"queued","structured":true,"id":"queued-pr","title":"Ship the queued PR-bound delivery","repo":"omega","project_resolved":true,"kind":"ship","delivery_mode":"direct-PR","body_excerpt":"Acceptance criteria: delivery checks pass."}
    ]
    | .tasks = []
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "queued PR-bound capacity run failed"
  printf '%s' "$json" | jq -e '
    (.recommendations | any(.id == "CAP-02"))
    and (.pipeline.ready | length) == 1
    and (.recommendations | any(.id == "CAP-06") | not)
  ' >/dev/null || fail "queued PR-bound work did not make authentication relevant: $json"

  jq '
    .backlog.records = [
      {"order":1,"state":"done","structured":true,"id":"landed-pr","title":"Landed the completed PR delivery","repo":"omega","project_resolved":true,"kind":"ship","delivery_mode":"no-mistakes","completion":{"verb":"merged","date":"2026-07-17"}}
    ]
    | .tasks = [
      {"id":"landed-pr","kind":"ship","mode":"no-mistakes","project":"omega","current_state":{"state":"done","source":"run-step","detail":"merged"},"endpoint":{"exists":false},"hints":{"open_decisions":[]},"pr":{"url":"https://example.invalid/merged"},"backlog":{"id":"landed-pr","state":"done","repo":"omega","project_resolved":true,"kind":"ship"}}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "landed PR capacity run failed"
  printf '%s' "$json" | jq -e '(.recommendations | any(.id == "CAP-02") | not)' >/dev/null ||
    fail "landed terminal work triggered credential repair: $json"
  pass "capacity recommends lane repairs only for grounded delivery demand"
}

test_blocked_tasks_suppress_demand_shortage() {
  local home="$TMP_ROOT/blocked-home" snapshot="$TMP_ROOT/blocked-snapshot.json" environment="$TMP_ROOT/blocked-environment.json" output="$TMP_ROOT/blocked-home/data/blocked.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [
      {"order":1,"state":"in_flight","structured":true,"id":"blocked-task","title":"Complete the externally blocked delivery","repo":"omega","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: delivery checks pass."}
    ]
    | .tasks = [
      {"id":"blocked-task","kind":"ship","project":"omega","current_state":{"state":"blocked","source":"run-step","detail":"external wait"},"endpoint":{"exists":true},"hints":{"open_decisions":[]},"pr":{"url":null},"backlog":{"id":"blocked-task","repo":"omega","project_resolved":true,"kind":"ship"}}
    ]
    | .secondmate_current.registry.records = []
    | .secondmate_current.records = []
    | .secondmate_current.total = 0
    | .secondmate_current.shown = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "blocked-task capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.blocked | length) == 1
    and (.recommendations | any(.id == "CAP-05" and .classification == "task dependencies and gates"))
    and (.recommendations | any(.id == "CAP-08") | not)
  ' >/dev/null || fail "blocked task was misclassified as demand shortage: $json"
  pass "blocked task stages suppress demand shortage and surface gate work"
}

test_available_ready_work_is_execution_shortage() {
  local home="$TMP_ROOT/execution-home" snapshot="$TMP_ROOT/execution-snapshot.json" environment="$TMP_ROOT/execution-environment.json" output="$TMP_ROOT/execution-home/data/execution.html" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [
      {"order":1,"state":"queued","structured":true,"id":"ready-task","title":"Ship the independently ready delivery","repo":"omega","project_resolved":true,"kind":"ship","delivery_mode":"local-only","body_excerpt":"Acceptance criteria: delivery checks pass."}
    ]
    | .tasks = []
    | .secondmate_current.registry.records = []
    | .secondmate_current.records = []
    | .secondmate_current.total = 0
    | .secondmate_current.shown = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "execution-shortage capacity run failed"
  printf '%s' "$json" | jq -e '
    .primary_bottleneck.id == "CAP-06"
    and .primary_bottleneck.classification == "execution shortage"
    and (.recommendations | any(.id == "CAP-06" and .classification == "execution shortage"))
    and (.recommendations | any(.id == "CAP-09") | not)
  ' >/dev/null || fail "available ready work was not classified as execution shortage: $json"
  pass "available ready work is classified as execution shortage"
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
  assert_grep 'minmax(0,1fr)' "$output" "dashboard grids lack shrink-safe tracks"
  assert_grep 'overflow-wrap:anywhere' "$output" "dashboard lacks long-token containment"
  assert_grep '@media(max-width:760px)' "$output" "dashboard lacks narrow-width safeguards"
  assert_grep 'prefers-color-scheme: light' "$output" "dashboard lacks a light-mode theme"
  assert_grep '--muted:#66645f;--hair:#e1e0d9;--line:rgba(11,11,11,.10);--blue:#1b5fae;--good:#087708;--warn:#8a6200;--serious:#a54824;--crit:#ae2525' "$output" "light-mode text status tokens are not contrast-safe"
  assert_grep 'class="skip" href="#main"' "$output" "dashboard lacks a keyboard skip link"
  assert_grep '<body class="sev-' "$output" "dashboard lacks the severity-classed alarm band"
  assert_grep 'id="needs-you"' "$output" "dashboard lacks the needs-you roll call"
  assert_grep 'id="blocked-items"' "$output" "dashboard lacks the blocked-items roll call"
  assert_grep 'class="meterbar"' "$output" "dashboard lacks the working-vs-waiting meter"
  assert_grep 'Why it waits' "$output" "dashboard lacks the waiting breakdown"
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
  local output="$home/data/capacity-dashboard.html" history="$home/data/capacity-wait-history.json"
  local target="$TMP_ROOT/symlink-target" redirected="$TMP_ROOT/redirected-data" mode
  make_fixture "$home" "$snapshot" "$environment"
  printf '%s\n' sentinel > "$history"
  if "$CAPACITY" --snapshot "$snapshot" --environment "$environment" --output "$history" >/dev/null 2>&1; then
    fail "capacity accepted its wait history as the dashboard destination"
  fi
  [ "$(cat "$history")" = sentinel ] || fail "dashboard collision changed wait history"
  if "$CAPACITY" --snapshot "$snapshot" --environment "$environment" --output "$output" --refs "$history" >/dev/null 2>&1; then
    fail "capacity accepted its wait history as the refs destination"
  fi
  [ "$(cat "$history")" = sentinel ] || fail "refs collision changed wait history"
  [ ! -e "$output" ] || fail "refs collision wrote the dashboard before refusing"
  rm "$history"
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
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f '%Lp' "$output")
  else
    mode=$(stat -c '%a' "$output")
  fi
  [ "$mode" = 600 ] || fail "capacity dashboard mode is $mode, expected 600"

  rm -rf "$redirected"
  mv "$home/data" "$redirected"
  rm "$redirected/capacity-dashboard.html"
  ln -s "$redirected" "$home/data"
  if "$CAPACITY" --snapshot "$snapshot" --environment "$environment" >/dev/null 2>&1; then
    fail "capacity followed a symlinked dashboard parent"
  fi
  [ ! -e "$redirected/capacity-dashboard.html" ] || fail "capacity wrote through a symlinked dashboard parent"

  rm "$home/data"
  mkdir -p "$redirected/nested-data"
  ln -s "$redirected" "$home/redirected-parent"
  jq --arg data "$home/redirected-parent/nested-data" '.roots.data = $data' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  if "$CAPACITY" --snapshot "$snapshot" --environment "$environment" >/dev/null 2>&1; then
    fail "capacity followed a symlinked dashboard ancestor"
  fi
  [ ! -e "$redirected/nested-data/capacity-dashboard.html" ] || fail "capacity wrote through a symlinked dashboard ancestor"

  local outer_target="$TMP_ROOT/output-outer-target" outer_link="$TMP_ROOT/output-outer-link"
  local linked_home="$outer_link/linked-home"
  mkdir -p "$outer_target/linked-home/data" "$outer_target/linked-home/state" "$outer_target/linked-home/config" "$outer_target/linked-home/projects"
  ln -s "$outer_target" "$outer_link"
  jq --arg home "$linked_home" '
    .fm_home = $home
    | .roots.state = ($home + "/state")
    | .roots.data = ($home + "/data")
    | .roots.config = ($home + "/config")
    | .roots.projects = ($home + "/projects")
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  "$CAPACITY" --snapshot "$snapshot" --environment "$environment" >/dev/null ||
    fail "capacity rejected a canonical home beneath a symlink ancestor"
  [ -f "$outer_target/linked-home/data/capacity-dashboard.html" ] ||
    fail "capacity did not write beneath the canonical protected home"
  pass "capacity atomically replaces regular output, permits canonical ancestors, and rejects internal symlinks"
}

test_fleet_snapshot_preserves_registered_scope_provenance() {
  local home="$TMP_ROOT/registry-home" missing="$TMP_ROOT/missing-secondmate" json
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' '- design - design systems domain (home: '"$missing"'; scope: design systems and UI review; projects: alpha, beta; added 2026-07-17)' > "$home/data/secondmates.md"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-07-17)' > "$home/data/projects.md"
  printf '%s\n' '## Queued' '- [ ] scoped-item - Ship the scoped alpha change (repo: alpha, kind: ship)' '  Acceptance criteria:' '  - focused checks pass' '- [ ] unknown-item - Ship the unknown project change (repo: typo-project, kind: ship)' '  Acceptance criteria:' '  - focused checks pass' > "$home/data/backlog.md"
  json=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-17T16:00:00Z "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "canonical fleet snapshot failed on registry fixture"
  printf '%s' "$json" | jq -e '
    (.secondmate_current.registry.records
      | any(.id == "design" and .summary == "design systems domain" and .scope == "design systems and UI review" and .projects == ["alpha","beta"]))
    and (.backlog.records | any(
      .id == "scoped-item"
      and .delivery_mode == "direct-PR"
      and .project_resolved == true
      and .body_excerpt == "Acceptance criteria:\n- focused checks pass"
    ))
    and (.backlog.records | any(
      .id == "unknown-item"
      and .delivery_mode == "no-mistakes"
      and .project_resolved == false
    ))
  ' >/dev/null || fail "canonical snapshot did not preserve route scope provenance: $json"
  pass "canonical fleet snapshot preserves bounded secondmate summary, scope, and projects"
}

test_unknown_project_is_a_definition_gap() {
  local home="$TMP_ROOT/unresolved-project-home" snapshot="$TMP_ROOT/unresolved-project-snapshot.json" environment="$TMP_ROOT/unresolved-project-environment.json" output json
  output="$home/data/unresolved-project.html"
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [{"order":1,"state":"queued","structured":true,"id":"typo-project","title":"Ship the typo project delivery","repo":"typo-project","project_resolved":false,"kind":"ship","delivery_mode":"no-mistakes","body_excerpt":"Acceptance criteria: delivery checks pass."}]
    | .tasks = []
    | .secondmate_current.registry.records = []
    | .secondmate_current.records = []
    | .secondmate_current.total = 0
    | .secondmate_current.shown = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "unresolved-project capacity run failed"
  printf '%s' "$json" | jq -e '
    .measures.useful_ready_work == 0
    and (.pipeline.ready | length) == 0
    and (.readiness.definition_gaps | any(.gaps | index("project unresolved")))
    and (.recommendations | any(.id == "CAP-04"))
    and (.recommendations | any(.id == "CAP-06") | not)
  ' >/dev/null || fail "unknown project fallback entered ready supply: $json"
  pass "unknown projects remain definition gaps despite safe delivery-mode fallback"
}

test_keyless_questions_and_blocker_chains() {
  local home="$TMP_ROOT/chains-home" snapshot="$TMP_ROOT/chains-snapshot.json" environment="$TMP_ROOT/chains-environment.json" output json html
  output="$home/data/chains.html"
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records = [
      {"order":1,"state":"in_flight","structured":true,"id":"asker","title":"Build the exporter","repo":"alpha","project_resolved":true,"kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: exporter ships."},
      {"order":2,"state":"in_flight","structured":true,"id":"keyed-asker","title":"Build the API","repo":"beta","project_resolved":true,"kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: API ships."},
      {"order":3,"state":"queued","structured":true,"id":"dependent","title":"Publish the dependent release","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"asker","blocked_reason":"needs exporter","body_excerpt":"Acceptance criteria: release ships."},
      {"order":4,"state":"queued","structured":true,"id":"policy-choice","title":"Choose the rollout policy","repo":"alpha","project_resolved":true,"kind":"captain","hold_kind":"captain","hold_reason":"pick conservative or fast"},
      {"order":5,"state":"queued","structured":true,"id":"after-policy","title":"Apply the rollout policy","repo":"delta","project_resolved":true,"kind":"ship","blocked_by":"policy-choice","body_excerpt":"Acceptance criteria: rollout applied."},
      {"order":6,"state":"queued","structured":true,"id":"multi-dependent","title":"Publish after two blockers","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"missing-root","blocked_by_all":["asker","missing-root"],"body_excerpt":"Acceptance criteria: both blockers clear."},
      {"order":7,"state":"queued","structured":true,"id":"deep-dependent","title":"Publish after a deep chain","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"deep-1","body_excerpt":"Acceptance criteria: the full chain clears."},
      {"order":8,"state":"queued","structured":true,"id":"deep-1","title":"Deep dependency one","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"deep-2","body_excerpt":"Acceptance criteria: continue."},
      {"order":9,"state":"queued","structured":true,"id":"deep-2","title":"Deep dependency two","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"deep-3","body_excerpt":"Acceptance criteria: continue."},
      {"order":10,"state":"queued","structured":true,"id":"deep-3","title":"Deep dependency three","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"deep-4","body_excerpt":"Acceptance criteria: continue."},
      {"order":11,"state":"queued","structured":true,"id":"deep-4","title":"Deep dependency four","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"deep-5","body_excerpt":"Acceptance criteria: continue."},
      {"order":12,"state":"queued","structured":true,"id":"deep-5","title":"Deep dependency five","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"deep-6","body_excerpt":"Acceptance criteria: continue."},
      {"order":13,"state":"queued","structured":true,"id":"deep-6","title":"Deep dependency six","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"policy-choice","body_excerpt":"Acceptance criteria: choose policy."},
      {"order":14,"state":"queued","structured":true,"id":"behind-keyed-worker","title":"Publish after the API decision","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"keyed-asker","body_excerpt":"Acceptance criteria: the API decision clears."},
      {"order":15,"state":"done","structured":true,"id":"finished-root","title":"Already finished dependency","repo":"gamma","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: finished."},
      {"order":16,"state":"queued","structured":true,"id":"stale-dependent","title":"Reconcile a stale dependency","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"finished-root","body_excerpt":"Acceptance criteria: stale edge clears."},
      {"order":17,"state":"queued","structured":true,"id":"branching-dependent","title":"Publish after converging branches","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"branch-a,branch-b","blocked_by_all":["branch-a","branch-b"],"body_excerpt":"Acceptance criteria: both branches clear."},
      {"order":18,"state":"queued","structured":true,"id":"branch-a","title":"First decision branch","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"policy-choice","body_excerpt":"Acceptance criteria: choose policy."},
      {"order":19,"state":"queued","structured":true,"id":"branch-b","title":"Second decision branch","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"policy-choice","body_excerpt":"Acceptance criteria: choose policy."},
      {"order":20,"state":"in_flight","structured":true,"id":"mixed-asker","title":"Resolve several worker questions","repo":"alpha","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: all questions resolve."},
      {"order":21,"state":"queued","structured":true,"id":"behind-mixed-worker","title":"Publish after every worker question","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"mixed-asker","body_excerpt":"Acceptance criteria: all roots clear."},
      {"order":22,"state":"queued","structured":true,"id":"cycle-dependent","title":"Reconcile sibling cycle","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"cycle-a,cycle-b","blocked_by_all":["cycle-a","cycle-b"],"body_excerpt":"Acceptance criteria: cycle clears."},
      {"order":23,"state":"queued","structured":true,"id":"cycle-a","title":"Cycle side A","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"cycle-b","body_excerpt":"Acceptance criteria: cycle clears."},
      {"order":24,"state":"queued","structured":true,"id":"cycle-b","title":"Cycle side B","repo":"gamma","project_resolved":true,"kind":"ship","blocked_by":"cycle-a","body_excerpt":"Acceptance criteria: cycle clears."}
    ]
    | .tasks = [
      {"id":"asker","kind":"ship","project":"alpha","current_state":{"state":"blocked","source":"status-fold","detail":"awaiting reply"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[{"key":"default","verb":"needs-decision","summary":"which port should the exporter bind"}]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"asker","title":"Build the exporter","repo":"alpha","project_resolved":true,"kind":"ship","since":"2026-07-16"}},
      {"id":"keyed-asker","kind":"ship","project":"beta","current_state":{"state":"blocked","source":"status-fold","detail":"awaiting decision"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[{"key":"api-shape","verb":"needs-decision","summary":"choose v1 or v2 response shape"}]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"keyed-asker","title":"Build the API","repo":"beta","project_resolved":true,"kind":"ship","since":"2026-07-16"}},
      {"id":"mixed-asker","kind":"ship","project":"alpha","current_state":{"state":"blocked","source":"status-fold","detail":"awaiting several answers"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[{"key":"default","verb":"needs-decision"},{"key":"route-one","verb":"needs-decision"},{"key":"route-two","verb":"needs-decision"}]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"mixed-asker","title":"Resolve several worker questions","repo":"alpha","project_resolved":true,"kind":"ship"}}
    ]
    | .secondmate_current.registry.records = []
    | .secondmate_current.records = []
    | .secondmate_current.total = 0
    | .secondmate_current.shown = 0
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "keyless-question capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.blocked | map(select(.reason | contains("Worker question being handled in chat"))) | length) == 2
    and (.pipeline.blocked | map(select(.reason | contains("Worker question"))) | .[0].what_you_can_do | contains("firstmate is handling"))
    and ([.pipeline.blocked[] | select(.waits_on != null) | .waits_on[0]] | any(contains("waiting on your decision")))
    and ([.pipeline.blocked[] | .waits_on // [] | join(" ")] | any(contains("blocked by") and contains("currently")))
    and any(.pipeline.blocked[];
      ((.waits_on // []) | length) == 2
      and ((.waits_on | join(" ")) | contains("worker question"))
      and ((.waits_on | join(" ")) | contains("unavailable")))
    and any(.pipeline.blocked[];
      ((.waits_on // [] | join(" ")) as $chain
       | ([$chain | scan("blocked by")] | length) >= 6
         and ($chain | contains("waiting on your decision"))))
    and any(.pipeline.blocked[];
      ((.waits_on // [] | join(" ")) | contains("currently blocked")
       and contains("waiting on your decision")))
    and any(.pipeline.blocked[];
      ((.waits_on // [] | join(" ")) | contains("dependency edge is stale"))
      and .what_you_can_do == "Nothing yet - firstmate reconciles this stale dependency")
    and any(.pipeline.blocked[];
      (.reason | contains(","))
      and ((.waits_on // []) | length) == 1
      and ((.waits_on | join(" ")) | contains("waiting on your decision")))
    and any(.pipeline.blocked[];
      ((.waits_on // []) | length) == 3
      and ((.waits_on | join(" ")) | contains("worker question"))
      and (([.waits_on[] | select(contains("waiting on your decision"))] | length) == 2))
    and any(.pipeline.blocked[];
      ((.waits_on // [] | join(" ")) | contains("circular dependency"))
      and (.what_you_can_do | contains("firstmate reconciles this circular dependency")))
    and ([.pipeline.blocked[] | .waits_on // [] | join(" ")] | any(contains("which port")) | not)
  ' >/dev/null || fail "keyless questions or blocker chains are wrong: $json"
  html=$(cat "$output")
  assert_contains "$html" 'What you can do:' "blocked rows omit the explicit captain action line"
  case "$html" in
    *'item-id">default'*) fail "a keyless worker question was fabricated into a decision identity" ;;
  esac
  pass "keyless worker questions stay chat-handled and blocked rows carry privacy-safe root-cause chains"
}

test_wait_estimator_honesty() {
  local unit="$TMP_ROOT/wait-estimator-unit.mjs"
  cat > "$unit" <<'EOF'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
const wp = await import(pathToFileURL(process.argv[2]).href);

// No-history case: never a fabricated percentage, elapsed time only.
const none = wp.estimateWait(720, []);
assert.equal(none.basis, "none");
assert.equal(none.percent, null);
assert.equal(none.remaining_seconds, null);
assert.match(wp.progressLabel(none), /^time unknown - 12m elapsed so far$/);

// Mid-run case: median-based percent and remaining, labeled as an estimate.
const mid = wp.estimateWait(1800, [3600, 3600, 3500]);
assert.equal(mid.basis, "history");
assert.equal(mid.percent, 50);
assert.equal(mid.remaining_seconds, 1800);
assert.equal(mid.overrun, false);
assert.match(wp.progressLabel(mid), /~50% done - ~30m left, based on past runs/);

// Overrun case: no frozen near-complete percentage, explicit overrun wording.
const over = wp.estimateWait(1800, [600, 600, 700]);
assert.equal(over.overrun, true);
assert.equal(over.percent, null);
assert.equal(over.remaining_seconds, null);
assert.match(wp.progressLabel(over), /running longer than usual - typically ~10m, 30m so far/);

// Percent clamps: a wait still under way is never 0% or 100%.
assert.equal(wp.estimateWait(1, [600]).percent, 1);
assert.equal(wp.estimateWait(600, [600]).percent, 99);
assert.equal(wp.estimateWait(600, [600]).overrun, false);

// Deadline math: exact remaining, percent only when the start is known.
const gate = wp.deadlineWait(288000, 748800);
assert.equal(gate.basis, "deadline");
assert.equal(gate.percent, 72);
assert.match(wp.progressLabel(gate), /~3d 8h until it resumes/);
assert.equal(wp.deadlineWait(288000, null).percent, null);

// Observation lifecycle: a vanished wait rolls its observed duration into the
// bounded per-kind history; a single sighting never records a zero.
const history = { schema: wp.WAIT_HISTORY_SCHEMA, active: {}, durations: {} };
let elapsed = wp.observeWaits(history, new Map([["main/a:validation", "validation"]]), 1000);
assert.equal(elapsed.get("main/a:validation"), 0);
elapsed = wp.observeWaits(history, new Map([["main/a:validation", "validation"]]), 1600);
assert.equal(elapsed.get("main/a:validation"), 600);
wp.observeWaits(history, new Map(), 2000);
assert.deepEqual(history.durations.validation, [600]);
assert.deepEqual(history.active, {});
wp.observeWaits(history, new Map([["main/b:ci", "ci"]]), 3000);
wp.observeWaits(history, new Map(), 4000);
assert.equal(history.durations.ci, undefined);
history.active["design/d:validation"] = { kind: "validation", first_observed: 1000, last_observed: 1600 };
wp.observeWaits(history, new Map(), 2000, new Set(["main"]));
assert.deepEqual(history.active["design/d:validation"], { kind: "validation", first_observed: 1000, last_observed: 1600 });
assert.deepEqual(history.durations.validation, [600]);
for (let index = 0; index < 30; index += 1) {
  wp.observeWaits(history, new Map([["main/c:ci", "ci"]]), 5000 + index * 300);
  wp.observeWaits(history, new Map([["main/c:ci", "ci"]]), 5100 + index * 300);
  wp.observeWaits(history, new Map(), 5200 + index * 300);
}
assert.equal(history.durations.ci.length, wp.WAIT_HISTORY_LIMIT);
// A declared external delay has no shared duration model: paused waits are
// tracked for elapsed time but their durations are never recorded, and a
// prior file carrying paused durations drops them on load.
assert.equal(wp.WAIT_HISTORY_KINDS.has("paused"), false);
wp.observeWaits(history, new Map([["main/p:paused", "paused"]]), 9000);
wp.observeWaits(history, new Map([["main/p:paused", "paused"]]), 9600);
wp.observeWaits(history, new Map(), 9900);
assert.equal(history.durations.paused, undefined);

// Corrupt, missing, or wrong-schema files start fresh instead of failing.
const corrupt = path.join(path.dirname(process.argv[3]), "corrupt-history.json");
fs.writeFileSync(corrupt, "{not json");
assert.deepEqual(wp.loadWaitHistory(corrupt).active, {});
assert.deepEqual(wp.loadWaitHistory(path.join(path.dirname(corrupt), "absent.json")).durations, {});
fs.writeFileSync(corrupt, JSON.stringify({ schema: "other", active: { x: { kind: "validation", first_observed: 1, last_observed: 2 } } }));
assert.deepEqual(wp.loadWaitHistory(corrupt).active, {});
fs.writeFileSync(corrupt, JSON.stringify({ schema: wp.WAIT_HISTORY_SCHEMA, active: {}, durations: { paused: [1200, 1800], validation: [600] } }));
assert.deepEqual(wp.loadWaitHistory(corrupt).durations, { validation: [600] });
process.stdout.write("estimator-unit-ok\n");
EOF
  node "$unit" "$ROOT/bin/fm-wait-progress.mjs" "$unit" | grep -q 'estimator-unit-ok' ||
    fail "wait estimator unit contract failed"
  pass "wait estimator is honest for no-history, mid-run, overrun, deadline, and rolling-history cases"
}

test_wait_classes_render_distinct_treatments() {
  local home="$TMP_ROOT/wait-class-home" snapshot="$TMP_ROOT/wait-class-snapshot.json" environment="$TMP_ROOT/wait-class-environment.json" output="$TMP_ROOT/wait-class-home/data/wait-class.html" json html
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records += [
      {"order":10,"state":"in_flight","structured":true,"id":"paused-task","title":"Wait for the upstream release","repo":"iota","project_resolved":true,"kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: upstream landed."},
      {"order":11,"state":"in_flight","structured":true,"id":"stuck-task","title":"Ship the kappa importer","repo":"kappa","project_resolved":true,"kind":"ship","since":"2026-07-16","body_excerpt":"Acceptance criteria: importer ships."},
      {"order":12,"state":"queued","structured":true,"id":"queued-root","title":"Prepare queued dependency","repo":"theta","project_resolved":true,"kind":"ship","body_excerpt":"Acceptance criteria: dependency is ready."},
      {"order":13,"state":"queued","structured":true,"id":"queued-dependent","title":"Use queued dependency","repo":"lambda","project_resolved":true,"kind":"ship","blocked_by":"queued-root","body_excerpt":"Acceptance criteria: dependency is used."}
    ]
    | .tasks += [
      {"id":"paused-task","kind":"ship","project":"iota","current_state":{"state":"paused","source":"status-fold","detail":"upstream release window"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"paused-task","title":"Wait for the upstream release","repo":"iota","project_resolved":true,"kind":"ship","since":"2026-07-16"}},
      {"id":"stuck-task","kind":"ship","project":"kappa","current_state":{"state":"blocked","source":"status-fold","detail":"credential missing"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"stuck-task","title":"Ship the kappa importer","repo":"kappa","project_resolved":true,"kind":"ship","since":"2026-07-16"}}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "wait-class capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.validating_fixing | any(
      .wait.class == "self_clearing"
      and .wait.kind == "validation"
      and (.wait.copy | contains("test suite"))
      and .wait.progress.basis == "none"
      and .wait.progress.percent == null
      and (.wait.progress.label | contains("time unknown"))))
    and (.pipeline.blocked | any(
      .wait.class == "self_clearing"
      and .wait.kind == "paused"
      and (.wait.copy | contains("external delay"))
      and .wait.progress.percent == null))
    and (.pipeline.blocked | any(
      .wait.class == "self_clearing"
      and .wait.kind == "time_gate"
      and (.wait.copy | contains("resumes automatically after 2026-08-01"))
      and .wait.progress.basis == "deadline"
      and .wait.progress.remaining_seconds > 0))
    and (.pipeline.blocked | any(
      .reason == "Captain hold"
      and .wait.class == "needs_actor"
      and (.waits_on | length) == 1
      and (.what_you_can_do | contains("Answer decision"))))
    and (.pipeline.blocked | any(
      .wait.class == "needs_actor"
      and ((.waits_on | join(" ")) | contains("queued and not started"))
      and (.what_you_can_do | contains("Dispatch"))))
    and (.pipeline.blocked | any(
      .wait.class == "self_clearing"
      and .wait.kind == "dependency"
      and ((.waits_on | join(" ")) | contains("currently working"))))
    and (.pipeline.blocked | all(.wait.class == "self_clearing" or .wait.class == "needs_actor"))
  ' >/dev/null || fail "wait classifications are wrong: $json"
  html=$(cat "$output")
  assert_contains "$html" 'id="selfwait-items"' "dashboard lacks the calm self-clearing wait group"
  assert_contains "$html" 'no action needed' "self-clearing group does not say no action is needed"
  assert_contains "$html" 'class="verb verb-waiting"' "self-clearing rows lack the calm waiting verb"
  assert_contains "$html" 'class="verb verb-blocked"' "needs-actor rows lost the attention verb"
  assert_contains "$html" 'resumes by itself' "self-clearing rows lack plain-language resume copy"
  assert_contains "$html" 'What you can do:' "needs-actor rows lost the what-you-can-do line"
  assert_contains "$html" 'role="progressbar"' "progress affordances lack the progressbar role"
  assert_contains "$html" 'aria-valuemin="0" aria-valuemax="100"' "progressbars lack aria value bounds"
  assert_contains "$html" 'time unknown' "a no-history wait does not admit its unknown duration"
  assert_contains "$html" 'wbar-unknown' "a no-history wait renders a determinate bar"
  assert_contains "$html" 'waiting on their own' "the waiting breakdown lacks the self-clearing line"
  case "$html" in
    *'% done'*) fail "a wait with no recorded history fabricated a percentage" ;;
  esac
  pass "self-clearing and needs-actor waits render distinct honest treatments"
}

test_captain_gated_pauses_need_action_without_eta() {
  local home="$TMP_ROOT/captain-gate-home" snapshot="$TMP_ROOT/captain-gate-snapshot.json" environment="$TMP_ROOT/captain-gate-environment.json" output="$TMP_ROOT/captain-gate-home/data/captain-gate.html" json html
  make_fixture "$home" "$snapshot" "$environment"
  # Legacy paused history must never fabricate a percent for any pause again.
  printf '%s\n' '{"schema":"fm-capacity-wait-history.v1","active":{},"durations":{"paused":[3600,3600,3500]}}' > "$home/data/capacity-wait-history.json"
  jq '
    .backlog.records += [
      {"order":10,"state":"in_flight","structured":true,"id":"pr-pause","title":"Harden the mu pipeline","repo":"mu","project_resolved":true,"kind":"ship","since":"2026-07-20","body_excerpt":"Acceptance criteria: pipeline hardened."},
      {"order":11,"state":"in_flight","structured":true,"id":"review-pause","title":"Prefetch the nu transits","repo":"nu","project_resolved":true,"kind":"ship","since":"2026-07-20","body_excerpt":"Acceptance criteria: transits prefetched."},
      {"order":12,"state":"in_flight","structured":true,"id":"ambient-pause","title":"Wait for the upstream window","repo":"xi","project_resolved":true,"kind":"ship","since":"2026-07-20","body_excerpt":"Acceptance criteria: window observed."},
      {"order":13,"state":"in_flight","structured":true,"id":"stale-pr-pause","title":"Hold for canary after a merged PR","repo":"astro","project_resolved":true,"kind":"ship","since":"2026-07-20","body_excerpt":"Acceptance criteria: canary order given."},
      {"order":14,"state":"in_flight","structured":true,"id":"closed-pr-pause","title":"Hold after a closed PR","repo":"tau","project_resolved":true,"kind":"ship","since":"2026-07-20","body_excerpt":"Acceptance criteria: retry decision given."}
    ]
    | .tasks += [
      {"id":"pr-pause","kind":"ship","project":"mu","current_state":{"state":"paused","source":"status-fold","detail":"PR 106 awaiting captain merge decision"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":"https://github.com/purple-phoenix/firstmate/pull/106"},"paths":{"report":{"present":false}},"backlog":{"id":"pr-pause","title":"Harden the mu pipeline","repo":"mu","project_resolved":true,"kind":"ship","since":"2026-07-20"}},
      {"id":"review-pause","kind":"ship","project":"nu","current_state":{"state":"paused","source":"status-fold","detail":"planned batch under captain review, holding for approvals"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"review-pause","title":"Prefetch the nu transits","repo":"nu","project_resolved":true,"kind":"ship","since":"2026-07-20"}},
      {"id":"ambient-pause","kind":"ship","project":"xi","current_state":{"state":"paused","source":"status-fold","detail":"upstream rate limit window"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}},"backlog":{"id":"ambient-pause","title":"Wait for the upstream window","repo":"xi","project_resolved":true,"kind":"ship","since":"2026-07-20"}},
      {"id":"stale-pr-pause","kind":"ship","project":"astro","current_state":{"state":"paused","source":"status-fold","detail":"PR merged; awaiting captain canary decision"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":"https://github.com/purple-phoenix/astroai/pull/97"},"paths":{"report":{"present":false}},"backlog":{"id":"stale-pr-pause","title":"Hold for canary after a merged PR","repo":"astro","project_resolved":true,"kind":"ship","since":"2026-07-20"}},
      {"id":"closed-pr-pause","kind":"ship","project":"tau","current_state":{"state":"paused","source":"status-fold","detail":"PR closed; awaiting captain retry decision"},"endpoint":{"exists":true,"agent_alive":"not_checked"},"hints":{"open_decisions":[]},"pr":{"url":"https://github.com/purple-phoenix/tau/pull/12"},"paths":{"report":{"present":false}},"backlog":{"id":"closed-pr-pause","title":"Hold after a closed PR","repo":"tau","project_resolved":true,"kind":"ship","since":"2026-07-20"}}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$(FM_HOME="$home" "$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "captain-gate capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.blocked | any(
      .captain_gate == true
      and .wait.class == "needs_actor"
      and (.wait | has("progress") | not)
      and ((.waits_on | join(" ")) | contains("paused for your decision on its open pull request"))
      and (.what_you_can_do | contains("Review and merge its open pull request"))))
    and (.pipeline.blocked | any(
      .captain_gate == true
      and .wait.class == "needs_actor"
      and ((.waits_on | join(" ")) | contains("paused: planned batch under captain review, holding for approvals"))
      and (.what_you_can_do | contains("Give your go or decision on: planned batch under captain review, holding for approvals"))
      and ((.what_you_can_do | test("open pull request"; "i")) | not)
      and ((.waits_on | join(" ") | test("open pull request"; "i")) | not)))
    and (.pipeline.blocked | any(
      .captain_gate == true
      and ((.waits_on | join(" ")) | contains("paused: PR merged; awaiting captain canary decision"))
      and (.what_you_can_do | contains("captain canary decision"))
      and ((.what_you_can_do | test("open pull request"; "i")) | not)
      and ((.waits_on | join(" ") | test("open pull request"; "i")) | not)))
    and (.pipeline.blocked | any(
      .captain_gate == true
      and ((.waits_on | join(" ")) | contains("paused: PR closed; awaiting captain retry decision"))
      and (.what_you_can_do | contains("captain retry decision"))
      and ((.what_you_can_do | test("open pull request"; "i")) | not)
      and ((.waits_on | join(" ") | test("open pull request"; "i")) | not)))
    and ([.pipeline.blocked[] | select(.captain_gate == true)] | length) == 4
    and (.pipeline.blocked | any(
      .wait.class == "self_clearing"
      and .wait.kind == "paused"
      and .wait.progress.basis == "none"
      and .wait.progress.percent == null
      and (.wait.progress.label | contains("time unknown"))))
    and .measures.open_captain_actions >= 5
  ' >/dev/null || fail "captain-gated pauses are misclassified: $json"
  html=$(cat "$output")
  assert_contains "$html" 'class="verb verb-review"' "captain-gated pauses are missing from the needs-you band"
  assert_contains "$html" 'Paused work is waiting on you, not an automatic process.' "captain-gate rows lack the plain-language framing"
  assert_contains "$html" 'Review and merge its open pull request' "the PR-gated pause lacks its what-you-can-do line"
  assert_contains "$html" 'PR merged; awaiting captain canary decision' "the merged-PR captain pause lacks its declared reason"
  assert_contains "$html" 'PR closed; awaiting captain retry decision' "the closed-PR captain pause lacks its declared reason"
  assert_contains "$html" 'Give your go or decision on:' "the non-PR captain pause lacks its what-you-can-do line"
  assert_contains "$html" 'time unknown' "the ambiguous pause does not admit its unknown duration"
  case "$html" in
    *'% done'*) fail "a pause fabricated a percent from unrelated past waits" ;;
  esac
  case "$html" in
    *'based on past runs'*) fail "a pause borrowed an ETA from unrelated past waits" ;;
  esac
  # A stale pr= must not invent open-PR language for non-PR captain-gated pauses.
  # Exactly one captain_gate card may mention an open pull request (the real PR).
  printf '%s' "$json" | jq -e '
    ([.pipeline.blocked[]
      | select(.captain_gate == true)
      | select(((.waits_on | join(" ")) + " " + (.what_you_can_do // "")) | test("open pull request"; "i"))]
     | length) == 1
    and ([.pipeline.blocked[]
      | select(.captain_gate == true)
      | select((.waits_on | join(" ")) | test("PR (merged|closed)"))
      | select(((.waits_on | join(" ")) + " " + (.what_you_can_do // "")) | test("open pull request"; "i"))]
     | length) == 0
  ' >/dev/null || fail "open pull request language leaked onto non-PR captain gates: $json"
  pass "captain-gated pauses render as needs-your-action with no fabricated ETA"
}

test_captain_kind_idea_hold_is_your_go_not_stuck() {
  local home="$TMP_ROOT/idea-hold-home" snapshot="$TMP_ROOT/idea-hold-snapshot.json" environment="$TMP_ROOT/idea-hold-environment.json" output="$TMP_ROOT/idea-hold-home/data/idea-hold.html" json html
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    .backlog.records += [
      {"order":20,"state":"queued","structured":true,"id":"audit-idea-w6","title":"Feature (queued): unified workspace","repo":"astro","project_resolved":true,"kind":"ship","since":"2026-07-29","hold_kind":"captain","hold_reason":"Audit feature opportunity - queued for captain prioritization","body_excerpt":"Acceptance criteria: workspace carries context."}
    ]
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$(FM_HOME="$home" "$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "captain idea-hold capacity run failed"
  printf '%s' "$json" | jq -e '
    (.pipeline.blocked | any(
      .captain_gate == true
      and .reason == "Waiting on your go"
      and .wait.class == "needs_actor"
      and ((.waits_on | join(" ")) | contains("held for your prioritization"))
      and (.what_you_can_do | contains("Prioritize or give your go on"))
      and (. as $card | $card.what_you_can_do | contains($card.id))
      and ((.what_you_can_do | test("Nothing yet"; "i")) | not)
      and (.reason != "Structured hold")))
    and ([.pipeline.blocked[] | select(.reason == "Structured hold" and (.what_you_can_do | test("Nothing yet"; "i")))] | length) == 0
  ' >/dev/null || fail "captain-kind idea hold misclassified as stuck: $json"
  html=$(cat "$output")
  assert_contains "$html" 'class="verb verb-review"' "captain idea hold is missing from the needs-you band"
  assert_contains "$html" 'Prioritize or give your go on item-' "captain idea hold lacks an opaque choice reference"
  case "$html" in
    *'verb-blocked">Stuck'*)
      # Stuck may still exist for other fixture rows; the idea hold must not be one.
      printf '%s' "$html" | grep -F 'verb-blocked">Stuck' | grep -q 'held for your prioritization' &&
        fail "captain idea hold rendered as STUCK" || true
      ;;
  esac
  pass "captain-kind idea holds render as waiting-on-your-go, not STUCK"
}

test_wait_history_estimates_and_overrun() {
  local home="$TMP_ROOT/wait-history-home" snapshot="$TMP_ROOT/wait-history-snapshot.json" environment="$TMP_ROOT/wait-history-environment.json" output="$TMP_ROOT/wait-history-home/data/wait-history.html" history json html first
  history="$home/data/capacity-wait-history.json"
  make_fixture "$home" "$snapshot" "$environment"
  first=$(node -e 'console.log(Math.floor(Date.parse("2026-07-17T15:30:00Z") / 1000))')
  printf '%s\n' "{\"schema\":\"fm-capacity-wait-history.v1\",\"active\":{\"main/validate-now:validation\":{\"kind\":\"validation\",\"first_observed\":$first,\"last_observed\":$first}},\"durations\":{\"validation\":[3600,3600,3500]}}" > "$history"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "seeded wait-history capacity run failed"
  printf '%s' "$json" | jq -e '
    .pipeline.validating_fixing | any(
      .wait.progress.basis == "history"
      and .wait.progress.percent == 50
      and .wait.progress.elapsed_seconds == 1800
      and .wait.progress.remaining_seconds == 1800
      and .wait.progress.overrun == false
      and (.wait.progress.label | contains("based on past runs")))
  ' >/dev/null || fail "seeded history did not produce a mid-run estimate: $json"
  html=$(cat "$output")
  assert_contains "$html" 'aria-valuenow="50"' "mid-run progressbar lacks its current value"
  assert_contains "$html" 'based on past runs' "mid-run estimate is not labeled as an estimate"

  printf '%s\n' "{\"schema\":\"fm-capacity-wait-history.v1\",\"active\":{\"main/validate-now:validation\":{\"kind\":\"validation\",\"first_observed\":$first,\"last_observed\":$first}},\"durations\":{\"validation\":[600,600,700]}}" > "$history"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") ||
    fail "overrun wait-history capacity run failed"
  printf '%s' "$json" | jq -e '
    .pipeline.validating_fixing | any(
      .wait.progress.overrun == true
      and .wait.progress.percent == null
      and (.wait.progress.label | contains("running longer than usual")))
  ' >/dev/null || fail "an exceeded estimate did not degrade to running-longer-than-usual: $json"
  assert_grep 'running longer than usual' "$output" "overrun wording is missing from the dashboard"

  jq '.tasks = [.tasks[] | if .id == "validate-now" then .current_state.detail = "implementing" | .pr.url = null else . end]' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  "$CAPACITY" --snapshot "$snapshot" --environment "$environment" --output "$output" >/dev/null ||
    fail "completion wait-history capacity run failed"
  jq -e '
    (.active | has("main/validate-now:validation") | not)
    and (.durations.validation | index(1800))
  ' "$history" >/dev/null || fail "a completed wait was not rolled into the duration history: $(cat "$history")"
  if [ "$(uname)" = Darwin ]; then
    [ "$(stat -f '%Lp' "$history")" = 600 ] || fail "wait history file is not private"
  else
    [ "$(stat -c '%a' "$history")" = 600 ] || fail "wait history file is not private"
  fi
  pass "recorded wait history yields labeled estimates, overruns degrade honestly, and completions roll into history"
}

test_parked_items_rest_in_the_parking_lot() {
  local home="$TMP_ROOT/parked-home" mate_home="$TMP_ROOT/parked-mate" snapshot="$TMP_ROOT/parked-snapshot.json" environment="$TMP_ROOT/parked-environment.json" output="$TMP_ROOT/parked-home/data/parked.html" json mate_json
  make_fixture "$home" "$snapshot" "$environment"
  mkdir -p "$mate_home/data" "$mate_home/state" "$mate_home/config" "$mate_home/projects"
  printf '%s\n' '- delta [direct-PR] - delta project (added 2026-07-17)' > "$mate_home/data/projects.md"
  printf '%s\n' \
    '## Queued' \
    '- [ ] design-ready - Refresh the delta design tokens (repo: delta) (kind: ship)' \
    '  Acceptance criteria: token snapshots pass.' \
    '- [ ] mate-parked - Parked delta exploration (repo: delta) (kind: ship) (since 2026-07-12) (hold: Mate parked reason stays private) (hold-kind: parked)' \
    '  Acceptance criteria: exploration is summarized.' > "$mate_home/data/backlog.md"
  mate_json=$(FM_HOME="$mate_home" FM_SNAPSHOT_NOW=2026-07-17T16:00:00Z "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) \
    || fail "secondmate parked summary fixture failed"
  printf '%s' "$mate_json" | jq -e '
    .counts.queued == 2
    and (.queued | any(.id == "mate-parked" and .since == "2026-07-12" and .hold_kind == "parked"))
  ' >/dev/null || fail "production secondmate projection omitted the parked since date: $mate_json"
  jq --argjson mate "$mate_json" '
    .backlog.records += [
      {"order":10,"state":"queued","structured":true,"id":"parked-rest","title":"Refresh the omicron gateway","repo":"omicron","project_resolved":true,"kind":"ship","since":"2026-07-10","hold_kind":"parked","hold_reason":"Captain parked omicron work until the retreat","body_excerpt":"Acceptance criteria: omicron gateway upgraded."}
    ]
    | (.secondmate_current.records[] | select(.id == "design") | .queued) = $mate.queued
    | (.secondmate_current.records[] | select(.id == "design") | .counts.queued) = $mate.counts.queued
  ' "$snapshot" > "$snapshot.tmp" && mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "parked fixture run failed"
  printf '%s' "$json" | jq -e '
    (.parked | length) == 2
    and ([.parked[].parked_since] | sort) == ["2026-07-10","2026-07-12"]
    and (.parked | all(.reason == "Parked at your request - deliberately resting, not stuck"))
    and ([.parked[].id] as $p | [.pipeline[][].id] | map(select(. as $x | $p | index($x))) | length) == 0
    and (.pipeline.blocked | length) == 3
    and (.pipeline.queued | length) == 2
    and (.readiness.explicit_gates | length) == 3
    and .readiness.queued_considered == 7
    and .measures.open_captain_actions == 1
    and (.omissions | any(contains("Park reasons are withheld")))
  ' >/dev/null || fail "parked work was not kept out of the blocked band and counts: $json"
  case "$json" in *omicron*) fail "parked project, title, or reason leaked into the model" ;; esac
  assert_grep 'Parking lot (2)' "$output" "dashboard lacks the collapsed parking lot"
  assert_grep '<details class="parking"' "$output" "parking lot is not a collapsed section"
  [ "$(grep -o 'data-parked-ref=' "$output" | wc -l | tr -d ' ')" = 2 ] \
    || fail "parked items do not render exactly once each in the parking lot"
  assert_no_grep 'until the retreat' "$output" "park reason leaked into the offline dashboard"
  assert_no_grep 'stays private' "$output" "secondmate park reason leaked into the offline dashboard"
  assert_no_grep 'Refresh the omicron gateway' "$output" "parked title leaked into the offline dashboard"
  local empty_home="$TMP_ROOT/parked-empty" empty_snapshot="$TMP_ROOT/parked-empty-snapshot.json" empty_environment="$TMP_ROOT/parked-empty-environment.json" empty_output="$TMP_ROOT/parked-empty/data/empty.html"
  make_fixture "$empty_home" "$empty_snapshot" "$empty_environment"
  "$CAPACITY" --snapshot "$empty_snapshot" --environment "$empty_environment" --output "$empty_output" >/dev/null || fail "empty parking-lot run failed"
  assert_no_grep 'Parking lot' "$empty_output" "an empty parking lot still rendered a section"
  assert_no_grep 'data-parked-ref' "$empty_output" "an empty parking lot still rendered row anchors"
  pass "captain-parked work rests in the collapsed parking lot, out of blocked bands, counts, and reasons stay withheld"
}

test_recurring_items_get_their_own_section() {
  local home="$TMP_ROOT/recurring-home" mate_home="$TMP_ROOT/recurring-mate" snapshot="$TMP_ROOT/recurring-snapshot.json" environment="$TMP_ROOT/recurring-environment.json" output="$TMP_ROOT/recurring-home/data/recurring.html" json mate_json
  make_fixture "$home" "$snapshot" "$environment"
  mkdir -p "$mate_home/data" "$mate_home/state" "$mate_home/config" "$mate_home/projects"
  printf '%s\n' '- delta [direct-PR] - delta project (added 2026-07-17)' > "$mate_home/data/projects.md"
  printf '%s\n' \
    '## Queued' \
    '- [ ] design-ready - Refresh the delta design tokens (repo: delta) (kind: ship)' \
    '  Acceptance criteria: token snapshots pass.' \
    '- [ ] mate-research-r5 - Weekly delta research (repo: delta) (kind: scout) (since 2026-07-10) (hold: Mate cadence reason stays private) (hold-kind: future) (hold-until: 2026-08-04)' \
    '  Acceptance criteria: report is filed.' \
    '## Done' \
    '- [x] mate-research-r4 - Weekly delta research data/mate-research-r4/report.md (done 2026-07-11)' \
    '- [x] unrelated-11 - Unrelated 11 (done 2026-07-23)' \
    '- [x] unrelated-10 - Unrelated 10 (done 2026-07-22)' \
    '- [x] unrelated-09 - Unrelated 09 (done 2026-07-21)' \
    '- [x] unrelated-08 - Unrelated 08 (done 2026-07-20)' \
    '- [x] unrelated-07 - Unrelated 07 (done 2026-07-19)' \
    '- [x] unrelated-06 - Unrelated 06 (done 2026-07-18)' \
    '- [x] unrelated-05 - Unrelated 05 (done 2026-07-17)' \
    '- [x] unrelated-04 - Unrelated 04 (done 2026-07-16)' \
    '- [x] unrelated-03 - Unrelated 03 (done 2026-07-15)' \
    '- [x] unrelated-02 - Unrelated 02 (done 2026-07-14)' \
    '- [x] unrelated-01 - Unrelated 01 (done 2026-07-13)' > "$mate_home/data/backlog.md"
  mate_json=$(FM_HOME="$mate_home" FM_SNAPSHOT_NOW=2026-07-17T16:00:00Z FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) \
    || fail "secondmate recurring summary fixture failed"
  printf '%s' "$mate_json" | jq -e '
    .counts.queued == 2
    and (.queued | any(.id == "mate-research-r5" and .hold_kind == "future" and .hold_until == "2026-08-04"))
    and (.landed | length) == 12
    and (.landed | any(.id == "mate-research-r4" and .report_path != null))
  ' >/dev/null || fail "production secondmate projection omitted the recurring date gate: $mate_json"
  jq --argjson mate "$mate_json" '
    .backlog.records += [
      {"order":10,"state":"queued","structured":true,"id":"sigma-research-w4","title":"Weekly sigma market research","repo":"sigma","project_resolved":true,"kind":"scout","since":"2026-07-12","hold_kind":"future","hold_reason":"Weekly cadence reason stays private","hold_until":"2026-08-04","body_excerpt":"Acceptance criteria: report lands on the books."},
      {"order":11,"state":"queued","structured":true,"id":"expired-cadence-w2","title":"Run the rho refresh on its due date","repo":"rho","project_resolved":true,"kind":"ship","since":"2026-07-01","hold_kind":"future","hold_reason":"cadence gate already passed","hold_until":"2026-07-01","body_excerpt":"Acceptance criteria: refresh checks pass."},
      {"order":12,"state":"queued","structured":true,"id":"sigma-research-w4-2026-08-04","title":"Weekly dated sigma market research","repo":"sigma","project_resolved":true,"kind":"scout","since":"2026-07-12","hold_kind":"future","hold_reason":"Dated cadence stays private","hold_until":"2026-08-04","body_excerpt":"Acceptance criteria: report lands on the books."},
      {"order":13,"state":"done","structured":true,"id":"sigma-research-w3","title":"Weekly sigma market research","repo":"sigma","project_resolved":true,"kind":"scout","pr_url":"https://github.com/example/sigma/pull/7","completion":{"verb":"merged","date":"2026-07-14"}},
      {"order":14,"state":"done","structured":true,"id":"sigma-research-w3-2026-08-04","title":"Unrelated dated sigma market research","repo":"sigma","project_resolved":true,"kind":"scout","pr_url":"https://github.com/example/sigma/pull/8","completion":{"verb":"merged","date":"2026-07-15"}}
    ]
    | (.secondmate_current.records[] | select(.id == "design") | .queued) = $mate.queued
    | (.secondmate_current.records[] | select(.id == "design") | .counts.queued) = $mate.counts.queued
    | (.secondmate_current.records[] | select(.id == "design") | .landed) = $mate.landed
  ' "$snapshot" > "$snapshot.tmp" && mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output") || fail "recurring fixture run failed"
  printf '%s' "$json" | jq -e '
    (.recurring | length) == 3
    and (.recurring | all(.next_run == "2026-08-04"))
    and (.recurring | all(.reason == "Scheduled cadence work - healthy and waiting for its next run"))
    and (.recurring | all(.scheduled_since != null))
    and ([.recurring[].id] as $r | [.pipeline[][].id] | map(select(. as $x | $r | index($x))) | length) == 0
    and (.pipeline.blocked | length) == 3
    and (.readiness.explicit_gates | length) == 3
    and .measures.waiting_work == 5
    and .readiness.queued_considered == 8
    and ([.recurring[] | select(.owner == "main")] | length) == 2
    and ([.recurring[] | select(.owner == "main" and .last_run != null)] | length) == 1
    and ([.recurring[] | select(.owner == "main" and .last_run != null)] | all(.last_run.date == "2026-07-14" and .last_run.artifact_recorded == true and (.last_run.ref | startswith("item-"))))
    and ([.recurring[] | select(.owner == "main" and .last_run == null)] | length) == 1
    and ([.recurring[] | select(.owner != "main")] | length) == 1
    and ([.recurring[] | select(.owner != "main")] | all(.last_run.artifact_recorded == true))
    and ([.pipeline.ready[].id] | length) == 3
    and (.omissions | any(contains("Recurring schedule reasons are withheld")))
  ' >/dev/null || fail "date-gated cadence work was not classified recurring, out of blocked bands and counts: $json"
  case "$json" in *sigma*|*"stays private"*) fail "recurring project, title, or schedule reason leaked into the model" ;; esac
  assert_grep 'Recurring (3) · scheduled cadence work, healthy and on schedule' "$output" "dashboard lacks the calm recurring section"
  assert_grep 'next: Aug 4' "$output" "recurring row lacks its next-run date"
  [ "$(grep -o 'data-recurring-ref=' "$output" | wc -l | tr -d ' ')" = 3 ] \
    || fail "recurring items do not render exactly once each in the recurring section"
  assert_grep 'data-last-run-ref=' "$output" "recurring row lacks its last completed run anchor"
  assert_no_grep 'Weekly sigma market research' "$output" "recurring title leaked into the offline dashboard"
  assert_no_grep 'stays private' "$output" "recurring schedule reason leaked into the offline dashboard"
  assert_no_grep 'github.com/example' "$output" "last-run artifact URL leaked into the offline dashboard"
  local empty_home="$TMP_ROOT/recurring-empty" empty_snapshot="$TMP_ROOT/recurring-empty-snapshot.json" empty_environment="$TMP_ROOT/recurring-empty-environment.json" empty_output="$TMP_ROOT/recurring-empty/data/empty.html"
  make_fixture "$empty_home" "$empty_snapshot" "$empty_environment"
  "$CAPACITY" --snapshot "$empty_snapshot" --environment "$empty_environment" --output "$empty_output" >/dev/null || fail "empty recurring run failed"
  assert_no_grep 'Recurring (' "$empty_output" "an empty recurring section still rendered"
  assert_no_grep 'data-recurring-ref' "$empty_output" "an empty recurring section still rendered row anchors"
  pass "date-gated cadence work rests in the calm recurring section with next-run and last-run linkage, and an expired date gate re-enters normal readiness"
}

test_live_agents_render_working_idle_and_unavailable_states() {
  local home="$TMP_ROOT/live-agents-home" snapshot="$TMP_ROOT/live-agents-snapshot.json" environment="$TMP_ROOT/live-agents-environment.json"
  local output="$TMP_ROOT/live-agents-home/data/live-agents.html" refs="$TMP_ROOT/live-agents-home/state/live-agents-refs.json" json
  make_fixture "$home" "$snapshot" "$environment"
  jq '
    (.secondmate_current.records[] | select(.id == "unknown-mate") | .current) = {"state":"unknown","reason":"structured home snapshot failed"}
    | (.secondmate_current.records[] | select(.id == "unknown-mate") | .provenance.selected) = "unknown"
  ' "$snapshot" > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  json=$("$CAPACITY" --json --snapshot "$snapshot" --environment "$environment" --output "$output" --refs "$refs") ||
    fail "live-agents fixture run failed"
  printf '%s' "$json" | jq -e '
    .live_agents.generated == "2026-07-17T16:00:00Z"
    and (.live_agents.records | any(.role == "worker" and .activity == "working"))
    and (.live_agents.records | any(.role == "worker" and .activity == "validating"))
    and (.live_agents.records | any(.role == "supervisor" and .activity == "idle"))
    and (.live_agents.records | any(.role == "supervisor" and .activity == "unavailable"))
    and (.live_agents.records | all(.as_of == "2026-07-17T16:00:00Z"))
  ' >/dev/null || fail "live-agents model omitted a current worker or honest supervisor state: $json"
  jq -e '
    [.refs[] | select(.kind == "item" and .value == "main/build-old" and .label == "Build the alpha subsystem")] | length == 1
  ' "$refs" >/dev/null || fail "private refs sidecar omitted the live task title"
  assert_grep '>Live agents<' "$output" "dashboard lacks the live-agents section"
  assert_grep '>What every agent is doing now<' "$output" "dashboard lacks the live-agents heading"
  assert_grep '>Idle<' "$output" "dashboard lacks an idle supervisor state"
  assert_grep '>Unavailable<' "$output" "dashboard lacks an unavailable supervisor rollup"
  assert_grep 'Reading generated 2026-07-17T16:00:00Z' "$output" "live-agents section lacks its observation time"
  assert_grep '>As of<' "$output" "live-agents section lacks per-row freshness labeling"
  assert_no_grep 'Build the alpha subsystem' "$output" "offline live-agents section leaked a private task title"
  pass "live agents render current workers plus idle and unavailable supervisor states with explicit freshness"
}

test_skill_discovery_and_read_mostly_contract
test_classification_priority_overlap_and_idle_semantics
test_live_agents_render_working_idle_and_unavailable_states
test_parked_items_rest_in_the_parking_lot
test_recurring_items_get_their_own_section
test_cross_home_overlap_holds_supersession_and_active_count
test_secondmate_readiness_uses_final_serialized_supply
test_secondmate_readiness_uses_home_owned_runtime_lanes
test_incomplete_sources_fail_closed
test_unresolved_active_projects_fail_closed
test_definition_and_time_markers_require_whole_evidence
test_secondmate_scope_is_required_for_lane_readiness
test_ready_selection_preserves_priority_and_order
test_recent_landings_report_incomplete_projection
test_secondmate_captain_holds_are_pipeline_waiting_work
test_approval_signal_and_max_effort_survive_safe_normalization
test_unavailable_lanes_and_demand_shortage_are_distinct
test_blocked_tasks_suppress_demand_shortage
test_available_ready_work_is_execution_shortage
test_html_is_private_escaped_accessible_and_responsive
test_output_replacement_rejects_symlinks_and_enforces_mode
test_fleet_snapshot_preserves_registered_scope_provenance
test_unknown_project_is_a_definition_gap
test_keyless_questions_and_blocker_chains
test_wait_estimator_honesty
test_wait_classes_render_distinct_treatments
test_captain_gated_pauses_need_action_without_eta
test_captain_kind_idea_hold_is_your_go_not_stuck
test_wait_history_estimates_and_overrun
