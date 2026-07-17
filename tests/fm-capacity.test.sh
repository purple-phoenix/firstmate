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
      {"order":3,"state":"queued","structured":true,"id":"ready-safe","title":"Ship <script>alert(1)</script> token=topsecret","repo":"gamma","kind":"ship","body_excerpt":"Acceptance criteria: bounded regression tests pass."},
      {"order":4,"state":"queued","structured":true,"id":"overlap-alpha","title":"Improve the active alpha subsystem","repo":"alpha","kind":"ship","body_excerpt":"Acceptance criteria: alpha remains compatible."},
      {"order":5,"state":"queued","structured":true,"id":"vague","title":"TBD","repo":null,"kind":null,"body_excerpt":"Contact patient@example.com about password=hunter2"},
      {"order":6,"state":"queued","structured":true,"id":"dependency","title":"Publish the dependent release","repo":"epsilon","kind":"ship","blocked_by":"build-old","blocked_reason":"wait for alpha landing","body_excerpt":"Acceptance criteria: release is published."},
      {"order":7,"state":"queued","structured":true,"id":"captain-choice","title":"Choose the rollout policy","repo":"alpha","kind":"captain","hold_kind":"captain","hold_reason":"pick conservative or fast rollout"},
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
      {"id":"design","home":"$home/design","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"queued":[{"id":"design-ready","title":"Refresh the delta design tokens","repo":"delta","kind":"ship","body_excerpt":"Acceptance criteria: token snapshots pass."}],"landed":[]},
      {"id":"quiet","home":"$home/quiet","current":{"state":"no_active_work","reason":null},"provenance":{"selected":"structured-home"},"active_children":[],"decisions_open":[],"queued":[],"landed":[]},
      {"id":"unknown-mate","home":"$home/unknown","current":{"state":"unknown","reason":"structured home snapshot timed out"},"provenance":{"selected":"unknown"},"active_children":[],"decisions_open":[],"queued":[],"landed":[]}
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
    and (.pipeline.ready | any(.id == "ready-safe"))
    and (.pipeline.ready | any(.id == "design-ready" and .owner == "design"))
    and (.readiness.conservative_overlap_gates | any(.id == "overlap-alpha"))
    and (.readiness.explicit_gates | any(.id == "dependency"))
    and (.readiness.explicit_gates | any(.id == "future-gate" and .reason == "time gate until 2026-08-01"))
    and (.readiness.definition_gaps | any(.id == "vague" and (.gaps | index("project unresolved"))))
    and (.lanes.persistent_secondmates | any(.id == "design" and .utilization == "idle with grounded ready in-scope work"))
    and (.lanes.persistent_secondmates | any(.id == "quiet" and (.utilization | startswith("healthy idle"))))
    and (.lanes.persistent_secondmates | any(.id == "unknown-mate" and .utilization == "unavailable"))
    and .primary_bottleneck.id == "CAP-03"
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
  assert_grep '&lt;script&gt;alert(1)&lt;/script&gt;' "$output" "dashboard did not escape hostile title markup"
  assert_no_grep 'topsecret' "$output" "dashboard leaked a token-like value"
  assert_no_grep 'hunter2' "$output" "dashboard leaked a password-like value"
  assert_no_grep 'patient@example.com' "$output" "dashboard leaked an email address"
  assert_no_grep 'src="http' "$output" "dashboard loads a remote script or image"
  assert_no_grep '@import' "$output" "dashboard imports a remote stylesheet"
  assert_no_grep 'lavish' "$output" "dashboard contains a Lavish dependency"
  assert_grep 'data-copy=' "$output" "dashboard lacks copyable action prompts"
  pass "dashboard is offline, escaped, privacy-bounded, accessible, responsive, and read-mostly"
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
test_unavailable_lanes_and_demand_shortage_are_distinct
test_html_is_private_escaped_accessible_and_responsive
test_fleet_snapshot_preserves_registered_scope_provenance
