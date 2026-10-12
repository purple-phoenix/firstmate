#!/usr/bin/env bash
# Semantic contract test for the PR body compliance workflow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

ruby - "$WORKFLOW" <<'RUBY' || fail "no-mistakes required workflow contract is invalid"
require "json"
require "yaml"

workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
trigger = workflow["on"] || workflow[true]
pull_request = trigger.fetch("pull_request")
expected_types = %w[opened edited synchronize reopened]
raise "pull_request types" unless pull_request.fetch("types") == expected_types
raise "main branch" unless pull_request.fetch("branches") == ["main"]

permissions = workflow.fetch("permissions")
raise "contents permission" unless permissions.fetch("contents") == "read"
raise "pull-request permission" unless permissions.fetch("pull-requests") == "read"

group = workflow.fetch("concurrency").fetch("group")
expected_group = "no-mistakes-required-${{ github.event.pull_request.number }}-${{ (github.event.action == 'opened' || github.event.action == 'edited') && github.run_id || 'head-change' }}"
raise "event concurrency identity" unless group == expected_group
raise "head cancellation" unless workflow.fetch("concurrency").fetch("cancel-in-progress") == true

run_name = workflow.fetch("run-name")
%w[github.event.action github.run_number github.run_id].each do |field|
  raise "run name missing #{field}" unless run_name.include?(field)
end

job = workflow.fetch("jobs").fetch("check")
raise "stable check name" unless job.fetch("name") == "PR must be raised via no-mistakes"
condition = job.fetch("if")
raise "github-actions exemption" unless condition.include?("github-actions[bot]")
raise "dependabot exemption" unless condition.include?("dependabot[bot]")
raise "release-please exemption" if condition.include?("release-please[bot]")

steps = job.fetch("steps")
raise "one delegated attestation step" unless steps.length == 1
step = steps.fetch(0)
expected_action = "kunchenguid/no-mistakes/.github/actions/require-no-mistakes@f6441c96c352a18b9cadcaef6b6c7017e9ac3970"
raise "pinned attestation action" unless step.fetch("uses") == expected_action
raise "maintainer exemption" unless step.fetch("with").fetch("exempt-authors") == "kunchenguid"

normalized = JSON.generate(workflow)
raise "workflow checks out fork code" if normalized.include?("actions/checkout")
raise "workflow reads secrets" if normalized.include?("secrets.")
raise "workflow grants write" if permissions.values.include?("write")
RUBY

pass "no-mistakes workflow semantically preserves event identity, permissions, and pinned attestation"
