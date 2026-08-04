#!/usr/bin/env bash
# tests/fm-telegram.test.sh - behavior and security regression for the Telegram
# captain channel (bin/fm-tg-lib.sh, fm-tg-setup.sh, fm-tg-poll.sh,
# fm-tg-inbox.sh, fm-tg-reply.sh).
#
# Everything runs against a loopback fake Bot API and a fake keychain, so the
# suite is deterministic and never touches Telegram, the network beyond
# 127.0.0.1, or the operator's real keychain.
#
# The fake logs every request it receives, and a curl shim logs every argument
# vector, which is what lets this suite PROVE the token never reaches a process
# argument and never leaves the transport layer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "ok - skipped (node is required)"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "ok - skipped (jq is required)"; exit 0; }

# fm_test_tmproot registers its own EXIT cleanup, which fires inside the command
# substitution that captures the path, so recreate the directory here and own the
# teardown from this file (the same shape every other suite here uses).
TMP_ROOT=$(fm_test_tmproot fm-telegram)
mkdir -p "$TMP_ROOT"
TOKEN='1234567890:AAFakeTokenForTestsOnly_NotReal_abcdef'
USER_ID=4242424242
CHAT_ID=4242424242
API_LOG="$TMP_ROOT/api.log"
CURL_LOG="$TMP_ROOT/curl-argv.log"
SCENARIO="$TMP_ROOT/scenario.json"
FAKE_PID=

cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  fm_test_cleanup
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# --- fake Telegram Bot API --------------------------------------------------
#
# Reads $SCENARIO on every request, so a test can change the server's behavior
# between calls without restarting it.

cat > "$TMP_ROOT/fake-telegram.mjs" <<'JS'
import http from "node:http";
import fs from "node:fs";

const [, , scenarioPath, logPath, portPath] = process.argv;
const readScenario = () => {
  try { return JSON.parse(fs.readFileSync(scenarioPath, "utf8")); } catch { return {}; }
};

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const m = /^\/bot([^/]+)\/([A-Za-z]+)$/.exec(req.url ?? "");
    const token = m ? m[1] : "";
    const method = m ? m[2] : "";
    fs.appendFileSync(logPath, JSON.stringify({ method, token, body }) + "\n");
    const s = readScenario();
    const reply = (code, obj) => {
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    if (!m) return reply(404, { ok: false });
    if (s.reject_token && token !== s.reject_token) { /* fallthrough */ }
    if (method === "getMe") {
      if (s.getMe_status && s.getMe_status !== 200) return reply(s.getMe_status, { ok: false, description: "unauthorized" });
      return reply(200, { ok: true, result: { id: 1234567890, is_bot: true, username: "firstmate_test_bot" } });
    }
    if (method === "deleteWebhook") return reply(200, { ok: true, result: true });
    if (method === "getUpdates") {
      if (s.getUpdates_status && s.getUpdates_status !== 200) return reply(s.getUpdates_status, { ok: false, description: "nope" });
      if (s.getUpdates_malformed) { res.writeHead(200, { "content-type": "application/json" }); return res.end("{not json"); }
      let request = {};
      try { request = JSON.parse(body || "{}"); } catch {}
      const offset = Number.isInteger(request.offset) ? request.offset : 0;
      const limit = Number.isInteger(request.limit) ? request.limit : 100;
      const updates = (s.updates ?? []).filter((u) => Number.isInteger(u?.update_id) && u.update_id >= offset).slice(0, limit);
      return reply(200, { ok: true, result: updates });
    }
    if (method === "sendMessage") {
      if (s.sendMessage_hang) { return; }  // never answers: exercises the ambiguous path
      const n = (s.sendMessage_calls = (s.sendMessage_calls ?? 0));
      if (s.sendMessage_status && s.sendMessage_status !== 200) {
        return reply(s.sendMessage_status, { ok: false, description: "refused" });
      }
      if (s.sendMessage_fail_after !== undefined) {
        const sent = fs.readFileSync(logPath, "utf8").split("\n").filter((l) => l.includes('"sendMessage"')).length;
        if (sent > s.sendMessage_fail_after) return reply(500, { ok: false, description: "server error" });
      }
      void n;
      return reply(200, { ok: true, result: { message_id: 1 } });
    }
    return reply(404, { ok: false });
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portPath, String(server.address().port));
});
JS

: > "$API_LOG"
printf '{}\n' > "$SCENARIO"
node "$TMP_ROOT/fake-telegram.mjs" "$SCENARIO" "$API_LOG" "$TMP_ROOT/port" &
FAKE_PID=$!
disown "$FAKE_PID" 2>/dev/null || true
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.1; done
[ -s "$TMP_ROOT/port" ] || fail "the fake Telegram API never came up"
PORT=$(cat "$TMP_ROOT/port")
API_BASE="http://127.0.0.1:$PORT"

scenario() { printf '%s\n' "$1" > "$SCENARIO"; }
api_calls() { grep -c "\"$1\"" "$API_LOG" 2>/dev/null || true; }

# --- fake keychain and a curl shim that records its own argv ----------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
KEYSTORE="$TMP_ROOT/keychain-store"
mkdir -p "$KEYSTORE"

cat > "$FAKEBIN/security" <<'SH'
#!/usr/bin/env bash
# Fake `security`, so no test ever touches the operator's real keychain. It
# stores the value read on STDIN, exactly like the real prompt path, so a test
# that passed a secret in argv would store the wrong thing and fail loudly.
set -u
store=${FM_TG_TEST_KEYSTORE:?}
action=$1; shift
acct=; svc=
while [ $# -gt 0 ]; do
  case "$1" in
    -a) acct=$2; shift 2 ;;
    -s) svc=$2; shift 2 ;;
    *) shift ;;
  esac
done
key=$(printf '%s/%s' "$svc" "$acct" | tr -c 'A-Za-z0-9._-' '_')
case "$action" in
  add-generic-password) IFS= read -r v || true; printf '%s\n' "$v" > "$store/$key" ;;
  find-generic-password) [ -f "$store/$key" ] || exit 44; cat "$store/$key" ;;
  delete-generic-password)
    [ "${FM_TG_TEST_SECURITY_DELETE_FAIL:-0}" = 0 ] || exit 55
    rm -f -- "$store/$key"
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/security"

REAL_CURL=$(command -v curl)
cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CURL_LOG"
[ -z "\${FM_TG_TEST_CURL_RC:-}" ] || exit "\$FM_TG_TEST_CURL_RC"
exec "$REAL_CURL" "\$@"
SH
chmod +x "$FAKEBIN/curl"
: > "$CURL_LOG"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

tg() {
  local script=$1; shift
  PATH="$FAKEBIN:$PATH" \
  FM_HOME="$HOME_DIR" \
  FM_TG_API_BASE="$API_BASE" \
  FM_TG_TEST_KEYSTORE="$KEYSTORE" \
  FM_TG_TEST_ALLOW_KEYCHAIN=1 \
  FM_TG_SECURITY_BIN=security \
  "$ROOT/bin/$script" "$@"
}

config_field() { jq -r "$1" "$HOME_DIR/config/telegram.json" 2>/dev/null; }

# =============================================================================
# 1. Ships inert
# =============================================================================

out=$(tg fm-tg-poll.sh 2>&1) || fail "an unconfigured poll must exit 0"
[ -z "$out" ] || fail "an unconfigured poll must print nothing, got: $out"
[ ! -d "$HOME_DIR/state/tg/inbox" ] || fail "an unconfigured poll must not create state"
[ "$(api_calls getUpdates)" = 0 ] || fail "an unconfigured poll must not call Telegram"
pass "inert: no configuration means no output, no state, and no API call"

