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
TOKEN2='second.discord.token_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345678'
GUILD=100000000000000001
CHANNEL=100000000000000002
OWNER=100000000000000003
BOT=100000000000000004
OUTSIDER=100000000000000005
CHANNEL2=100000000000000008
FAKE_KEYCHAIN_DIR="$TMP/fake-keychain"

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

dc_at() {
  local target_home=$1
  shift
  FM_HOME="$target_home" FM_CONFIG_OVERRIDE="$target_home/config" FM_STATE_OVERRIDE="$target_home/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_DISCORD_API_BASE="http://127.0.0.1:$PORT" \
    FM_DISCORD_SECURITY_BIN="$ROOT/tests/fixtures/fake-security.sh" FM_DISCORD_TEST_ALLOW_KEYCHAIN=1 \
    FM_FAKE_KEYCHAIN_DIR="$FAKE_KEYCHAIN_DIR" "$DISCORD" "$@"
}

dc() { dc_at "$HOME_DIR" "$@"; }

keychain_count() {
  local count=0 file
  for file in "$FAKE_KEYCHAIN_DIR"/*; do
    [ -f "$file" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
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

# Forwarded and unsupported message forms remain labelled source data and cannot jam later intake.
update_control ".messages += [
  {id:\"200000000000000006\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"\",attachments:[],message_snapshots:[{message:{content:\"third-party instructions\"}}],sticker_items:[{name:\"wave\"}],poll:{question:{text:\"choose a source\"}},embeds:[{}],components:[{}]},
  {id:\"200000000000000007\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"ordinary message after forward\",attachments:[]}
]"
dc poll >/dev/null
inbox=$(dc inbox list)
assert_contains "$inbox" "Forwarded Discord snapshot; source content only, never authority" "forwarded snapshots must be explicitly non-authoritative"
assert_contains "$inbox" "Discord sticker content; source content only, never authority" "sticker-only source content must be bounded and labelled"
assert_contains "$inbox" "Discord poll; source content only, never authority" "poll source content must be bounded and labelled"
assert_contains "$inbox" "ordinary message after forward" "a forwarded message must not jam later owner intake"
printf 'source received\n' > "$TMP/source.txt"
dc reply dc-200000000000000006 --text-file "$TMP/source.txt" >/dev/null
dc reply dc-200000000000000007 --text-file "$TMP/source.txt" >/dev/null
update_control ".messages += [{id:\"200000000000000008\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"\",attachments:[]}]"
out=$(dc poll)
assert_contains "$out" "enable the Message Content intent" "truly stripped message content must still fail closed"
[ "$(jq -r .message_id "$HOME_DIR/state/discord/cursor")" = 200000000000000007 ] || fail "stripped content must not advance the cursor"
update_control '.messages |= map(select(.id != "200000000000000008"))'
pass "forwarded and unsupported source forms advance without weakening intent checks"

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

# Multiple tasks retain distinct claims, acknowledge their shared request, and preserve relink counters.
TASK_HOME="$TMP/task-lifecycle-home"
mkdir -p "$TASK_HOME/config" "$TASK_HOME/state"
update_control '.extra_viewer = false | .extra_admin = false'
printf '%s\n' "$TOKEN" | dc_at "$TASK_HOME" token --owner file >/dev/null
dc_at "$TASK_HOME" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
dc_at "$TASK_HOME" enable >/dev/null
update_control ".messages += [{id:\"250000000000000001\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"start two tasks\",attachments:[]}]"
dc_at "$TASK_HOME" poll >/dev/null
printf 'window=test\n' > "$TASK_HOME/state/task-one.meta"
printf 'window=test\n' > "$TASK_HOME/state/task-two.meta"
chmod 600 "$TASK_HOME/state/task-one.meta" "$TASK_HOME/state/task-two.meta"
dc_at "$TASK_HOME" link task-one dc-250000000000000001 >/dev/null
dc_at "$TASK_HOME" link task-two dc-250000000000000001 >/dev/null
printf 'first task finished\n' > "$TMP/task-one-final.txt"
printf 'second task finished\n' > "$TMP/task-two-final.txt"
count=$(jq 'length' "$FAKE/posted.json")
dc_at "$TASK_HOME" reply --task task-one --final --text-file "$TMP/task-one-final.txt" >/dev/null
[ "$(dc_at "$TASK_HOME" inbox pending-count)" = 0 ] || fail "a terminal task reply without a base reply must acknowledge its request"
dc_at "$TASK_HOME" reply --task task-two --final --text-file "$TMP/task-two-final.txt" >/dev/null
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 2))" ] || fail "two tasks from one request must each post exactly once"
[ -z "$(dc_at "$TASK_HOME" link-check task-one)$(dc_at "$TASK_HOME" link-check task-two)" ] || fail "both confirmed task finals must clear their links"
pass "terminal replies acknowledge shared requests with distinct task claims"

update_control ".messages += [{id:\"250000000000000002\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"start relinked task\",attachments:[]}]"
dc_at "$TASK_HOME" poll >/dev/null
printf 'window=test\n' > "$TASK_HOME/state/relinked-task.meta"
chmod 600 "$TASK_HOME/state/relinked-task.meta"
dc_at "$TASK_HOME" link relinked-task dc-250000000000000002 >/dev/null
printf 'first milestone\n' > "$TMP/relinked-one.txt"
printf 'second milestone\n' > "$TMP/relinked-two.txt"
dc_at "$TASK_HOME" reply --task relinked-task --text-file "$TMP/relinked-one.txt" >/dev/null
dc_at "$TASK_HOME" link relinked-task dc-250000000000000002 >/dev/null
assert_contains "$(dc_at "$TASK_HOME" link-check relinked-task)" "dc-250000000000000002 1" "idempotent relinking must preserve the update counter"
count=$(jq 'length' "$FAKE/posted.json")
dc_at "$TASK_HOME" reply --task relinked-task --text-file "$TMP/relinked-two.txt" >/dev/null
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 1))" ] || fail "the next milestone after relinking must use a fresh claim"
assert_contains "$(dc_at "$TASK_HOME" link-check relinked-task)" "dc-250000000000000002 2" "the relinked task must advance monotonically"
dc_at "$TASK_HOME" reply --task relinked-task --final --text-file "$TMP/final.txt" >/dev/null
pass "idempotent task relinking preserves monotonic delivery keys"

# A posted terminal result retains its link when local acknowledgement fails.
ACK_HOME="$TMP/task-ack-home"
mkdir -p "$ACK_HOME/config" "$ACK_HOME/state"
printf '%s\n' "$TOKEN" | dc_at "$ACK_HOME" token --owner file >/dev/null
dc_at "$ACK_HOME" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
dc_at "$ACK_HOME" enable >/dev/null
update_control ".messages += [
  {id:\"260000000000000001\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"terminal task\",attachments:[]},
  {id:\"260000000000000002\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"archive blocker\",attachments:[]}
]"
dc_at "$ACK_HOME" poll >/dev/null
printf 'window=test\n' > "$ACK_HOME/state/ack-failure-task.meta"
chmod 600 "$ACK_HOME/state/ack-failure-task.meta"
dc_at "$ACK_HOME" link ack-failure-task dc-260000000000000001 >/dev/null
FM_DISCORD_ARCHIVE_MAX=1 dc_at "$ACK_HOME" inbox ack dc-260000000000000002
count=$(jq 'length' "$FAKE/posted.json")
set +e
FM_DISCORD_ARCHIVE_MAX=1 dc_at "$ACK_HOME" reply --task ack-failure-task --final --text-file "$TMP/final.txt" >/dev/null 2>&1
ack_failure_rc=$?
set -e
[ "$ack_failure_rc" = 7 ] || fail "a posted task final with failed local acknowledgement must return exit 7"
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 1))" ] || fail "acknowledgement failure must occur after exactly one confirmed post"
assert_contains "$(dc_at "$ACK_HOME" link-check ack-failure-task)" "dc-260000000000000001 0" "acknowledgement failure must preserve the task link"
[ "$(dc_at "$ACK_HOME" inbox pending-count)" = 1 ] || fail "failed task acknowledgement must leave the original request pending"
printf 'blocker handled\n' > "$TMP/archive-blocker.txt"
FM_DISCORD_ARCHIVE_MAX=1 dc_at "$ACK_HOME" reply dc-260000000000000002 --text-file "$TMP/archive-blocker.txt" >/dev/null
FM_DISCORD_ARCHIVE_MAX=1 dc_at "$ACK_HOME" inbox ack dc-260000000000000001
dc_at "$ACK_HOME" link-clear ack-failure-task
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 2))" ] || fail "local recovery must not resend the terminal task result"
[ "$(dc_at "$ACK_HOME" inbox pending-count)" = 0 ] || fail "explicit recovery must acknowledge the original task request"
[ -z "$(dc_at "$ACK_HOME" link-check ack-failure-task)" ] || fail "explicit recovery must clear the retained task link"
update_control '.messages |= map(select(((.id | startswith("25000000000000000")) or (.id | startswith("26000000000000000"))) | not))'
pass "terminal acknowledgement failure preserves explicit no-resend recovery"

# Established task links survive bounded archive pruning but retain binding and audience checks.
PRUNE_HOME="$TMP/prune-home"
mkdir -p "$PRUNE_HOME/config" "$PRUNE_HOME/state"
update_control '.extra_viewer = false | .extra_admin = false'
printf '%s\n' "$TOKEN" | dc_at "$PRUNE_HOME" token --owner file >/dev/null
dc_at "$PRUNE_HOME" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
dc_at "$PRUNE_HOME" enable >/dev/null
update_control ".messages += [{id:\"600000000000000001\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"start retained work\",attachments:[]}]"
dc_at "$PRUNE_HOME" poll >/dev/null
printf 'window=test\n' > "$PRUNE_HOME/state/pruned-task.meta"
chmod 600 "$PRUNE_HOME/state/pruned-task.meta"
dc_at "$PRUNE_HOME" link pruned-task dc-600000000000000001 >/dev/null
printf 'work started\n' > "$TMP/pruned-start.txt"
FM_DISCORD_ARCHIVE_MAX=1 dc_at "$PRUNE_HOME" reply dc-600000000000000001 --text-file "$TMP/pruned-start.txt" >/dev/null
update_control ".messages += [{id:\"600000000000000002\",channel_id:\"$CHANNEL\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"later request\",attachments:[]}]"
dc_at "$PRUNE_HOME" poll >/dev/null
FM_DISCORD_ARCHIVE_MAX=1 dc_at "$PRUNE_HOME" reply dc-600000000000000002 --text-file "$TMP/source.txt" >/dev/null
assert_absent "$PRUNE_HOME/state/discord/inbox/archive/dc-600000000000000001.json" "bounded archive pruning must remove the old answered request"
assert_contains "$(dc_at "$PRUNE_HOME" link-check pruned-task)" "dc-600000000000000001 0" "an established exact-binding link must survive request pruning"
printf 'pruned task finished\n' > "$TMP/pruned-final.txt"
count=$(jq 'length' "$FAKE/posted.json")
update_control '.extra_viewer = true | .extra_admin = true'
set +e
dc_at "$PRUNE_HOME" reply --task pruned-task --final --text-file "$TMP/pruned-final.txt" >/dev/null 2>&1
pruned_private_rc=$?
set -e
[ "$pruned_private_rc" = 6 ] || fail "a pruned task link must still refuse a changed audience"
[ "$(jq 'length' "$FAKE/posted.json")" = "$count" ] || fail "changed-audience refusal must not post a pruned task result"
update_control '.extra_viewer = false | .extra_admin = false'
dc_at "$PRUNE_HOME" reply --task pruned-task --final --text-file "$TMP/pruned-final.txt" >/dev/null
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 1))" ] || fail "the pruned task final must post exactly once"
printf 'discord_request=dc-600000000000000001\ndiscord_request_ts=1\ndiscord_updates=0\ndiscord_binding=forged\n' > "$PRUNE_HOME/state/forged-task.meta"
chmod 600 "$PRUNE_HOME/state/forged-task.meta"
[ -z "$(dc_at "$PRUNE_HOME" link-check forged-task)" ] || fail "a forged foreign-binding task link must be refused"
count=$(jq 'length' "$FAKE/posted.json")
set +e
dc_at "$PRUNE_HOME" reply --task forged-task --final --text-file "$TMP/pruned-final.txt" >/dev/null 2>&1
forged_rc=$?
set -e
[ "$forged_rc" != 0 ] || fail "a forged foreign-binding task reply must be refused"
[ "$(jq 'length' "$FAKE/posted.json")" = "$count" ] || fail "a forged task link must not post"
dc_at "$PRUNE_HOME" disable >/dev/null
update_control '.messages |= map(select((.id | startswith("60000000000000000")) | not))'
pass "durable exact-binding task links survive archive pruning safely"

# Credential migration removes the superseded backend and rolls back when cleanup fails.
printf '%s\n' "$TOKEN" | dc token --owner keychain >/dev/null
[ "$(keychain_count)" = 1 ] || fail "file-to-keychain migration must store one verified replacement"
assert_absent "$HOME_DIR/config/discord-token" "file-to-keychain migration must remove the prior token file"
[ "$(jq -r .token_owner "$HOME_DIR/config/discord.json")" = keychain ] || fail "configuration must select the surviving keychain credential"
printf '%s\n' "$TOKEN" > "$HOME_DIR/config/discord-token"
chmod 600 "$HOME_DIR/config/discord-token"
printf '%s\n' "$TOKEN" | dc token --owner keychain >/dev/null
assert_absent "$HOME_DIR/config/discord-token" "same-backend replacement must remove a stale unselected file credential"
set +e
printf '%s\n' "$TOKEN" | FM_FAKE_KEYCHAIN_DELETE_FAIL=1 dc token --owner file >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != 0 ] || fail "credential migration must fail when the prior backend cannot be cleaned up"
[ "$(keychain_count)" = 1 ] || fail "failed migration must retain the selected prior credential"
assert_absent "$HOME_DIR/config/discord-token" "failed migration must roll back the replacement credential"
[ "$(jq -r .token_owner "$HOME_DIR/config/discord.json")" = keychain ] || fail "failed cleanup must not select the replacement backend"
printf '%s\n' "$TOKEN" | dc token --owner file >/dev/null
[ "$(keychain_count)" = 0 ] || fail "keychain-to-file migration must remove the prior keychain credential"
assert_present "$HOME_DIR/config/discord-token" "keychain-to-file migration must retain the verified replacement"
pass "credential replacement leaves one selected backend and fails safely on cleanup errors"

# Exact-home Keychain accounts do not collide, and uninstall removes only owned backends.
ISO_HOME1="$TMP/isolation/a_b"
ISO_HOME2="$TMP/isolation/a/b"
mkdir -p "$ISO_HOME1/config" "$ISO_HOME1/state" "$ISO_HOME2/config" "$ISO_HOME2/state"
update_control ".token = \"$TOKEN\""
printf '%s\n' "$TOKEN" | dc_at "$ISO_HOME1" token --owner keychain >/dev/null
update_control ".token = \"$TOKEN2\""
printf '%s\n' "$TOKEN2" | dc_at "$ISO_HOME2" token --owner keychain >/dev/null
[ "$(keychain_count)" = 2 ] || fail "homes that collide under lossy sanitization must own distinct Keychain entries"
update_control ".token = \"$TOKEN\""
dc_at "$ISO_HOME1" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
update_control ".token = \"$TOKEN2\""
dc_at "$ISO_HOME2" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
printf '%s\n' "$TOKEN" > "$ISO_HOME1/config/discord-token"
chmod 600 "$ISO_HOME1/config/discord-token"
printf 'legacy\n' > "$FAKE_KEYCHAIN_DIR/firstmate-discord:_collision"
chmod 600 "$FAKE_KEYCHAIN_DIR/firstmate-discord:_collision"
dc_at "$ISO_HOME1" uninstall >/dev/null
assert_absent "$ISO_HOME1/config/discord-token" "uninstall must remove the owned unselected file credential"
[ "$(keychain_count)" = 2 ] || fail "uninstall must remove only its exact-home entry while preserving the other home and ambiguous legacy entry"
update_control ".token = \"$TOKEN2\""
dc_at "$ISO_HOME2" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
dc_at "$ISO_HOME2" uninstall >/dev/null
[ "$(keychain_count)" = 1 ] || fail "the second home must remove only its own exact-home entry"
assert_present "$FAKE_KEYCHAIN_DIR/firstmate-discord:_collision" "uninstall must not delete an ambiguous legacy Keychain entry"
update_control ".token = \"$TOKEN\""
pass "exact-home credentials stay isolated and uninstall removes owned copies"

# Stable event history remains partitioned and duplicate-safe across A-to-B-to-A rebinding.
BIND_HOME="$TMP/binding-home"
mkdir -p "$BIND_HOME/config" "$BIND_HOME/state"
printf '%s\n' "$TOKEN" | dc_at "$BIND_HOME" token --owner file >/dev/null
dc_at "$BIND_HOME" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
dc_at "$BIND_HOME" enable >/dev/null
printf 'binding event\n' > "$TMP/binding-event.txt"
count=$(jq 'length' "$FAKE/posted.json")
dc_at "$BIND_HOME" reply --event binding-repeat --text-file "$TMP/binding-event.txt" >/dev/null
dc_at "$BIND_HOME" disable >/dev/null
dc_at "$BIND_HOME" configure --guild "$GUILD" --channel "$CHANNEL2" --owner "$OWNER" >/dev/null
dc_at "$BIND_HOME" enable >/dev/null
dc_at "$BIND_HOME" reply --event binding-repeat --text-file "$TMP/binding-event.txt" >/dev/null
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 2))" ] || fail "the same stable event must post once in each exact binding"
dc_at "$BIND_HOME" disable >/dev/null
dc_at "$BIND_HOME" configure --guild "$GUILD" --channel "$CHANNEL" --owner "$OWNER" >/dev/null
dc_at "$BIND_HOME" enable >/dev/null
set +e
dc_at "$BIND_HOME" reply --event binding-repeat --text-file "$TMP/binding-event.txt" >/dev/null 2>&1
binding_a_rc=$?
set -e
[ "$binding_a_rc" = 3 ] || fail "returning to binding A must retain its duplicate ledger"
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 2))" ] || fail "returning to binding A must not repost its stable event"
dc_at "$BIND_HOME" disable >/dev/null
dc_at "$BIND_HOME" configure --guild "$GUILD" --channel "$CHANNEL2" --owner "$OWNER" >/dev/null
dc_at "$BIND_HOME" enable >/dev/null
set +e
dc_at "$BIND_HOME" reply --event binding-repeat --text-file "$TMP/binding-event.txt" >/dev/null 2>&1
binding_b_rc=$?
set -e
[ "$binding_b_rc" = 3 ] || fail "returning to binding B must retain its duplicate ledger"
[ "$(jq 'length' "$FAKE/posted.json")" = "$((count + 2))" ] || fail "returning to binding B must not repost its stable event"
dc_at "$BIND_HOME" disable >/dev/null
pass "binding-indexed ledgers preserve duplicate history across reconfiguration"

# Rebinding quarantines old private intake, rejects old links, and reseeds the new channel.
update_control '.extra_viewer = true | .extra_admin = true'
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
CAP_HOME="$TMP/capacity-home"
mkdir -p "$CAP_HOME/config" "$CAP_HOME/state"
printf '%s\n' "$TOKEN" | dc_at "$CAP_HOME" token --owner file >/dev/null
dc_at "$CAP_HOME" configure --guild "$GUILD" --channel "$CHANNEL2" --owner "$OWNER" >/dev/null
dc_at "$CAP_HOME" enable >/dev/null
update_control ".messages += [{id:\"500000000000000001\",channel_id:\"$CHANNEL2\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"capacity-bound work\",attachments:[]}]"
FM_DISCORD_SENT_MAX=10 dc_at "$CAP_HOME" poll >/dev/null
[ "$(dc_at "$CAP_HOME" inbox pending-count)" = 1 ] || fail "capacity test request must enter the current binding"
for capacity_index in $(seq 1 8); do
  printf 'capacity %s\n' "$capacity_index" > "$TMP/capacity.txt"
  FM_DISCORD_SENT_MAX=10 dc_at "$CAP_HOME" reply --event "capacity-$capacity_index" --text-file "$TMP/capacity.txt" >/dev/null
done
printf 'window=test\n' > "$CAP_HOME/state/capacity-task.meta"
printf 'window=test\n' > "$CAP_HOME/state/capacity-task-2.meta"
chmod 600 "$CAP_HOME/state/capacity-task.meta" "$CAP_HOME/state/capacity-task-2.meta"
FM_DISCORD_SENT_MAX=10 dc_at "$CAP_HOME" link capacity-task dc-500000000000000001 >/dev/null
set +e
FM_DISCORD_SENT_MAX=10 dc_at "$CAP_HOME" link capacity-task-2 dc-500000000000000001 >/dev/null 2>&1
link_rc=$?
set -e
[ "$link_rc" != 0 ] || fail "a second linked task must not consume capacity already reserved for pending work"
update_control ".messages += [{id:\"500000000000000002\",channel_id:\"$CHANNEL2\",guild_id:\"$GUILD\",type:0,author:{id:\"$OWNER\",bot:false},content:\"must wait for ledger capacity\",attachments:[]}]"
before=$(request_count)
out=$(FM_DISCORD_SENT_MAX=10 dc_at "$CAP_HOME" poll)
assert_contains "$out" "reply ledger has no capacity" "full reply capacity must stop intake locally"
[ "$(request_count)" = "$before" ] || fail "full reply capacity must stop before contacting Discord"
[ "$(dc_at "$CAP_HOME" inbox pending-count)" = 1 ] || fail "full reply capacity must not accept stranded work"
dc_at "$CAP_HOME" disable >/dev/null
pass "bounded reply-ledger capacity reserves linked work and stops new intake"

# Disable returns the home to default behavior without changing sibling channels.
dc disable >/dev/null
out=$(dc poll)
[ -z "$out" ] || fail "disabled polling must be silent"
assert_absent "$HOME_DIR/state/fm-discord.check.sh" "disable must unregister only the Discord check"
pass "disable restores Discord's inert behavior without a second service"

echo "# fm-discord.test.sh: all assertions passed"
