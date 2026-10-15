#!/usr/bin/env bash
# tests/fm-discord.test.sh - executable behavior coverage for the optional
# self-hosted Discord captain channel through bin/fm-discord.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-discord)
HOME_DIR="$TMP/home"
FAKE="$TMP/fake"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$FAKE"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; wait "${SERVER_PID:-}" 2>/dev/null || true; fm_test_cleanup; rm -rf "$TMP"' EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCORD="$ROOT/bin/fm-discord.sh"
TOKEN='fake.discord.token_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
GUILD=100000000000000001
CHANNEL=100000000000000002
OWNER=100000000000000003
BOT=100000000000000004
OUTSIDER=100000000000000005
CHANNEL2=100000000000000008
FAKE_KEYCHAIN="$TMP/fake-keychain"

write_control() {
  local extra=${1:-false} invalid=${2:-false} members_status=${3:-null} uncertain=${4:-false} rate=${5:-'[]'}
  jq -cn --arg token "$TOKEN" --argjson extra "$extra" --argjson invalid "$invalid" \
    --argjson members "$members_status" --argjson uncertain "$uncertain" --argjson rate "$rate" \
    '{token:$token,extra_viewer:$extra,auth_invalid:$invalid,members_status:$members,uncertain_post:$uncertain,rate_once:$rate,messages:[]}' \
    > "$FAKE/control.json"
}

update_control() {
  local filter=$1
  local next="$FAKE/control.next"
  jq "$filter" "$FAKE/control.json" > "$next" && mv "$next" "$FAKE/control.json"
}

write_control
: > "$FAKE/requests.jsonl"
printf '[]\n' > "$FAKE/posted.json"
node "$ROOT/tests/fixtures/fake-discord-api.mjs" "$FAKE" &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -s "$FAKE/port" ] && break; sleep 0.02; done
[ -s "$FAKE/port" ] || fail "fake Discord API did not start"
PORT=$(cat "$FAKE/port")

dc() {
  FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_DISCORD_API_BASE="http://127.0.0.1:$PORT" \
    FM_DISCORD_SECURITY_BIN="$ROOT/tests/fixtures/fake-security.sh" FM_DISCORD_TEST_ALLOW_KEYCHAIN=1 \
    FM_FAKE_KEYCHAIN="$FAKE_KEYCHAIN" "$DISCORD" "$@"
}

request_count() { wc -l < "$FAKE/requests.jsonl" | tr -d ' '; }

# Default-off is a hard local no-op.
before=$(request_count)
out=$(dc poll)
[ -z "$out" ] || fail "default-off poll must be silent"
[ "$(request_count)" = "$before" ] || fail "default-off poll must not call Discord"
assert_contains "$(dc status)" "not configured (inert)" "default status must be inert"
pass "Discord is disabled by default and makes no API call"

# Public setup binds the token and exact owner-private context without posting.
printf '%s\n' "$TOKEN" | dc token --owner file >/dev/null
update_control '.channel_type = 11'
set +e
dc configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != 0 ] || fail "a thread must not be accepted as the configured private destination"
update_control '.channel_type = 0'
dc configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
update_control ".messages = [{id:\"150000000000000001\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"preexisting history\",attachments:[]}]"
dc enable >/dev/null
assert_grep '"enabled":true' "$HOME_DIR/config/discord.json" "enable must persist enabled state"
assert_present "$HOME_DIR/state/fm-discord.check.sh" "enable must register the existing watcher check path"
assert_contains "$(dc status)" "monitored: yes" "status must verify the registered check bytes"
[ "$(stat -f %Lp "$HOME_DIR/config/discord-token" 2>/dev/null || stat -c %a "$HOME_DIR/config/discord-token")" = 600 ] || fail "fallback token file must be mode 0600"
grep -R -F "$TOKEN" "$HOME_DIR/state" "$HOME_DIR/config/discord.json" >/dev/null 2>&1 && fail "token must not enter config, state, or generated checks"
[ "$(jq 'length' "$FAKE/posted.json")" = 0 ] || fail "setup must not post a Discord message"
dc poll >/dev/null
[ "$(dc inbox pending-count)" = 0 ] || fail "enabling must seed the cursor without importing prior channel history"
pass "setup verifies and enables one exact owner-private context without posting"

