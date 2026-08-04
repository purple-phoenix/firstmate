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
The fake API's own request log was asserted to contain the token, so the proof is not vacuous: the token demonstrably reached the loopback Bot API endpoint and no forbidden destination.

## No listening socket, no webhook, one sender

Asserted structurally over `bin/fm-tg-*.sh`: no `setWebhook`, `nc -l`, `--listen`, `createServer`, `socat`, or `LISTEN`; `bin/fm-tg-reply.sh` is the only script that calls `sendMessage`; and no script outside the `fm-tg-` family references `bin/fm-tg-reply.sh`, so no watcher, hook, or lifecycle path can push internal progress to the captain's phone.
`enable` was observed calling `deleteWebhook`, so the pull transport is the only transport.

## Watcher integration

The registered `state/fm-telegram.check.sh` printed exactly one bounded line while messages were pending, satisfied `fm_custom_check_registered` from `bin/fm-check-lib.sh`, and lost its registration when its bytes were tampered with - so the watcher refuses it rather than executing it.
`fm_supervision_needed` from `bin/fm-supervision-lib.sh` returned true for a home with an armed channel and no fleet work, which is what keeps a Telegram-only home on one live supervision cycle.

## Check cadence

2026-08-03, macOS 15.6 (Darwin 24.6.0), node v26.5.0, jq 1.7.1, ShellCheck 0.11.0.

```sh
bin/fm-test-run.sh tests/fm-check-cadence.test.sh tests/fm-telegram.test.sh \
  tests/fm-x-mode.test.sh tests/fm-supervision-instructions.test.sh \
  tests/fm-daemon.test.sh tests/fm-arm-pretool-check.test.sh
```

`FM_TEST_SUMMARY total=6 failed=0 skipped_gate=0`.