out=$(tg fm-tg-setup.sh status 2>&1)
case "$out" in *"not configured"*) ;; *) fail "status must report an unconfigured channel, got: $out" ;; esac
pass "inert: status reports an unconfigured channel without touching Telegram"

# =============================================================================
# 2. Setup: the token is never an argument, never printed, never committed
# =============================================================================

out=$(printf '%s\n' "$TOKEN" | tg fm-tg-setup.sh token --owner keychain 2>&1) \
  || fail "storing a valid token must succeed: $out"
case "$out" in *"$TOKEN"*) fail "setup printed the token" ;; esac
case "$out" in *firstmate_test_bot*) ;; *) fail "setup must confirm the bot identity, got: $out" ;; esac
[ "$(config_field .token_owner)" = keychain ] || fail "the token owner must be recorded"
[ "$(config_field .enabled)" = false ] || fail "storing a token must not enable the channel"
grep -rq "$TOKEN" "$HOME_DIR/config" && fail "the token must not be written into the config directory"
[ "$(cat "$KEYSTORE"/firstmate-telegram-bot_firstmate-telegram_* 2>/dev/null)" = "$TOKEN" ] \
  || fail "the token must reach the keychain owner through stdin"
pass "setup: the token is stored through stdin in the keychain owner and never printed"

out=$(printf '%s\n' "not-a-token" | tg fm-tg-setup.sh token --owner keychain 2>&1) && fail "a malformed token must be refused"
case "$out" in *"not-a-token"*) fail "the refusal echoed the rejected secret" ;; esac
pass "setup: a malformed token is refused without echoing what was pasted"

# The channel must refuse to run before pairing, even with a good token.
out=$(tg fm-tg-poll.sh 2>&1)
[ -z "$out" ] || fail "an unpaired channel must stay silent, got: $out"
out=$(tg fm-tg-setup.sh enable 2>&1) && fail "enable must refuse before pairing"
case "$out" in *pair*) ;; *) fail "enable must point at the pairing step, got: $out" ;; esac
pass "setup: a token alone never enables the channel"

# Pair against the one-time private challenge; a group and an unchallenged
# private message in the same batch are ignored.
scenario "$(jq -cn --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:
  ([range(1;26) as $id | {update_id:$id, message:{message_id:$id, date:$id, chat:{id:888, type:"private"}, from:{id:888, is_bot:false}, text:"/start"}}]
  + [{update_id:40, message:{message_id:40, date:40, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false, first_name:"Captain"}, text:"/start PAIRTEST123"}},
     {update_id:41, message:{message_id:41, date:41, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"first real message"}}])}')"
out=$(FM_TG_PAIR_WAIT=1 FM_TG_PAIR_CHALLENGE=PAIRTEST123 tg fm-tg-setup.sh pair 2>&1) || fail "pairing must succeed: $out"
[ "$(config_field .user_id)" = "$USER_ID" ] || fail "pairing must record the exact user id"
[ "$(config_field .chat_id)" = "$CHAT_ID" ] || fail "pairing must record the exact private chat id"
[ "$(config_field .enabled)" = false ] || fail "pairing must not enable the channel"
case "$out" in *"$USER_ID"*) fail "pairing printed the full identity instead of a redacted one" ;; esac
pass "pairing: only the one-time private challenge binds the sender and chat"

# Pairing consumed the challenge, so it never becomes a captain request.
[ "$(cat "$HOME_DIR/state/tg/cursor")" = 40 ] || fail "pairing must commit only through the matched challenge"
pass "pairing: the challenge that paired the channel is consumed, not delivered as a request"

out=$(tg fm-tg-setup.sh enable 2>&1) || fail "enable must succeed after pairing: $out"
[ "$(config_field .enabled)" = true ] || fail "enable must flip the channel on"
[ -f "$HOME_DIR/state/fm-telegram.check.sh" ] || fail "enable must write the watcher check"
[ -f "$HOME_DIR/state/fm-telegram.check-trust" ] || fail "enable must register the watcher check"
[ "$(api_calls deleteWebhook)" -ge 1 ] || fail "enable must clear any webhook so the transport stays pull-only"
grep -q "$TOKEN" "$HOME_DIR/state/fm-telegram.check.sh" && fail "the generated check must not carry the token"
pass "enable: registers a token-free watcher check and clears any webhook"

# Cadence: an enabled channel is polled every 30s, not on the 300s default, and
# the operator is told so - plus told that a supervision cycle already running
# keeps its old cadence until it restarts (docs/configuration.md "Watcher check
# cadence"; bin/fm-cadence.sh owns the file).
[ -f "$HOME_DIR/config/check-cadence.env" ] || fail "enable must arm the 30s check cadence"
grep -q '^export FM_CHECK_INTERVAL=30$' "$HOME_DIR/config/check-cadence.env" \
  || fail "the armed cadence must be 30s"
grep -q "$TOKEN" "$HOME_DIR/config/check-cadence.env" && fail "the cadence file must not carry the token"
case "$out" in *"every 30 seconds"*) ;; *) fail "enable must state the 30-second pickup, got: $out" ;; esac
case "$out" in
  *"applies to the NEXT supervision cycle, not one already running"*) ;;
  *) fail "enable must not imply a running watcher rereads the cadence, got: $out" ;;
esac
# shellcheck source=/dev/null
cadence_interval=$( . "$HOME_DIR/config/check-cadence.env" && bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
[ "$cadence_interval" = 30 ] || fail "sourcing the cadence file must start a watcher at 30s"
# Re-running enable is idempotent and does not re-announce a transition.
cadence_sum=$(shasum < "$HOME_DIR/config/check-cadence.env")
out=$(tg fm-tg-setup.sh enable 2>&1) || fail "re-enable must succeed: $out"
[ "$(shasum < "$HOME_DIR/config/check-cadence.env")" = "$cadence_sum" ] \
  || fail "re-enabling must leave the cadence file byte-identical"
case "$out" in
  *"applies to the NEXT supervision cycle"*) fail "an unchanged cadence must not re-announce a transition: $out" ;;
esac
pass "enable: arms the 30s check cadence idempotently and is honest about the restart it needs"

cadence_body=$(cat "$HOME_DIR/config/check-cadence.env")
tg fm-tg-setup.sh disable >/dev/null || fail "disable before cadence refusal checks must succeed"
cadence_target="$TMP_ROOT/cadence-target"
printf '%s\n' "$cadence_body" > "$cadence_target"
chmod 0600 "$cadence_target"
ln -s "$cadence_target" "$HOME_DIR/config/check-cadence.env"
out=$(tg fm-tg-setup.sh enable 2>&1) || fail "enable should preserve the channel when cadence reconciliation fails: $out"
case "$out" in *"every 30 seconds"*) fail "a symlink refusal left a 30-second pickup promise: $out" ;; esac
case "$out" in *"fast check cadence is not armed"*) ;; *) fail "a symlink refusal did not report the slower pickup: $out" ;; esac
rm -f "$HOME_DIR/config/check-cadence.env" "$cadence_target"
out=$(tg fm-tg-setup.sh enable 2>&1) || fail "enable must repair cadence after symlink removal: $out"
case "$out" in *"every 30 seconds"*) ;; *) fail "repaired cadence did not restore the pickup claim: $out" ;; esac

