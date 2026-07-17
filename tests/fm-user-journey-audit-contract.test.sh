#!/usr/bin/env bash
# Contract tests for the /user-journey-audit captain-invocable skill.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/user-journey-audit/SKILL.md"
AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"
ARCHITECTURE="$ROOT/docs/architecture.md"

test_skill_is_discoverable_and_single_owner() {
  assert_present "$SKILL" "user-journey-audit SKILL.md is missing"
  assert_grep 'name: user-journey-audit' "$SKILL" "skill frontmatter has the wrong name"
  assert_grep 'user-invocable: true' "$SKILL" "skill is not captain-invocable"
  assert_grep '  internal: true' "$SKILL" "skill is not hidden from standalone installation"
  assert_grep '/user-journey-audit' "$README" "README does not list the captain-invocable command"
  assert_grep "single owner of Firstmate's user-journey audit procedure" "$SKILL" \
    "skill does not declare its one-owner contract"
  pass "user-journey-audit is discoverable, captain-invocable, and the procedure owner"
}

test_one_target_and_idle_contract() {
  assert_grep 'One invocation audits one explicitly resolved application or project' "$SKILL" \
    "skill does not limit an invocation to one resolved target"
  assert_grep 'Never combine applications, repositories, deployments, or unrelated product surfaces' "$SKILL" \
    "skill can combine multiple targets"
  assert_grep 'never schedules, repeats, or initiates an audit' "$SKILL" \
    "skill can self-schedule"
  pass "each invocation resolves one application and never self-schedules"
}

test_safe_browser_environment() {
  for phrase in \
    'safe isolated local instance by default' \
    'chrome-devtools-axi' \
    'headless by default' \
    'Headed or visible browsing requires explicit captain authorization' \
    'Never browse or mutate production' \
    'use production credentials' \
    'call paid APIs' \
    'external mutation'; do
    assert_grep "$phrase" "$SKILL" "safe browser contract is missing '$phrase'"
  done
  pass "audit defaults to isolated local headless browser use without external effects"
}

test_personas_are_dynamic_bounded_and_complete() {
  assert_grep 'derive two to four personas from the product surfaces actually observed' "$SKILL" \
    "personas are not dynamically derived from observed product surfaces"
  assert_grep 'Do not use a permanently fixed new-user and returning-user pair' "$SKILL" \
    "skill still relies on the closed PR's fixed persona pair"
  for field in 'Goal.' 'Context of use.' 'Prior experience' 'Constraints' 'Observable success criteria'; do
    assert_grep "$field" "$SKILL" "persona definition is missing '$field'"
  done
  assert_grep 'before persona synthesis or source-led diagnosis' "$SKILL" \
    "fresh-user behavioral pass is not protected from source-led scripting"
  pass "personas are bounded, observed-product-derived, and behaviorally specified"
}

test_journey_matrix_covers_realistic_paths() {
  for phrase in \
    'primary success path' \
    'Navigation and findability' \
    'Input validation' \
    'Recovery from mistakes' \
    'Accessibility-relevant keyboard' \
    'Returning-user continuation'; do
    assert_grep "$phrase" "$SKILL" "journey matrix is missing '$phrase'"
  done
  assert_grep 'Exercise each journey end to end through the browser' "$SKILL" \
    "journeys are not required to run end to end"
  pass "browser journeys cover success, recovery, navigation, validation, accessibility, and return"
}

test_durable_evidence_and_report_classes() {
  for phrase in \
    'data/<id>/audit-notes.md' \
    'data/<id>/personas.md' \
    'data/<id>/evidence/' \
    'data/<id>/report.md' \
    'Confirmed defects' \
    'UX friction' \
    'Feature opportunities' \
    'Unresolved uncertainties'; do
    assert_grep "$phrase" "$SKILL" "durable audit contract is missing '$phrase'"
  done
  assert_grep 'Never capture passwords, tokens, cookies, API keys' "$SKILL" \
    "evidence contract does not protect secrets"
  assert_grep 'lavish-axi' "$SKILL" "skill does not produce the settled rendered review surface"
  pass "structured notes, durable evidence, report classes, and visual review are required"
}