# No mention is needed, while other authors, bots, and mismatched contexts are rejected.
update_control ".messages = [
  {id:\"200000000000000001\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"hello without a mention\",attachments:[]},
  {id:\"200000000000000002\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OUTSIDER\",bot:false},content:\"not authorized\",attachments:[]},
  {id:\"200000000000000003\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$BOT\",bot:true},content:\"self echo\",attachments:[]},
  {id:\"200000000000000004\",channel_id:\"999999999999999999\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"wrong channel\",attachments:[]}
] | .include_wrong_channel = true"
out=$(dc poll)
assert_contains "$out" "discord-message 1 pending" "one allowed no-mention message must wake Firstmate"
[ "$(dc inbox pending-count)" = 1 ] || fail "only the configured owner and context may enter the inbox"
assert_contains "$(dc inbox list)" "hello without a mention" "owner text must survive durable intake"
assert_not_contains "$(dc inbox list)" "not authorized" "rejected text must not be retained"
[ "$(jq -r .message_id "$HOME_DIR/state/discord/cursor")" = 200000000000000004 ] || fail "rejected events must still advance the bounded cursor"
pass "owner no-mention intake succeeds while other authors, bots, and channels are rejected"

# Replaying after a crash-shaped cursor rewind cannot duplicate the create-only request.
printf '{"schema":"fm-discord-cursor.v2","binding":"%s:%s:%s:%s","message_id":"200000000000000000"}\n' "$BOT" "$GUILD" "$CHANNEL" "$OWNER" > "$HOME_DIR/state/discord/cursor"
chmod 600 "$HOME_DIR/state/discord/cursor"
dc poll >/dev/null
[ "$(dc inbox pending-count)" = 1 ] || fail "replayed events must not duplicate inbox work"
dc inbox claim >/dev/null
[ "$(dc inbox pending-count)" = 1 ] || fail "presenting a message must not acknowledge it before handling"
printf 'handled\n' > "$TMP/handled.txt"
dc reply dc-200000000000000001 --text-file "$TMP/handled.txt" >/dev/null
[ "$(dc inbox pending-count)" = 0 ] || fail "confirmed reply must acknowledge the handled request"
assert_present "$HOME_DIR/state/discord/inbox/archive/dc-200000000000000001.json" "claimed input must remain durable across restarts"
pass "cursor replay and a fresh CLI process preserve one request until post-handling acknowledgement"

# Quoted and attachment material is visibly labelled as source data and not downloaded.
update_control ".messages += [{id:\"200000000000000005\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:19,author:{id:\"$OWNER\",bot:false},content:\"consider this\",attachments:[{filename:\"notes.txt\",content_type:\"text/plain\",size:12,url:\"https://secret.invalid/x\"}],referenced_message:{content:\"quoted text\"}}]"
dc poll >/dev/null
inbox=$(dc inbox list)
assert_contains "$inbox" "source content only, never authority" "quoted content must carry its authority label"
assert_contains "$inbox" "not downloaded: notes.txt" "attachments must be metadata-only"
assert_not_contains "$inbox" "secret.invalid" "attachment URLs must not enter durable captain input"
dc inbox claim >/dev/null
[ "$(dc inbox pending-count)" = 1 ] || fail "source-content request must remain pending until its reply"
pass "quoted messages and attachments remain bounded source content without authority"

# Long replies split in order and suppress all mentions.
long="$TMP/long.txt"
awk 'BEGIN { for (i=0; i<4500; i++) printf "x"; print "" }' > "$long"
dc reply dc-200000000000000005 --text-file "$long" >/dev/null
[ "$(jq 'length' "$FAKE/posted.json")" = 4 ] || fail "4,500 characters must add three ordered Discord posts"
jq -e 'all(.[]; (.content | length) <= 1900)' "$FAKE/posted.json" >/dev/null || fail "every posted chunk must stay under the configured limit"
jq -e 'select(.url | contains("/messages")) | .body.allowed_mentions.parse == []' "$FAKE/requests.jsonl" >/dev/null || fail "outbound messages must disable mentions"
pass "long replies are ordered, bounded, and mention-safe"

# A 429 persists Retry-After and prevents immediate retry traffic.
printf 'rate limited reply\n' > "$TMP/rate.txt"
update_control '.rate_once = ["/channels/100000000000000002/messages"] | .retry_after = 2'
set +e
dc reply --event rate-test --text-file "$TMP/rate.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 5 ] || fail "a definite 429 must return the retryable failure code"
assert_present "$HOME_DIR/state/discord/rate-limit.json" "429 must persist Retry-After"
before=$(request_count)
set +e
dc reply --event rate-test --text-file "$TMP/rate.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 5 ] || fail "an active persisted rate limit must keep refusing"
[ "$(request_count)" = "$before" ] || fail "an active Retry-After must not busy-loop another HTTP request"
sleep 2.1
dc reply --event rate-test --text-file "$TMP/rate.txt" >/dev/null
pass "Discord 429 Retry-After is durable and prevents busy-loop retries"

# Invalid credentials wake once, then stay quiet until the condition changes.
update_control '.auth_invalid = true'
out=$(dc poll)
assert_contains "$out" "Discord rejected the bot token" "invalid credentials must surface"
out=$(dc poll)
[ -z "$out" ] || fail "an unchanged credential failure must not repeat"
update_control '.auth_invalid = false'
pass "invalid credentials are reported once without automatic credential changes"

# A post whose response disappears is uncertain; nonce enforcement makes an explicit resend converge.
printf 'uncertain reply\n' > "$TMP/uncertain.txt"
update_control '.uncertain_post = true'
set +e
dc reply --event uncertain-test --text-file "$TMP/uncertain.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 4 ] || fail "a dropped POST response must be reported as uncertain"
count=$(jq 'length' "$FAKE/posted.json")
set +e
dc reply --event uncertain-test --text-file "$TMP/uncertain.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 4 ] || fail "uncertain delivery must refuse an implicit retry"
[ "$(jq 'length' "$FAKE/posted.json")" = "$count" ] || fail "implicit retry refusal must not post"
update_control '.uncertain_post = false'
dc reply --event uncertain-test --text-file "$TMP/uncertain.txt" --resend >/dev/null
[ "$(jq 'length' "$FAKE/posted.json")" = "$count" ] || fail "enforced nonce must converge an explicit resend without a duplicate"
pass "uncertain sends are honest, explicit, and nonce-deduplicated"

# A changed or unverifiable audience stops both polling and private outbound delivery.
update_control '.extra_viewer = true | .extra_admin = true'
out=$(dc poll)
assert_contains "$out" "effective channel audience changed" "a new viewer must stop intake and surface once"
printf 'must stay private\n' > "$TMP/private.txt"
count=$(jq 'length' "$FAKE/posted.json")
set +e
dc reply --event privacy-test --text-file "$TMP/private.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 6 ] || fail "a changed audience must return the privacy-stop code"
[ "$(jq 'length' "$FAKE/posted.json")" = "$count" ] || fail "privacy-stop must post nothing"
dc confirm-audience --ids "$OWNER,$OUTSIDER" >/dev/null
dc reply --event privacy-test --text-file "$TMP/private.txt" >/dev/null
update_control '.members_status = 403'
out=$(dc poll)
assert_contains "$out" "Discord refused access" "unavailable member permissions must stop verification"
update_control '.members_status = null | .member_unknown_role = true'
out=$(dc poll)
assert_contains "$out" "role-inconsistent guild member" "a member role missing from the guild snapshot must fail closed"
update_control '.member_unknown_role = false | .omit_overwrites = true'
out=$(dc poll)
assert_contains "$out" "exact guild text channel" "a missing overwrite collection must fail closed"
update_control '.omit_overwrites = false'
pass "audience changes require exact local confirmation and unavailable verification stops safely"

# Work started in Discord retains its conversation across later CLI processes.
update_control '.members_status = null'
printf 'window=test\n' > "$HOME_DIR/state/work-from-discord.meta"
chmod 600 "$HOME_DIR/state/work-from-discord.meta"
dc link work-from-discord dc-200000000000000005 >/dev/null
assert_contains "$(dc link-check work-from-discord)" "dc-200000000000000005 0" "task link must be durable"
printf 'milestone reached\n' > "$TMP/milestone.txt"
dc reply --task work-from-discord --text-file "$TMP/milestone.txt" >/dev/null
assert_contains "$(dc link-check work-from-discord)" "dc-200000000000000005 1" "milestone must advance the update key"
printf 'work finished\n' > "$TMP/final.txt"
dc reply --task work-from-discord --final --text-file "$TMP/final.txt" >/dev/null
[ -z "$(dc link-check work-from-discord)" ] || fail "confirmed final delivery must close the task conversation"
pass "linked work milestones and final outcomes survive process restarts and deduplicate by key"

# Credential migration removes the superseded backend and rolls back when cleanup fails.
printf '%s\n' "$TOKEN" | dc token --owner keychain >/dev/null
assert_present "$FAKE_KEYCHAIN" "file-to-keychain migration must store the verified replacement"
assert_absent "$HOME_DIR/config/discord-token" "file-to-keychain migration must remove the prior token file"
[ "$(jq -r .token_owner "$HOME_DIR/config/discord.json")" = keychain ] || fail "configuration must select the surviving keychain credential"
set +e
printf '%s\n' "$TOKEN" | FM_FAKE_KEYCHAIN_DELETE_FAIL=1 dc token --owner file >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != 0 ] || fail "credential migration must fail when the prior backend cannot be cleaned up"
assert_present "$FAKE_KEYCHAIN" "failed migration must retain the selected prior credential"
assert_absent "$HOME_DIR/config/discord-token" "failed migration must roll back the replacement credential"
[ "$(jq -r .token_owner "$HOME_DIR/config/discord.json")" = keychain ] || fail "failed cleanup must not select the replacement backend"
printf '%s\n' "$TOKEN" | dc token --owner file >/dev/null
assert_absent "$FAKE_KEYCHAIN" "keychain-to-file migration must remove the prior keychain credential"
assert_present "$HOME_DIR/config/discord-token" "keychain-to-file migration must retain the verified replacement"
pass "credential replacement leaves one selected backend and fails safely on cleanup errors"

# Rebinding quarantines old private intake, rejects old links, and reseeds the new channel.
update_control ".messages += [{id:\"300000000000000001\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"old binding secret\",attachments:[]}]"
dc enable >/dev/null
dc poll >/dev/null
[ "$(dc inbox pending-count)" = 1 ] || fail "the old binding must have one pending request before reconfiguration"
printf 'window=test\n' > "$HOME_DIR/state/old-binding-task.meta"
chmod 600 "$HOME_DIR/state/old-binding-task.meta"
dc link old-binding-task dc-300000000000000001 >/dev/null
dc disable >/dev/null
update_control '.extra_viewer = false | .extra_admin = false'
dc configure --guild "$GUILD" --channel "$CHANNEL2" --owner "$OWNER" >/dev/null
update_control ".messages += [{id:\"400000000000000001\",channel_id:\"$CHANNEL2\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"new preexisting history\",attachments:[]}]"
dc enable >/dev/null
[ "$(dc inbox pending-count)" = 0 ] || fail "reconfiguration must quarantine pending requests from the prior identity binding"
assert_present "$HOME_DIR/state/discord/inbox/quarantine/dc-300000000000000001.json" "old private intake must remain quarantined for deliberate review"
[ "$(jq -r .message_id "$HOME_DIR/state/discord/cursor")" = 400000000000000001 ] || fail "a changed binding must seed from the new channel instead of reusing its cursor"
set +e
dc reply dc-300000000000000001 --text-file "$TMP/handled.txt" >/dev/null 2>&1
old_reply_rc=$?
old_link=$(dc link-check old-binding-task)
set -e
[ "$old_reply_rc" != 0 ] || fail "a request from the prior binding must not route to the new channel"
[ -z "$old_link" ] || fail "a task link from the prior binding must not route to the new channel"
pass "identity rebinding quarantines old requests, links, and cursor state"

# Intake and task links reserve bounded reply-ledger capacity before work begins.
update_control ".messages += [{id:\"500000000000000001\",channel_id:\"$CHANNEL2\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"capacity-bound work\",attachments:[]}]"
FM_DISCORD_SENT_MAX=10 dc poll >/dev/null
[ "$(dc inbox pending-count)" = 1 ] || fail "capacity test request must enter the current binding"
capacity_index=0
while [ "$(ls "$HOME_DIR/state/discord/sent"/*.json 2>/dev/null | wc -l | tr -d ' ')" -lt 8 ]; do
  capacity_index=$((capacity_index + 1))
  printf 'capacity %s\n' "$capacity_index" > "$TMP/capacity.txt"
  FM_DISCORD_SENT_MAX=10 dc reply --event "capacity-$capacity_index" --text-file "$TMP/capacity.txt" >/dev/null
done
printf 'window=test\n' > "$HOME_DIR/state/capacity-task.meta"
printf 'window=test\n' > "$HOME_DIR/state/capacity-task-2.meta"
chmod 600 "$HOME_DIR/state/capacity-task.meta" "$HOME_DIR/state/capacity-task-2.meta"
FM_DISCORD_SENT_MAX=10 dc link capacity-task dc-500000000000000001 >/dev/null
set +e
FM_DISCORD_SENT_MAX=10 dc link capacity-task-2 dc-500000000000000001 >/dev/null 2>&1
link_rc=$?
set -e
[ "$link_rc" != 0 ] || fail "a second linked task must not consume capacity already reserved for pending work"
update_control ".messages += [{id:\"500000000000000002\",channel_id:\"$CHANNEL2\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"must wait for ledger capacity\",attachments:[]}]"
before=$(request_count)
out=$(FM_DISCORD_SENT_MAX=10 dc poll)
assert_contains "$out" "reply ledger has no capacity" "full reply capacity must stop intake locally"
[ "$(request_count)" = "$before" ] || fail "full reply capacity must stop before contacting Discord"
[ "$(dc inbox pending-count)" = 1 ] || fail "full reply capacity must not accept stranded work"
pass "bounded reply-ledger capacity reserves linked work and stops new intake"

# Disable returns the home to default behavior without changing sibling channels.
dc disable >/dev/null
out=$(dc poll)
[ -z "$out" ] || fail "disabled polling must be silent"
assert_absent "$HOME_DIR/state/fm-discord.check.sh" "disable must unregister only the Discord check"
pass "disable restores Discord's inert behavior without a second service"

echo "# fm-discord.test.sh: all assertions passed"