tg fm-tg-setup.sh disable >/dev/null || fail "disable before hard-link refusal check must succeed"
printf '%s\n' "$cadence_body" > "$cadence_target"
chmod 0600 "$cadence_target"
ln "$cadence_target" "$HOME_DIR/config/check-cadence.env"
out=$(tg fm-tg-setup.sh enable 2>&1) || fail "enable should preserve the channel when hard-link reconciliation fails: $out"
case "$out" in *"every 30 seconds"*) fail "a hard-link refusal left a 30-second pickup promise: $out" ;; esac
rm -f "$HOME_DIR/config/check-cadence.env" "$cadence_target"
out=$(tg fm-tg-setup.sh enable 2>&1) || fail "enable must repair cadence after hard-link removal: $out"
pass "enable reports fast pickup only after a validated cadence reconcile"

out=$(tg fm-tg-poll.sh 2>&1)
[ "$out" = "tg-message 1 pending" ] || fail "the first post-challenge message must remain pollable, got: $out"
[ "$(jq -r .text "$HOME_DIR/state/tg/inbox/tg-41.json")" = "first real message" ] \
  || fail "pairing lost the first real message that shared the challenge batch"
pass "pairing: pages past old updates and preserves later messages from the challenge batch"

# =============================================================================
# 3. Ingress allowlisting - only the exact paired sender in the exact chat
# =============================================================================

reset_ingress() {
  rm -rf "$HOME_DIR/state/tg/inbox" "$HOME_DIR/state/tg/sent" "$HOME_DIR/state/tg/outbox"
  rm -f "$HOME_DIR/state/tg/poll.error" "$HOME_DIR/state/tg/rejects"
  rm -f "$HOME_DIR/state/tg/cursor"
}

msg() {  # <update_id> <extra-message-json>
  jq -cn --argjson id "$1" --argjson extra "$2" --argjson u "$USER_ID" --argjson c "$CHAT_ID" \
    '{update_id:$id, message:({message_id:$id, date:1, chat:{id:$c, type:"private"},
      from:{id:$u, is_bot:false}, text:"hello"} + $extra)}'
}

reset_ingress
scenario "$(jq -cn --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:[
  {update_id:20, message:{message_id:1, date:1, chat:{id:$c, type:"private"}, from:{id:99999, is_bot:false}, text:"impostor"}},
  {update_id:21, message:{message_id:2, date:1, chat:{id:987654, type:"private"}, from:{id:$u, is_bot:false}, text:"wrong chat"}},
  {update_id:22, message:{message_id:3, date:1, chat:{id:-100999, type:"supergroup"}, from:{id:$u, is_bot:false}, text:"group"}},
  {update_id:23, message:{message_id:4, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:true}, text:"bot"}},
  {update_id:24, message:{message_id:5, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"fwd", forward_origin:{type:"user"}}},
  {update_id:25, message:{message_id:6, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"via", via_bot:{id:5}}},
  {update_id:26, message:{message_id:7, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"as channel", sender_chat:{id:-100}}},
  {update_id:27, edited_message:{message_id:8, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"edited"}},
  {update_id:28, channel_post:{message_id:9, date:1, chat:{id:-100, type:"channel"}, text:"post"}},
  {update_id:29, callback_query:{id:"cb", from:{id:$u}, data:"x"}}
]}')"
out=$(tg fm-tg-poll.sh 2>&1)
[ -z "$out" ] || fail "every refused update must leave the poll silent, got: $out"
[ "$(tg fm-tg-inbox.sh pending-count)" = 0 ] || fail "no refused update may become a request"
[ "$(api_calls sendMessage)" = 0 ] || fail "a refused update must never produce an outbound message"
[ "$(cat "$HOME_DIR/state/tg/cursor")" = 29 ] || fail "refused updates must still advance the cursor"
jq -e '.count == 10' "$HOME_DIR/state/tg/rejects" >/dev/null || fail "refusals must be counted"
grep -rq impostor "$HOME_DIR/state" && fail "refused text must never be stored"
pass "ingress: wrong sender, wrong chat, group, bot, forward, via_bot, sender_chat, edit, channel post, and callback are all refused silently"

# =============================================================================
# 4. Accepted messages, replay safety, and adversarial text
# =============================================================================

reset_ingress
# Deliberately literal: this is the exact text a hostile message would carry, and
# it must reach the durable record byte for byte without any of it being expanded.
# shellcheck disable=SC2016 # Nothing here may expand; that is the point of the case.
ADVERSARIAL='hi $(touch '"$TMP_ROOT"'/pwned) `touch '"$TMP_ROOT"'/pwned2` ${IFS}; rm -rf /'
scenario "$(jq -cn --arg t "$ADVERSARIAL" --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:[
  {update_id:30, message:{message_id:1, date:100, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:$t}}
]}')"
out=$(tg fm-tg-poll.sh 2>&1)
[ "$out" = "tg-message 1 pending" ] || fail "an accepted message must print one bounded wake line, got: $out"
[ -f "$TMP_ROOT/pwned" ] && fail "message text was executed"
[ -f "$TMP_ROOT/pwned2" ] && fail "message text was executed"
[ "$(jq -r '.text' "$HOME_DIR/state/tg/inbox/tg-30.json")" = "$ADVERSARIAL" ] \
  || fail "adversarial text must be stored verbatim as data"
[ "$(jq -r '.schema' "$HOME_DIR/state/tg/inbox/tg-30.json")" = fm-telegram-request.v1 ] || fail "wrong record schema"
mode=$(stat -c %a "$HOME_DIR/state/tg/inbox/tg-30.json" 2>/dev/null || stat -f %Lp "$HOME_DIR/state/tg/inbox/tg-30.json")
[ "$mode" = 600 ] || fail "an inbound record must be mode 0600, got $mode"
pass "ingress: shell-metacharacter text is stored as data, never executed, in a mode-0600 record"

# A replayed update id (Telegram re-delivers when the cursor never advanced)
# must not create a second request.
rm -f "$HOME_DIR/state/tg/cursor"
out=$(tg fm-tg-poll.sh 2>&1)
[ "$(tg fm-tg-inbox.sh pending-count)" = 1 ] || fail "a replayed update must not duplicate the request"
[ "$out" = "tg-message 1 pending" ] || fail "a replay must still report the still-pending message, got: $out"
pass "replay: re-delivering the same update id leaves exactly one durable request"

# Crash between commit and cursor advance: the record survives, the cursor is
# behind, and the next poll converges without duplicating.
[ "$(cat "$HOME_DIR/state/tg/cursor")" = 30 ] || fail "the cursor must advance past a committed update"
out=$(tg fm-tg-poll.sh 2>&1)
[ "$(tg fm-tg-inbox.sh pending-count)" = 1 ] || fail "converged polls must not duplicate"
pass "crash safety: commit-then-advance ordering converges on exactly one request"