An enabled channel raises this home from the 300s default sweep to 30s through the single generated `config/check-cadence.env` owned by `bin/fm-cadence.sh` ([`configuration.md`](../configuration.md#watcher-check-cadence-configcheck-cadenceenv)).
The suites establish, in order:

- **The matrix.** A home with neither channel wrote no cadence file and a watcher would start at 300s; a Telegram-only home and an X-only home each started at 30s; a home with both produced exactly one file in `config/`, so two armed channels never yield two config owners.
- **Bounded load.** The cadence changes only how often the existing watcher sweeps; `bin/fm-tg-poll.sh` keeps its own bounded long poll (`FM_TG_POLL_TIMEOUT`, default 10s, within `FM_CHECK_TIMEOUT`), its 100-record ingress bound, its ledger reservations, and its once-per-cause error dedupe, all still asserted by `tests/fm-telegram.test.sh`.
- **Transitions.** `enable` armed the cadence and re-running it left the file byte-identical without re-announcing a transition; `disable` and `uninstall` released it; `disable` with X mode still armed deliberately kept it; and repeated `reconcile` runs were byte-stable.
- **No false claim of a live re-read.** `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` once at process start, and every transition line was asserted to say the new cadence applies to the next supervision cycle and to carry the emitted harness repair instruction rather than restarting anything.
- **Migration.** A home carrying the pre-rename `config/x-mode.env` had it removed and replaced with the current owner in the armed case, and removed outright in the idle case, so no home is left with two cadence owners.
- **Artifact safety.** The generated file is mode 0600, is refused rather than written when its destination is a symlink (the link target's bytes and mode were unchanged), and contains exactly one non-comment line - the interval export - with no token, chat id, user id, or bot identity.
- **Away mode.** `exec_watcher_with_cadence` in `bin/fm-supervise-daemon.sh` started a probe watcher at 30s for an armed home and 300s for an unarmed one, and picked up a mid-away release on the next spawn, so the away-mode watcher is not stranded on the default cadence for the stretch the captain is most likely to message.
- **Arm-command policy.** `bin/fm-arm-command-policy.mjs` denies every cadence-source prefix on a watcher command; the protected arm and checkpoint owners apply the fixed interval only after `bin/fm-cadence.sh` validates the artifact without evaluating its bytes.
- **Tail scheduling.** `tests/fm-watcher-lock.test.sh` runs two individually slow ordinary checks while a Telegram check becomes due between each one, proving the single watcher re-enters the validated inbound dispatcher exactly at those due points, preserves ordinary-check progress, and exits on the resulting captain wake before starting the next ordinary check.

On 2026-08-04, `bash tests/fm-supervision-instructions.test.sh && bash tests/fm-watch-checkpoint.test.sh` completed with exit 0.
The renderer test proves that Kimi's normalized unknown fallback uses the bounded checkpoint owner instead of a raw watcher launch, and the checkpoint test proves that owner applies a valid cadence while refusing a symlinked executable payload at the default cadence without evaluating its bytes.
On 2026-08-04, `bash tests/fm-watcher-lock.test.sh` completed with exit 0.

## Keychain owner

The `security` prompt path this channel uses (`add-generic-password ... -w` with the value on standard input, no keychain argument after `-w`) was confirmed on 2026-08-02 to consume stdin rather than an argument: run non-interactively it reached `password data for new item: retype password for new item:` and then refused with `security: SecKeychainItemCreateFromContent (<default>): User interaction is not allowed`, creating nothing.
An earlier variant that placed the keychain path after `-w` was observed storing the literal next argument as the secret, which is why the production call keeps `-w` last with no trailing operand.
Creating the item itself requires an unlocked login keychain in an interactive session - the operator's real setup context - and was deliberately not exercised from the isolated task worktree.
`bin/fm-tg-setup.sh token` reports that exact failure and points at the `--owner file` fallback, which the suite exercises end to end at mode 0600 against the repository's gitignore entries.

## Compatibility axes reviewed

- **Primary harnesses** (`claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`): the channel adds a registered watcher check and an agent skill, neither of which is harness-specific.
  The one shared-behavior change is `bin/fm-supervision-lib.sh` treating an armed channel as a supervision need; Claude's tokenless auto-arm and cooperative turn-end guard consume that full predicate directly, while the other harness protocols keep or re-arm their ordinary watcher cycle under the always-loaded supervision contract.
  The check cadence rides the validated launch owner for every primary path: `tests/fm-supervision-instructions.test.sh` asserts that `claude`, `codex`, `opencode`, `pi`, `pi-signed`, and `grok` preserve their own repair mechanisms, while Kimi's normalized unknown fallback names the bounded checkpoint owner rather than raw `fm-watch.sh`; `tests/fm-watch-checkpoint.test.sh` covers both accepted and refused cadence artifacts on that fallback path.
  `tests/fm-turnend-guard.test.sh`, `tests/fm-claude-stop-autoarm.test.sh`, `tests/fm-guard-stale-banner.test.sh`, and `tests/fm-supervision-instructions.test.sh` all passed.
- **Runtime backends** (`tmux`, `herdr`, `zellij`, `orca`, `cmux`, and the blocked `codex-app`): not applicable after inspection. The channel spawns nothing, reads no pane or composer, and sends no keystrokes; its wakes travel the ordinary durable wake queue.
- **Away mode**: wake handling unchanged - `classify_check` in `bin/fm-supervise-daemon.sh` escalates every `check:` wake, so a Telegram wake reaches the captain's session exactly as an X-mode or dashboard wake does.
  The daemon also routes each watcher spawn through the validated cadence owner because away mode owns that launch instead of a primary-harness wrapper. `tests/fm-daemon.test.sh` and `tests/fm-supervision-events.test.sh` cover both paths.
- **X mode and dashboard commands**: independently armable, each keeping its own check, records, and wake vocabulary.
  X mode's own artifact is now just its relay poll shim: the cadence it used to write moved to the shared owner, which both channels arm identically, so a home with both gets one cadence and one file. `tests/fm-x-mode.test.sh` asserts that end of it; the dashboard command poll is unchanged and `tests/fm-dash.test.sh` was unaffected.
- **Secondmate homes**: the Telegram configuration is deliberately absent from `FM_INHERITABLE_CONFIG` in `bin/fm-config-inherit-lib.sh`, so it is never propagated. That is required rather than incidental: Telegram permits one `getUpdates` consumer per bot, so two homes sharing a token would fight over updates.
- **Legacy check migration**: `bin/fm-pr-check-migrate.sh` preserves any check that passes `fm_custom_check_registered`, which the Telegram check does. `tests/fm-pr-check-security.test.sh` passed.
