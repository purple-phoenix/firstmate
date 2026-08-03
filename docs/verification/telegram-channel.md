# Telegram captain channel verification

Audience: maintainer verification.

This record supports the current inertness, ingress-allowlisting, secret-handling, crash-safety, at-most-once-delivery, and no-exposure guarantees of the optional Telegram captain channel.
Operator behavior and active limits remain in [`telegram-channel.md`](../telegram-channel.md); the schema and tunables remain in [`configuration.md`](../configuration.md).
Task-specific chronology, temporary paths, and delivery transcripts remain in private reports or PR evidence.

## Regression suite

2026-08-02, macOS 15.6 (Darwin 24.6.0), node v26.5.0, curl 8.7.1, jq 1.7.1, ShellCheck 0.11.0.

```sh
bash tests/fm-telegram.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

All three passed.
`tests/fm-telegram.test.sh` runs the whole channel against a loopback fake Bot API and a fake `security` client, so it never contacts Telegram, never leaves 127.0.0.1, and never touches the operator's keychain.
Its checks establish, in order:

- **Inert by default.** With no configuration the poll printed nothing, created no state, and made no API call, and `status` reported an unconfigured channel.
- **Ordered setup.** A token alone did not enable the channel; `enable` refused until pairing completed.
- **Secret handling.** The token was accepted only on standard input; a malformed paste was refused without echoing it; and the stored value arrived at the keychain client through stdin rather than an argument.
- **Pairing.** A one-time private challenge paged past more than one update batch, bound the exact sender and chat, committed the cursor only through the challenge, and left the captain's later message available to the normal poll.
- **Ingress allowlisting.** A wrong sender id, wrong chat id, supergroup chat, bot sender, `forward_origin`, `via_bot`, `sender_chat`, `edited_message`, `channel_post`, and `callback_query` were each refused with no durable record, no outbound message, and no stored text; only the bounded refusal counter moved.
- **Text is data.** A message containing `$(touch ...)`, backtick substitution, `${IFS}`, and `; rm -rf /` created no file and was stored byte-for-byte in a mode-0600 record.
- **Replay and crash safety.** Re-delivering the same update id against a rewound cursor produced exactly one request, and the commit-before-advance ordering converged without duplication.
- **Malformed and bounded input.** An out-of-order batch containing a photo, an oversized message, a whitespace-only message, an entry with no `update_id`, and a non-object array element was processed in update order; the oversized message's text was not stored.
- **Failure handling.** HTTP 401, HTTP 409, an unreadable body, and an unreachable host each surfaced exactly once, deduplicated until recovery, and leaked neither the token nor the request URL.
- **Outbound.** A short reply was one plain-text message with no `parse_mode` addressed to the paired chat; a second reply for the same request id was refused; markup characters were delivered literally; and long replies preserved single line breaks, split by UTF-16 units, capped their thread, and marked truncation with an ellipsis.
- **Delivery honesty.** A definite refusal sent nothing and left the key retryable; a server error was recorded as ambiguous, refused a silent retry, and required an explicit `--resend`; no path fell back to another channel.
- **State bounds.** Pending ingress stopped before either the 100-record inbox bound or the reply ledger's unanswered-request reservations were exhausted, sent claims plus linked-task final reservations stopped at 200 without pruning at-most-once evidence, claimed requests and dry-run previews retained their newest records by validated record time, and the task update maximum clamped so `.u999` remained available for the final.
- **Removal.** Owner switching rolled back when the prior credential could not be removed; `disable` stopped polling and refused to send; and `uninstall` retained a disabled retryable configuration until both token locations were confirmed empty.

## No process-argument leak

The suite runs every Bot API call through a `curl` shim on `PATH` that appends its own argument vector to a log before exec'ing the real `curl`.
After the full run the log was non-empty, contained `-K` (the mode-0600 config file carrying the token-bearing URL), and contained no occurrence of the token.
The same assertion sweeps the generated watcher check, every durable state record, the configuration file, `status` output, and every diagnostic.
The fake API's own request log was asserted to contain the token, so the proof is not vacuous: the token demonstrably reached Telegram and nowhere else.

## No listening socket, no webhook, one sender

Asserted structurally over `bin/fm-tg-*.sh`: no `setWebhook`, `nc -l`, `--listen`, `createServer`, `socat`, or `LISTEN`; `bin/fm-tg-reply.sh` is the only script that calls `sendMessage`; and no script outside the `fm-tg-` family references `bin/fm-tg-reply.sh`, so no watcher, hook, or lifecycle path can push internal progress to the captain's phone.
`enable` was observed calling `deleteWebhook`, so the pull transport is the only transport.

## Watcher integration

The registered `state/fm-telegram.check.sh` printed exactly one bounded line while messages were pending, satisfied `fm_custom_check_registered` from `bin/fm-check-lib.sh`, and lost its registration when its bytes were tampered with - so the watcher refuses it rather than executing it.
`fm_supervision_needed` from `bin/fm-supervision-lib.sh` returned true for a home with an armed channel and no fleet work, which is what keeps a Telegram-only home on one live supervision cycle.

## Keychain owner

The `security` prompt path this channel uses (`add-generic-password ... -w` with the value on standard input, no keychain argument after `-w`) was confirmed on 2026-08-02 to consume stdin rather than an argument: run non-interactively it reached `password data for new item: retype password for new item:` and then refused with `security: SecKeychainItemCreateFromContent (<default>): User interaction is not allowed`, creating nothing.
An earlier variant that placed the keychain path after `-w` was observed storing the literal next argument as the secret, which is why the production call keeps `-w` last with no trailing operand.
Creating the item itself requires an unlocked login keychain in an interactive session - the operator's real setup context - and was deliberately not exercised from the isolated task worktree.
`bin/fm-tg-setup.sh token` reports that exact failure and points at the `--owner file` fallback, which the suite exercises end to end at mode 0600 against the repository's gitignore entries.

## Compatibility axes reviewed

- **Primary harnesses** (`claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`): the channel adds a registered watcher check and an agent skill, neither of which is harness-specific. The one shared-behavior change is `bin/fm-supervision-lib.sh` treating an armed channel as a supervision need, which reaches `bin/fm-guard.sh`, `bin/fm-turnend-guard.sh`, and Claude's `bin/fm-claude-stop-autoarm.sh` uniformly. `tests/fm-turnend-guard.test.sh`, `tests/fm-claude-stop-autoarm.test.sh`, `tests/fm-guard-stale-banner.test.sh`, and `tests/fm-supervision-instructions.test.sh` all passed.
- **Runtime backends** (`tmux`, `herdr`, `zellij`, `orca`, `cmux`, and the blocked `codex-app`): not applicable after inspection. The channel spawns nothing, reads no pane or composer, and sends no keystrokes; its wakes travel the ordinary durable wake queue.
- **Away mode**: unchanged. `classify_check` in `bin/fm-supervise-daemon.sh` escalates every `check:` wake, so a Telegram wake reaches the captain's session exactly as an X-mode or dashboard wake does. `tests/fm-daemon.test.sh` and `tests/fm-supervision-events.test.sh` cover that path.
- **X mode and dashboard commands**: both untouched and independently armable; each channel keeps its own check, records, and wake vocabulary. `tests/fm-x-mode.test.sh` and `tests/fm-dash.test.sh` were unaffected.
- **Secondmate homes**: the Telegram configuration is deliberately absent from `FM_INHERITABLE_CONFIG` in `bin/fm-config-inherit-lib.sh`, so it is never propagated. That is required rather than incidental: Telegram permits one `getUpdates` consumer per bot, so two homes sharing a token would fight over updates.
- **Legacy check migration**: `bin/fm-pr-check-migrate.sh` preserves any check that passes `fm_custom_check_registered`, which the Telegram check does. `tests/fm-pr-check-security.test.sh` passed.