# Mixed batch, out of order, with a bad and an oversized entry.
reset_ingress
LONG=$(head -c 5000 < /dev/zero | tr '\0' 'x')
scenario "$(jq -cn --arg long "$LONG" --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:[
  {update_id:43, message:{message_id:3, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"third"}},
  {update_id:41, message:{message_id:1, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"first"}},
  {update_id:42, message:{message_id:2, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, photo:[{file_id:"x"}]}},
  {update_id:44, message:{message_id:4, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:$long}},
  {update_id:45, message:{message_id:5, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"   "}},
  {message:{message_id:6, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"no update id"}},
  "not an object"
]}')"
out=$(tg fm-tg-poll.sh 2>&1)
[ "$out" = "tg-message 5 pending" ] || fail "the mixed batch must yield five records, got: $out"
[ "$(jq -r .kind "$HOME_DIR/state/tg/inbox/tg-42.json")" = unsupported ] || fail "a photo must be recorded as unsupported"
[ "$(jq -r .kind "$HOME_DIR/state/tg/inbox/tg-44.json")" = oversized ] || fail "an over-long message must be recorded as oversized"
[ "$(jq -r .text "$HOME_DIR/state/tg/inbox/tg-44.json")" = "" ] || fail "an oversized message must not be stored"
[ "$(jq -r .kind "$HOME_DIR/state/tg/inbox/tg-45.json")" = unsupported ] || fail "a whitespace-only message must be unsupported"
[ "$(cat "$HOME_DIR/state/tg/cursor")" = 45 ] || fail "the cursor must end at the highest processed update"
pass "ingress: an out-of-order batch with media, oversize, blank, id-less, and non-object entries is handled in order and bounded"

listing=$(tg fm-tg-inbox.sh list)
case "$listing" in *"tg-41"*"tg-45"*) ;; *) fail "list must show pending records in update order, got: $listing" ;; esac
claimed=$(tg fm-tg-inbox.sh claim)
case "$claimed" in *"delivered: 5"*) ;; *) fail "claim must deliver every pending record, got: $claimed" ;; esac
[ "$(tg fm-tg-inbox.sh pending-count)" = 0 ] || fail "claim must drain the inbox"
[ -f "$HOME_DIR/state/tg/inbox/archive/tg-41.json" ] || fail "claim must archive rather than delete"
pass "inbox: claim delivers before archiving, so an interruption re-surfaces instead of losing a message"

reset_ingress
mkdir -p "$HOME_DIR/state/tg/inbox/archive" "$HOME_DIR/state/tg/sent"
printf '{"schema":"fm-telegram-request.v1","request_id":"tg-99","received_at":1,"kind":"message","text":"oldest"}\n' \
  > "$HOME_DIR/state/tg/inbox/archive/tg-99.json"
printf '{"schema":"fm-telegram-sent.v1","key":"tg-99","status":"sent"}\n' \
  > "$HOME_DIR/state/tg/sent/tg-99.json"
chmod 600 "$HOME_DIR/state/tg/inbox/archive/tg-99.json" "$HOME_DIR/state/tg/sent/tg-99.json"
for id in $(seq 100 148); do
  printf '{"schema":"fm-telegram-request.v1","request_id":"tg-%s","received_at":%s,"kind":"message","text":"newer"}\n' "$id" "$id" \
    > "$HOME_DIR/state/tg/inbox/archive/tg-$id.json"
  printf '{"schema":"fm-telegram-sent.v1","key":"tg-%s","status":"sent"}\n' "$id" \
    > "$HOME_DIR/state/tg/sent/tg-$id.json"
  chmod 600 "$HOME_DIR/state/tg/inbox/archive/tg-$id.json" "$HOME_DIR/state/tg/sent/tg-$id.json"
done
printf '{"schema":"fm-telegram-request.v1","request_id":"tg-200","received_at":200,"kind":"message","text":"newest"}\n' \
  > "$HOME_DIR/state/tg/inbox/tg-200.json"
chmod 600 "$HOME_DIR/state/tg/inbox/tg-200.json"
tg fm-tg-inbox.sh claim >/dev/null || fail "claiming into a full answered archive must succeed"
[ ! -f "$HOME_DIR/state/tg/inbox/archive/tg-99.json" ] || fail "archive retention kept the oldest answered request"
[ -f "$HOME_DIR/state/tg/inbox/archive/tg-100.json" ] || fail "archive retention pruned by filename instead of received time"
[ -f "$HOME_DIR/state/tg/inbox/archive/tg-200.json" ] || fail "archive retention did not keep the newly claimed request"
[ "$(find "$HOME_DIR/state/tg/inbox/archive" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')" = 50 ] \
  || fail "claimed-request archive exceeded its fixed bound"
pass "state: claimed requests retain the newest 50 records by received time"

reset_ingress
mkdir -p "$HOME_DIR/state/tg/inbox"
for id in $(seq 1000 1098); do
  printf '{"schema":"fm-telegram-request.v1","request_id":"tg-%s"}\n' "$id" \
    > "$HOME_DIR/state/tg/inbox/tg-$id.json"
  chmod 600 "$HOME_DIR/state/tg/inbox/tg-$id.json"
done
scenario "$(jq -cn --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:[
  {update_id:2000, message:{message_id:1, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"last local slot"}},
  {update_id:2001, message:{message_id:2, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"must remain at Telegram"}}
]}')"
out=$(tg fm-tg-poll.sh 2>&1)
[ "$out" = "tg-message 100 pending" ] || fail "the inbox must stop exactly at its fixed bound, got: $out"
[ "$(cat "$HOME_DIR/state/tg/cursor")" = 2000 ] || fail "the cursor advanced beyond available inbox capacity"
before=$(api_calls getUpdates)
tg fm-tg-poll.sh >/dev/null || fail "a full inbox poll must remain a safe no-op"
[ "$(api_calls getUpdates)" = "$before" ] || fail "a full inbox must apply backpressure before contacting Telegram"
[ "$(tg fm-tg-inbox.sh pending-count)" = 100 ] || fail "pending inbox state exceeded its fixed bound"
pass "state: pending ingress applies backpressure at 100 without advancing the cursor"

reset_ingress
mkdir -p "$HOME_DIR/state/tg/sent"
for id in $(seq -w 1 199); do
  printf '{"schema":"fm-telegram-sent.v1","key":"event-ingress-%s","status":"sent"}\n' "$id" \
    > "$HOME_DIR/state/tg/sent/event-ingress-$id.json"
  chmod 600 "$HOME_DIR/state/tg/sent/event-ingress-$id.json"
done
scenario "$(jq -cn --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:[
  {update_id:3000, message:{message_id:1, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"reply slot 200"}},
  {update_id:3001, message:{message_id:2, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"must stay remote"}}
]}')"
out=$(tg fm-tg-poll.sh 2>&1)
[ "$out" = "tg-message 1 pending" ] || fail "ingress must reserve only the final available reply slot, got: $out"
[ "$(cat "$HOME_DIR/state/tg/cursor")" = 3000 ] || fail "ingress advanced beyond available reply capacity"
before=$(api_calls getUpdates)
tg fm-tg-poll.sh >/dev/null || fail "reply-capacity backpressure must remain a safe no-op"
[ "$(api_calls getUpdates)" = "$before" ] || fail "exhausted reply capacity still contacted Telegram"
tg fm-tg-inbox.sh claim >/dev/null || fail "the reserved request must remain claimable"
printf 'reserved reply\n' > "$TMP_ROOT/ingress-reply.txt"
tg fm-tg-reply.sh tg-3000 --text-file "$TMP_ROOT/ingress-reply.txt" >/dev/null \
  || fail "an accepted request must be able to consume its reserved reply slot"
[ "$(find "$HOME_DIR/state/tg/sent" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')" = 200 ] \
  || fail "replying to the reserved ingress request exceeded the ledger bound"
pass "state: ingress reserves reply capacity before accepting captain messages"

# =============================================================================
# 5. Transport failures stop safely and never fall back
# =============================================================================