test_ordinary_bug_fix_authority_is_bounded() {
  assert_grep 'implementation authorization only for confirmed defects that are ordinary, reversible' "$SKILL" \
    "automatic bug-fix authority is not limited to ordinary reversible defects"
  for phrase in \
    'destructive, irreversible, security-sensitive, privacy-sensitive, billing' \
    'production-impacting' \
    'Never auto-merge' \
    'does not permit a PR merge'; do
    assert_grep "$phrase" "$SKILL" "automatic bug-fix boundary is missing '$phrase'"
  done
  assert_grep 'add regression coverage' "$SKILL" \
    "automatic fixes do not require regression coverage"
  pass "ordinary bugs are implementation-authorized without expanding sensitive or merge authority"
}

test_fix_routing_uses_promotion_clean_base_and_deduplication() {
  for phrase in \
    'equivalent work already exists' \
    'Partition the remaining eligible defects by one shared causal boundary' \
    'Promote the existing scout in place with `bin/fm-promote.sh`' \
    'Do not create a new task for that group' \
    'return to a clean current default-branch base' \
    'carry over no audit edits or helpers' \
    'one separate ordinary ship item for each additional'; do
    assert_grep "$phrase" "$SKILL" "automatic fix routing is missing '$phrase'"
  done
  pass "automatic fixes deduplicate, promote in place, reset cleanly, and split unrelated groups"
}

test_features_are_queued_but_never_implemented() {
  assert_grep 'Add every evidence-backed non-duplicate feature opportunity to the authoritative backlog as queued work once any required product decision is resolved' "$SKILL" \
    "grounded features are not added to the authoritative queued backlog"
  assert_grep 'Do not implement, dispatch, or promote feature work from this invocation' "$SKILL" \
    "feature opportunities can be implemented automatically"
  assert_grep 'register the decision before the audit completes, then create the dependent queued feature only after the captain answers' "$SKILL" \
    "decision-dependent features bypass the decision lifecycle sequence"
  assert_grep 'user goal, affected personas, report path, evidence pointers' "$SKILL" \
    "feature backlog items are not grounded in report evidence"
  pass "grounded features become evidence-linked queued work without automatic implementation"
}

test_scratch_helpers_and_existing_safety_boundaries() {
  assert_grep 'scratch-only launch adapters, seed data, accessibility probes, or capture helpers' "$SKILL" \
    "skill does not permit bounded scratch-only audit helpers"
  assert_grep 'route it as ordinary ship work with tests and the configured validation path' "$SKILL" \
    "durable tooling can bypass the normal ship path"
  for phrase in \
    'configured delivery path' \
    'supervision' \
    'validation' \
    'decision-hold-lifecycle' \
    'tear it down only after its work lands'; do
    assert_grep "$phrase" "$SKILL" "existing lifecycle boundary is missing '$phrase'"
  done
  pass "scratch tooling and existing lifecycle safety boundaries remain explicit"
}

test_agents_stub_is_minimal_and_safety_critical() {
  assert_grep 'load `user-journey-audit`' "$AGENTS" \
    "AGENTS.md lacks the precise load trigger"
  assert_grep 'narrowly authorizes confirmed ordinary reversible bug implementation, never feature implementation or merge' "$AGENTS" \
    "AGENTS.md lacks the safety-critical authority stub"
  assert_grep 'The skill owns the persona, evidence, selection, and authority rules rather than duplicating them here.' "$ARCHITECTURE" \
    "architecture docs duplicate or fail to point at the procedure owner"
  pass "AGENTS.md retains only the trigger and safety boundary while the skill owns procedure"
}

test_skill_is_discoverable_and_single_owner
test_one_target_and_idle_contract
test_safe_browser_environment
test_personas_are_dynamic_bounded_and_complete
test_journey_matrix_covers_realistic_paths
test_durable_evidence_and_report_classes
test_ordinary_bug_fix_authority_is_bounded
test_fix_routing_uses_promotion_clean_base_and_deduplication
test_features_are_queued_but_never_implemented
test_scratch_helpers_and_existing_safety_boundaries
test_agents_stub_is_minimal_and_safety_critical