reset_ingress
scenario '{"getUpdates_status":401}'
out=$(tg fm-tg-poll.sh 2>&1)
case "$out" in "tg-mode-error "*) ;; *) fail "an auth failure must surface once, got: $out" ;; esac
case "$out" in *"$TOKEN"*) fail "the auth diagnostic leaked the token" ;; esac
repeat=$(tg fm-tg-poll.sh 2>&1)
[ -z "$repeat" ] || fail "the same failure must not wake firstmate again, got: $repeat"
pass "failure: an auth failure surfaces exactly once and is deduplicated until it clears"

scenario '{"getUpdates_status":409}'
out=$(tg fm-tg-poll.sh 2>&1)
case "$out" in *"webhook"*) ;; *) fail "a 409 must name the conflicting-consumer cause, got: $out" ;; esac
pass "failure: a competing consumer or leftover webhook is reported in plain terms"

scenario '{"getUpdates_malformed":true}'
rm -f "$HOME_DIR/state/tg/poll.error"
out=$(tg fm-tg-poll.sh 2>&1)
case "$out" in "tg-mode-error "*unreadable*) ;; *) fail "a malformed body must be refused, got: $out" ;; esac
[ "$(tg fm-tg-inbox.sh pending-count)" = 0 ] || fail "a malformed body must not create records"
pass "failure: an unreadable API response is refused without creating records"

rm -f "$HOME_DIR/state/tg/poll.error"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TG_API_BASE="http://127.0.0.1:1" \
  FM_TG_TEST_KEYSTORE="$KEYSTORE" "$ROOT/bin/fm-tg-poll.sh" 2>&1)
case "$out" in "tg-mode-error "*) ;; *) fail "an unreachable API must surface once, got: $out" ;; esac
case "$out" in *127.0.0.1*|*"$TOKEN"*) fail "the network diagnostic leaked transport detail" ;; esac
pass "failure: an unreachable API reports a plain cause and leaks no URL or token"

: > "$CURL_LOG"
scenario '{}'
FM_TG_HTTP_TIMEOUT=0 tg fm-tg-poll.sh >/dev/null || fail "a zero HTTP timeout must be clamped"
grep -q -- '-m 20' "$CURL_LOG" || fail "a zero HTTP timeout must reset to the bounded default"
FM_TG_HTTP_TIMEOUT=999 tg fm-tg-poll.sh >/dev/null || fail "an oversized HTTP timeout must be clamped"
grep -q -- '-m 20' "$CURL_LOG" || fail "an oversized HTTP timeout must reset to the bounded default"
pass "transport: Bot API calls clamp zero and oversized HTTP timeouts"

# =============================================================================
# 6. Outbound: chunking, at-most-once, and ambiguous delivery
# =============================================================================

scenario '{}'
reset_ingress
: > "$API_LOG"

printf 'Captain, the sign-in fix is ready for review.\nhttps://github.com/example/repo/pull/12\n' > "$TMP_ROOT/reply.txt"
tg fm-tg-reply.sh tg-30 --text-file "$TMP_ROOT/reply.txt" >/dev/null || fail "a first reply must send"
[ "$(api_calls sendMessage)" = 1 ] || fail "a short reply must be exactly one message"
body=$(grep '"sendMessage"' "$API_LOG" | tail -1 | jq -r .body)
printf '%s' "$body" | jq -e '.parse_mode == null' >/dev/null || fail "no parse_mode may ever be sent"
printf '%s' "$body" | jq -e --argjson c "$CHAT_ID" '.chat_id == $c' >/dev/null || fail "the reply must target the paired chat"
pass "outbound: a short reply is one plain-text message to the paired chat with no parse_mode"

out=$(tg fm-tg-reply.sh tg-30 --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 3 ] || fail "a second reply for the same request must be refused (exit 3), got $rc"
[ "$(api_calls sendMessage)" = 1 ] || fail "the refused retry must not send anything"
pass "outbound: at most one reply per request id, however many times it is retried"

# Markup-looking characters survive literally and are never escaped or split
# into unbalanced markup, because no parse_mode is in play.
# shellcheck disable=SC2016 # Literal markup characters are the subject of this case.
printf 'balance *bold _italic `code` [link](x) <b>tag</b>\n' > "$TMP_ROOT/markup.txt"
tg fm-tg-reply.sh --event markup-check --text-file "$TMP_ROOT/markup.txt" >/dev/null || fail "the markup reply must send"
sent=$(grep '"sendMessage"' "$API_LOG" | tail -1 | jq -r '.body | fromjson | .text')
# shellcheck disable=SC2016 # Literal markup characters are the subject of this case.
[ "$sent" = 'balance *bold _italic `code` [link](x) <b>tag</b>' ] || fail "markup characters must pass literally, got: $sent"
pass "outbound: markup characters are delivered literally, so no chunk boundary can break markup"

# Long replies split within the per-message limit and stop at the chunk cap.
: > "$API_LOG"
python3 - "$TMP_ROOT/long.txt" <<'PY'
import sys
paras = ["word " * 120 for _ in range(40)]
open(sys.argv[1], "w").write("\n\n".join(paras))
PY
out=$(FM_TG_REPLY_MAX_CHARS=500 FM_TG_REPLY_MAX_CHUNKS=3 \
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TG_API_BASE="$API_BASE" \
  FM_TG_TEST_KEYSTORE="$KEYSTORE" "$ROOT/bin/fm-tg-reply.sh" --event long-check --text-file "$TMP_ROOT/long.txt" 2>&1) \
  || fail "the long reply must send: $out"
n=$(api_calls sendMessage)
[ "$n" = 3 ] || fail "the chunk cap must bound the thread to 3 messages, got $n"
while IFS= read -r line; do
  len=$(printf '%s' "$line" | jq -r '.body | fromjson | .text' | wc -m | tr -d ' ')
  [ "$len" -le 501 ] || fail "a chunk exceeded the per-message limit ($len)"
done < <(grep '"sendMessage"' "$API_LOG")
last=$(grep '"sendMessage"' "$API_LOG" | tail -1 | jq -r '.body | fromjson | .text')
case "$last" in *…) ;; *) fail "a truncated thread must mark its last message" ;; esac
pass "outbound: a long reply splits within the per-message limit, caps its thread, and marks truncation"

: > "$API_LOG"
python3 - "$TMP_ROOT/emoji.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("😀" * 250)
PY
FM_TG_REPLY_MAX_CHARS=200 tg fm-tg-reply.sh --event emoji-check --text-file "$TMP_ROOT/emoji.txt" >/dev/null \
  || fail "an emoji-heavy reply must send"
while IFS= read -r line; do
  units=$(printf '%s' "$line" | jq -r '.body | fromjson | .text' \
    | python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n").encode("utf-16-le")) // 2)')
  [ "$units" -le 200 ] || fail "an emoji chunk exceeded the UTF-16 limit ($units)"
done < <(grep '"sendMessage"' "$API_LOG")
pass "outbound: emoji-heavy replies are split by Telegram UTF-16 units"

: > "$API_LOG"
python3 - "$TMP_ROOT/lines.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("\n".join(f"line {i:02d} keeps formatting" for i in range(30)))
PY
FM_TG_REPLY_MAX_CHARS=200 tg fm-tg-reply.sh --event lines-check --text-file "$TMP_ROOT/lines.txt" >/dev/null \
  || fail "a multiline reply must send"
joined=$(grep '"sendMessage"' "$API_LOG" | jq -r '.body | fromjson | .text')
expected=$(cat "$TMP_ROOT/lines.txt")
[ "$joined" = "$expected" ] || fail "splitting an over-limit paragraph discarded single line breaks"
pass "outbound: long multiline replies preserve their single line breaks"

# A definite refusal frees the key for a retry; an ambiguous outcome does not.
scenario '{"sendMessage_status":400}'
out=$(tg fm-tg-reply.sh --event refused-check --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 5 ] || fail "a definite refusal must exit 5, got $rc"
[ ! -f "$HOME_DIR/state/tg/sent/event-refused-check.json" ] || fail "a definite refusal must free the key for a retry"
scenario '{}'
tg fm-tg-reply.sh --event refused-check --text-file "$TMP_ROOT/reply.txt" >/dev/null \
  || fail "the freed key must be retryable"
pass "outbound: a definite refusal sends nothing and leaves the message retryable"

scenario '{"sendMessage_status":500}'
out=$(tg fm-tg-reply.sh --event ambiguous-check --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 4 ] || fail "a server error must be treated as ambiguous (exit 4), got $rc"
[ "$(jq -r .status "$HOME_DIR/state/tg/sent/event-ambiguous-check.json")" = ambiguous ] \
  || fail "an ambiguous delivery must be recorded as ambiguous"
scenario '{}'
out=$(tg fm-tg-reply.sh --event ambiguous-check --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 4 ] || fail "an ambiguous key must stay refused without --resend, got $rc"
tg fm-tg-reply.sh --event ambiguous-check --resend --text-file "$TMP_ROOT/reply.txt" >/dev/null \
  || fail "--resend must be the explicit way past an ambiguous delivery"
pass "outbound: an ambiguous delivery is never silently retried and never falls back to another channel"

scenario '{}'
out=$(FM_TG_TEST_CURL_RC=56 tg fm-tg-reply.sh --event reset-check --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 4 ] || fail "a post-connect reset must be ambiguous, got $rc"
[ "$(jq -r .status "$HOME_DIR/state/tg/sent/event-reset-check.json")" = ambiguous ] \
  || fail "a post-connect reset must retain an ambiguous claim"
out=$(tg fm-tg-reply.sh --event reset-check --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 4 ] || fail "a post-connect reset must block automatic retry, got $rc"
tg fm-tg-reply.sh --event reset-check --resend --text-file "$TMP_ROOT/reply.txt" >/dev/null \
  || fail "an explicit resend must clear a post-connect reset hold"

out=$(FM_TG_TEST_CURL_RC=7 tg fm-tg-reply.sh --event connect-check --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 5 ] || fail "a definite connection refusal must stay retryable, got $rc"
[ ! -f "$HOME_DIR/state/tg/sent/event-connect-check.json" ] \
  || fail "a definite connection refusal must free its claim"
tg fm-tg-reply.sh --event connect-check --text-file "$TMP_ROOT/reply.txt" >/dev/null \
  || fail "a definite connection refusal must permit an ordinary retry"
pass "outbound: post-request network loss stops while pre-connect failure remains retryable"

# Nothing is sent, and no key is consumed, when the channel is off.
tg fm-tg-setup.sh disable >/dev/null || fail "disable must succeed"
before=$(api_calls sendMessage)
out=$(tg fm-tg-reply.sh --event while-disabled --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "a disabled channel must refuse to send, got $rc"
[ "$(api_calls sendMessage)" = "$before" ] || fail "a disabled channel sent a message"
[ ! -f "$HOME_DIR/state/fm-telegram.check.sh" ] || fail "disable must remove the watcher check"
[ ! -f "$HOME_DIR/state/fm-telegram.check-trust" ] || fail "disable must remove the watcher registration"
out=$(tg fm-tg-poll.sh 2>&1)
[ -z "$out" ] || fail "a disabled channel must stop polling, got: $out"
[ ! -f "$HOME_DIR/config/check-cadence.env" ] \
  || fail "disable must release the 30s check cadence with no other channel armed"
pass "disable: polling stops, the check is unregistered, the cadence is released, and nothing can be sent"

# X mode armed alongside Telegram: disabling Telegram must NOT drop the shared
# cadence, because the relay poll still needs it.
tg fm-tg-setup.sh enable >/dev/null || fail "re-enable must succeed"
: > "$HOME_DIR/state/x-watch.check.sh"
tg fm-tg-setup.sh disable >/dev/null || fail "disable must succeed with X mode armed"
[ -f "$HOME_DIR/config/check-cadence.env" ] \
  || fail "disabling Telegram must not release a cadence X mode still needs"
rm -f "$HOME_DIR/state/x-watch.check.sh"
pass "disable: the shared cadence survives while another captain channel is still armed"

tg fm-tg-setup.sh enable >/dev/null || fail "re-enable must succeed"

# A message that starts real work keeps one durable identity: the task carries
# the conversation, so a later session reports the outcome to the same chat.
scenario '{}'
: > "$API_LOG"
printf 'window=fm-work-x1\nkind=ship\nproject=alpha\npr=https://github.com/example/repo/pull/12\n' > "$HOME_DIR/state/work-x1.meta"
tg fm-tg-link.sh work-x1 tg-30 >/dev/null || fail "linking a task to its message must succeed"
[ "$(tg fm-tg-link.sh --check work-x1)" = "tg-30 0" ] || fail "--check must report the link and its spent budget"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tg-lib.sh"
fm_pr_metadata_identity_parse "$HOME_DIR/state/work-x1.meta" \
  || fail "a Telegram link appended after pr= must preserve PR metadata validity"

printf 'Captain, the investigation is done and a build is under way.\n' > "$TMP_ROOT/u1.txt"
tg fm-tg-reply.sh --task work-x1 --text-file "$TMP_ROOT/u1.txt" >/dev/null || fail "a linked update must send"
[ "$(api_calls sendMessage)" = 1 ] || fail "a linked update must be one message"
[ "$(tg fm-tg-link.sh --check work-x1)" = "tg-30 1" ] || fail "a delivered update must be counted"
fm_pr_metadata_identity_parse "$HOME_DIR/state/work-x1.meta" \
  || fail "a Telegram update rewrite must preserve PR metadata validity"

# Retrying the same update is refused; a genuinely new milestone is not.
out=$(tg fm-tg-reply.sh --task work-x1 --text-file "$TMP_ROOT/u1.txt" 2>&1); rc=$?
[ "$rc" = 0 ] || fail "a new milestone must be allowed, got $rc"
[ "$(api_calls sendMessage)" = 2 ] || fail "the second milestone must send"
out=$(FM_TG_TASK_UPDATE_MAX=2 tg fm-tg-reply.sh --task work-x1 --text-file "$TMP_ROOT/u1.txt" 2>&1); rc=$?
[ "$rc" = 3 ] || fail "a spent update budget must refuse a further update, got $rc"
[ "$(api_calls sendMessage)" = 2 ] || fail "a refused update must send nothing"
pass "linked work: updates are counted, keyed distinctly, and bounded by their budget"

# A terminal outcome is never rationed, and it closes the conversation.
printf 'Captain, that one is shipped.\n' > "$TMP_ROOT/final.txt"
FM_TG_TASK_UPDATE_MAX=2 tg fm-tg-reply.sh --task work-x1 --final --text-file "$TMP_ROOT/final.txt" >/dev/null \
  || fail "a final outcome must send even past the update budget"
[ "$(api_calls sendMessage)" = 3 ] || fail "the final outcome must send"
[ -z "$(tg fm-tg-link.sh --check work-x1)" ] || fail "a final outcome must clear the link"
grep -q '^tg_request=' "$HOME_DIR/state/work-x1.meta" && fail "a final outcome must drop the link from the task record"
fm_pr_metadata_identity_parse "$HOME_DIR/state/work-x1.meta" \
  || fail "clearing a Telegram link must preserve PR metadata validity"
out=$(tg fm-tg-reply.sh --task work-x1 --text-file "$TMP_ROOT/u1.txt" 2>&1); rc=$?
[ "$rc" = 3 ] || fail "an unlinked task must refuse to send, got $rc"
pass "linked work: the terminal outcome always lands and then closes the conversation"

rm -f "$HOME_DIR/state/work-x1.meta"

printf 'window=fm-work-limit\nkind=ship\nproject=alpha\n' > "$HOME_DIR/state/work-limit.meta"
tg fm-tg-link.sh work-limit tg-31 >/dev/null || fail "the update-limit task must link"
fm_tg_meta_link_set "$HOME_DIR/state/work-limit.meta" tg-31 "$(date +%s)" 998 \
  || fail "the largest supported update count must remain representable"
[ -z "$(FM_TG_TASK_UPDATE_MAX=9999 tg fm-tg-link.sh --check work-limit)" ] \
  || fail "an oversized task update maximum must clamp before key overflow"
FM_TG_TASK_UPDATE_MAX=9999 tg fm-tg-reply.sh --task work-limit --final --text-file "$TMP_ROOT/final.txt" >/dev/null \
  || fail "the final reply must use the remaining .u999 key after the clamped update budget"
[ -f "$HOME_DIR/state/tg/sent/tg-31.u999.json" ] || fail "the bounded final ledger key was not recorded"
rm -f "$HOME_DIR/state/work-limit.meta"
pass "linked work: update limits clamp within the final ledger key space"

rm -rf "$HOME_DIR/state/tg/sent"
mkdir -p "$HOME_DIR/state/tg/sent"
for id in $(seq -w 1 199); do
  printf '{"schema":"fm-telegram-sent.v1","key":"event-cap-%s","status":"sent"}\n' "$id" \
    > "$HOME_DIR/state/tg/sent/event-cap-$id.json"
  chmod 600 "$HOME_DIR/state/tg/sent/event-cap-$id.json"
done
printf 'window=fm-work-reserved\nkind=ship\nproject=alpha\n' > "$HOME_DIR/state/work-reserved.meta"
tg fm-tg-link.sh work-reserved tg-32 >/dev/null || fail "one final slot must be reservable at ledger capacity"
out=$(tg fm-tg-reply.sh --event over-cap --text-file "$TMP_ROOT/reply.txt" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "an ordinary send must backpressure once all ledger slots are occupied or reserved"
tg fm-tg-reply.sh --task work-reserved --final --text-file "$TMP_ROOT/final.txt" >/dev/null \
  || fail "a linked final outcome must consume its reserved slot at ledger capacity"
[ "$(find "$HOME_DIR/state/tg/sent" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')" = 200 ] \
  || fail "the sent ledger exceeded its fixed bound"
rm -f "$HOME_DIR/state/work-reserved.meta"
rm -rf "$HOME_DIR/state/tg/sent" "$HOME_DIR/state/tg/outbox"
pass "state: sent claims and final reservations stay bounded without pruning at-most-once records"

# Dry run: firstmate can compose and record without anything reaching Telegram.
before=$(api_calls sendMessage)
printf 'a preview that must never leave the machine\n' > "$TMP_ROOT/dry.txt"
FM_TG_DRY_RUN=1 tg fm-tg-reply.sh --event dry-check --text-file "$TMP_ROOT/dry.txt" >/dev/null \
  || fail "a dry run must succeed"
[ "$(api_calls sendMessage)" = "$before" ] || fail "a dry run sent a real message"
[ -f "$HOME_DIR/state/tg/outbox/event-dry-check.json" ] || fail "a dry run must record what it would have sent"
pass "outbound: a dry run records the would-be message and sends nothing"

rm -rf "$HOME_DIR/state/tg/outbox"
mkdir -p "$HOME_DIR/state/tg/outbox"
printf '{"schema":"fm-telegram-outbox.v1","key":"event-zold","recorded_at":1}\n' \
  > "$HOME_DIR/state/tg/outbox/event-zold.json"
chmod 600 "$HOME_DIR/state/tg/outbox/event-zold.json"
for id in $(seq 2 50); do
  printf '{"schema":"fm-telegram-outbox.v1","key":"event-mid%s","recorded_at":%s}\n' "$id" "$id" \
    > "$HOME_DIR/state/tg/outbox/event-mid$id.json"
  chmod 600 "$HOME_DIR/state/tg/outbox/event-mid$id.json"
done
FM_TG_DRY_RUN=1 tg fm-tg-reply.sh --event anew --text-file "$TMP_ROOT/dry.txt" >/dev/null \
  || fail "a dry run at preview retention capacity must succeed"
[ "$(find "$HOME_DIR/state/tg/outbox" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')" = 50 ] \
  || fail "dry-run preview retention exceeded 50 records"
[ -f "$HOME_DIR/state/tg/outbox/event-anew.json" ] || fail "preview pruning removed the newly recorded dry run"
[ ! -f "$HOME_DIR/state/tg/outbox/event-zold.json" ] || fail "preview pruning kept an older lexicographically greater slug"
pass "state: dry-run previews retain the newest 50 records by recorded time"

# The weaker file-token owner still works end to end and stays mode 0600.
out=$(printf '%s\n' "$TOKEN" | FM_TG_TEST_SECURITY_DELETE_FAIL=1 tg fm-tg-setup.sh token --owner file 2>&1); rc=$?
[ "$rc" != 0 ] || fail "an owner switch must fail when the previous credential cannot be removed"
[ "$(config_field .token_owner)" = keychain ] || fail "a failed owner switch changed the configured owner"
[ ! -f "$HOME_DIR/config/telegram-token" ] || fail "a failed owner switch left the new fallback credential behind"
[ -n "$(ls -A "$KEYSTORE" 2>/dev/null)" ] || fail "a failed owner switch lost the still-configured keychain credential"
out=$(printf '%s\n' "$TOKEN" | tg fm-tg-setup.sh token --owner file 2>&1) \
  || fail "the file token owner must work: $out"
[ -z "$(ls -A "$KEYSTORE" 2>/dev/null)" ] || fail "switching to file ownership must remove the old keychain token"
mode=$(stat -c %a "$HOME_DIR/config/telegram-token" 2>/dev/null || stat -f %Lp "$HOME_DIR/config/telegram-token")
[ "$mode" = 600 ] || fail "the fallback token file must be mode 0600, got $mode"
grep -q '^config/telegram-token$' "$ROOT/.gitignore" || fail "the fallback token file must be gitignored"
grep -q '^config/telegram\.json$' "$ROOT/.gitignore" || fail "the channel configuration must be gitignored"
tg fm-tg-setup.sh enable >/dev/null || fail "enable must work with the file token owner"
tg fm-tg-reply.sh --event file-owner-check --text-file "$TMP_ROOT/reply.txt" >/dev/null \
  || fail "sending must work with the file token owner"
pass "secret: the documented weaker file owner works end to end at mode 0600 and is gitignored"

# Back to the keychain owner for the remaining proofs.
printf '%s\n' "$TOKEN" | tg fm-tg-setup.sh token --owner keychain >/dev/null || fail "restoring the keychain owner must work"
[ ! -f "$HOME_DIR/config/telegram-token" ] || fail "switching to keychain ownership must remove the old token file"
tg fm-tg-setup.sh enable >/dev/null || fail "re-enable must succeed"

# =============================================================================
# 7. The token never reaches a process argument
# =============================================================================

if grep -q -- "$TOKEN" "$CURL_LOG"; then
  fail "the bot token appeared in a curl argument vector"
fi
[ -s "$CURL_LOG" ] || fail "the curl shim recorded nothing, so this proof is vacuous"
grep -q -- '-K ' "$CURL_LOG" || fail "requests must pass their URL through a curl config file"
pass "secret: across every API call this suite made, the token never entered a process argument"

for f in "$HOME_DIR/state"/*.check.sh "$HOME_DIR/state"/tg "$HOME_DIR/config"/*; do
  [ -e "$f" ] || continue
  grep -rq -- "$TOKEN" "$f" && fail "the token leaked into $f"
done
grep -rq -- "$TOKEN" "$API_LOG" || fail "the fake API never saw the token, so the transport proof is vacuous"
pass "secret: the token reaches only the Bot API, never a check script, state record, or config file"

status=$(tg fm-tg-setup.sh status 2>&1)
case "$status" in *"$TOKEN"*) fail "status printed the token" ;; esac
case "$status" in *"$USER_ID"*) fail "status printed the full captain identity" ;; esac
case "$status" in *"stored in the keychain owner"*) ;; *) fail "status must confirm the token is held, got: $status" ;; esac
pass "secret: status confirms the token without revealing it or the full paired identity"

# A configured API base that could break out of the curl config file is refused
# before any request is built, rather than changing what the config file means.
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TG_TEST_KEYSTORE="$KEYSTORE" \
  FM_TG_API_BASE='http://127.0.0.1/"
url = "http://evil.invalid/' "$ROOT/bin/fm-tg-poll.sh" 2>&1)
case "$out" in "tg-mode-error "*misconfigured*) ;; *) fail "a quote-bearing API base must be refused as a local misconfiguration, got: $out" ;; esac
grep -q 'evil.invalid' "$CURL_LOG" && fail "a quote-bearing API base reached curl"
pass "transport: a base that could break out of the request config file is refused, not interpolated"

# =============================================================================
# 8. No listening socket, no webhook, one outbound owner
# =============================================================================

for s in fm-tg-lib.sh fm-tg-poll.sh fm-tg-reply.sh fm-tg-inbox.sh fm-tg-setup.sh fm-tg-link.sh; do
  if grep -Eq 'setWebhook|nc -l|--listen|createServer|socat|LISTEN' "$ROOT/bin/$s"; then
    fail "$s must not register a webhook or open a listening socket"
  fi
done
senders=$(grep -rl 'sendMessage' "$ROOT/bin" | grep -v fm-tg-lib.sh || true)
[ "$senders" = "$ROOT/bin/fm-tg-reply.sh" ] || fail "exactly one script may send to Telegram, found: $senders"
callers=$(grep -rl 'api\.telegram\.org\|fm_tg_api ' "$ROOT/bin" | LC_ALL=C sort | tr '\n' ' ')
case "$callers" in
  *fm-tg-lib.sh*fm-tg-poll.sh*fm-tg-reply.sh*fm-tg-setup.sh*) ;;
  *) fail "unexpected Telegram transport caller set: $callers" ;;
esac
pass "boundary: no webhook, no listening socket, and a single outbound owner"

# Ordinary internal firstmate machinery must not be able to reach Telegram.
if grep -rl 'fm-tg-reply\.sh' "$ROOT/bin" | grep -v 'fm-tg-' | grep -q .; then
  fail "no general firstmate script may push to Telegram; only firstmate itself decides to reply"
fi
pass "boundary: no watcher, status, or lifecycle script can push internal progress to Telegram"

# =============================================================================
# 9. The registered watcher check is what actually wakes firstmate
# =============================================================================

reset_ingress
scenario "$(jq -cn --argjson u "$USER_ID" --argjson c "$CHAT_ID" '{updates:[
  {update_id:60, message:{message_id:1, date:1, chat:{id:$c, type:"private"}, from:{id:$u, is_bot:false}, text:"how are we doing?"}}
]}')"
out=$(PATH="$FAKEBIN:$PATH" FM_TG_API_BASE="$API_BASE" FM_TG_TEST_KEYSTORE="$KEYSTORE" \
  "$HOME_DIR/state/fm-telegram.check.sh" 2>&1)
[ "$out" = "tg-message 1 pending" ] || fail "the registered check must print one wake line, got: $out"
lines=$(printf '%s\n' "$out" | grep -c .)
[ "$lines" = 1 ] || fail "the check must print exactly one line, got $lines"
pass "watcher: the registered check produces exactly one bounded wake line"

# Sourced for the registration predicate the watcher itself uses. Static source
# following stays off here so a test never re-imports a production source graph.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"
fm_custom_check_registered "$HOME_DIR/state" fm-telegram \
  || fail "the check must pass the watcher's registration check"
printf '#!/bin/sh\necho tampered\n' > "$HOME_DIR/state/fm-telegram.check.sh"
if fm_custom_check_registered "$HOME_DIR/state" fm-telegram; then
  fail "a tampered check must lose its registration"
fi
pass "watcher: the check is byte-bound, so a tampered check is refused rather than executed"

tg fm-tg-setup.sh enable >/dev/null || fail "re-enable must restore the check"

# =============================================================================
# 10. Supervision and removal
# =============================================================================

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"
fm_supervision_needed "$HOME_DIR/state" 300 \
  || fail "an enabled Telegram channel must count as a supervision need with no fleet work"
pass "supervision: a Telegram-only home keeps one live supervision cycle"

pending_before=$(tg fm-tg-inbox.sh pending-count)
printf '%s\n' "$TOKEN" > "$HOME_DIR/config/telegram-token"
chmod 600 "$HOME_DIR/config/telegram-token"
out=$(FM_TG_TEST_SECURITY_DELETE_FAIL=1 tg fm-tg-setup.sh uninstall 2>&1); rc=$?
[ "$rc" != 0 ] || fail "uninstall must fail when a token owner cannot be confirmed empty"
[ -f "$HOME_DIR/config/telegram.json" ] || fail "a failed uninstall removed the configuration needed to retry cleanup"
[ -n "$(ls -A "$KEYSTORE" 2>/dev/null)" ] || fail "the failed uninstall silently lost the keychain failure evidence"
case "$out" in *"could not be confirmed empty"*) ;; *) fail "failed uninstall did not report incomplete credential cleanup: $out" ;; esac
out=$(tg fm-tg-setup.sh uninstall 2>&1) || fail "uninstall must succeed: $out"
[ ! -f "$HOME_DIR/config/telegram.json" ] || fail "uninstall must remove the configuration"
[ ! -f "$HOME_DIR/config/telegram-token" ] || fail "uninstall must remove a stale fallback token"
[ ! -f "$HOME_DIR/state/fm-telegram.check.sh" ] || fail "uninstall must remove the watcher check"
[ ! -f "$HOME_DIR/config/check-cadence.env" ] || fail "uninstall must release the 30s check cadence"
[ -z "$(ls -A "$KEYSTORE" 2>/dev/null)" ] || fail "uninstall must remove the stored token"
if [ "$pending_before" -gt 0 ]; then
  case "$out" in *"still on disk"*) ;; *) fail "uninstall must account for already-received messages, got: $out" ;; esac
fi
out=$(tg fm-tg-poll.sh 2>&1)
[ -z "$out" ] || fail "an uninstalled channel must be inert again, got: $out"
pass "uninstall: token, pairing, config, and polling are removed, and received messages are accounted for"

echo "ok - fm-telegram: all checks passed"
