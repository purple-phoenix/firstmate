# Telegram captain channel

A private one-to-one Telegram chat with your own firstmate, so you can reach it from a phone without SSH.
It ships inert: firstmate does nothing with Telegram until you create a bot, pair your account, and explicitly enable the channel.

Mechanics live with their owners: [`configuration.md`](configuration.md) owns the schema and tunables, and each script's `--help` owns its exact flags - `bin/fm-tg-setup.sh` (setup and removal), `bin/fm-tg-inbox.sh` (reading messages), `bin/fm-tg-reply.sh` (sending), `bin/fm-tg-poll.sh` (the poll itself).
The `telegram-captain-channel` skill owns how firstmate decides what to say.

## What it is for

SSH from a phone works, but it is hard to read, hard to type into, has no autocorrect, and puts far more operational output on screen than you want in public.
This channel gives the same firstmate a phone-shaped door: short messages, a real keyboard, searchable history, and push notifications.

It is the same agent and the same fleet, not a second one.
Anything you ask for here runs through firstmate's normal lifecycle and lands in the normal records.

## What arrives on your phone

Firstmate answers what you send, and otherwise stays quiet.
Unprompted, it messages you for five things only:

- a decision that is genuinely yours,
- work ready for your review, with the full review link,
- the final result of something you asked about here,
- a real blocker it could not clear,
- a credential or login it needs (it names what is needed and never asks you to send it here).

Routine progress, worker chatter, validation steps, and monitoring events never reach Telegram.
Structurally, only `bin/fm-tg-reply.sh` can send, and only firstmate itself calls it - no watcher, hook, or lifecycle script can push to your phone.

Long material stays behind links: reports, evidence boards, image comparisons, the capacity dashboard, and CI output are sent as tailnet-only URLs rather than pasted into chat.

## What you can send

This first version handles **private one-to-one text messages**, and nothing else.
If the paired captain sends a photo, voice note, document, sticker, blank message, or oversized text in that private chat, firstmate records only its unsupported or oversized kind, stores none of its content, and replies once with that fact.
Forwarded messages, bot-mediated messages, stories, other senders or chats, and all group or channel traffic are rejected silently without storing or echoing their text.

Four short commands exist because they are awkward to type on a phone.
Everything else is just talking to firstmate normally.

| you type | you get |
| --- | --- |
| `/status` | what is moving right now, one line per piece of work |
| `/decisions` | what is waiting on you, with a recommendation each |
| `/review` | work ready for you, each with its full link |
| `/help` | the above, plus "or just talk to me" |

## Privacy limitation - read this before enabling

**Telegram bot chats are not end-to-end encrypted.**
Telegram's servers can read every message in both directions.

So:

- Never send a password, API key, token, recovery code, or private URL with an embedded secret through this channel, and firstmate will never ask you for one here.
- Firstmate declines destructive, irreversible, and security-sensitive requests over Telegram and asks you to confirm them in the terminal or over the tailnet.
  That is deliberate: those are exactly the actions someone with access to your Telegram account would want.
- Assume your operational conversation is visible to Telegram. If that is not acceptable for your work, do not enable this channel.

The bot token itself is held outside the chat, in your macOS login keychain by default.
Nothing in firstmate prints it, passes it as a command argument, writes it into a log, or embeds it in a generated script.

## Transport and exposure

Firstmate polls Telegram outbound and nothing more:

- It calls the Bot API's `getUpdates` with a bounded long poll every 30 seconds while the channel is enabled.
- **No port is opened.** No webhook is registered - enabling the channel explicitly clears any webhook, so the pull path is the only path.
- Nothing but Telegram itself sits in the middle: no OpenClaw, relay, tunnel, Funnel, or other third-party service.

Telegram holds an unread update for at most 24 hours, so the next poll picks it up if firstmate resumes within that service window.

### How long a message waits

Enabling the channel switches this home to the 30-second check cadence owned by [`configuration.md`](configuration.md#watcher-check-cadence-configcheck-cadenceenv), so **expect firstmate to notice a message within about 30 seconds** and to start answering it on its next turn.
That is the honest worst case for pickup, not for a reply: how long the answer itself takes depends on what you asked for.

Two things change that number, and both are stated where they happen rather than hidden:

- **A supervision cycle that was already running when you enabled the channel keeps its old cadence until it restarts.** The `enable` command says so and prints the exact restart instruction for your harness. Until then pickup stays on the old 300-second cadence.
- **Nothing is supervising at all.** Then nothing polls, and the message waits until firstmate is supervising again (within Telegram's 24-hour retention). `bin/fm-tg-setup.sh status` showing `monitored: no` is this case.

## Setup

You need a phone with Telegram and about two minutes.

**1. Create the bot in Telegram.**
Open a chat with `@BotFather`, send `/newbot`, and answer its two questions (a display name, then a username ending in `bot`).
It replies with a token that looks like `123456789:AA...`.
Keep that message on screen; you will paste the token once, in the next step.

Then, still in BotFather, send `/setprivacy` and choose your new bot - this channel only uses private chats, so privacy mode on is the right setting.

**2. Store the token, without ever typing it into a chat.**
Copy the token from BotFather, then on the machine running firstmate:

```sh
pbpaste | bin/fm-tg-setup.sh token
```

The token is read from standard input only - never as a command argument - checked against Telegram, and stored in your macOS login keychain.
The confirmation names your bot, never the token.

On a machine without a keychain, or if the keychain path fails, use the weaker fallback:

```sh
pbpaste | bin/fm-tg-setup.sh token --owner file
```

On a non-macOS host, replace `pbpaste` with your platform's clipboard or secret-tool command while keeping the token on standard input.

That writes a gitignored mode-0600 `config/telegram-token`.
It is weaker on purpose: anything that can read your firstmate home can read the token. Prefer the keychain where you have one.

**3. Pair your phone.**
In Telegram, open a private chat with the bot you just made.
Then run:

```sh
bin/fm-tg-setup.sh pair
```

The command prints a one-time `/start` command for you to send in that private chat, listens briefly for that exact challenge, and records your numeric Telegram user id and private chat id.
An ordinary `/start` or a message from someone who only knows the bot username cannot claim the pairing.
From then on those two numbers are the whole allowlist: any other sender, any other chat, and any group or channel is dropped without a reply.
The confirmation shows only the last four digits.

**4. Turn it on.**

```sh
bin/fm-tg-setup.sh enable
```

This clears any webhook, registers the watcher check that polls for your messages every 30 seconds, and flips the channel on.
It also prints the restart instruction for your harness when a supervision cycle is already running, because that cycle keeps its old cadence until it restarts.
Send it a message from your phone; firstmate normally notices it within about 30 seconds.

Check the state at any time - it never prints the token or your full identity:

```sh
bin/fm-tg-setup.sh status
```

## Turning it off

```sh
bin/fm-tg-setup.sh disable     # stop polling, keep the bot and the pairing
bin/fm-tg-setup.sh uninstall   # also remove the token, pairing, and configuration
```

`disable` stops the poll, removes the watcher check, and reports how many already-received messages are still queued locally; re-enable with `enable` and they are still there.
It also returns this home to the default 300-second check cadence unless X mode still needs the fast one, and prints the restart instruction for that too.

`uninstall` additionally deletes the stored token and `config/telegram.json`.
It reports failure and keeps the disabled configuration when either token owner cannot be confirmed empty, so you can unlock or repair that owner and retry cleanup.
Messages already received stay on disk under your home's state directory and are reported so you can delete them deliberately.
To remove the bot itself, send `/deletebot` to BotFather.

Either way there was never anything listening, so nothing stays reachable from outside.

## Troubleshooting

| what you see | what it means |
| --- | --- |
| firstmate never answers | The channel is off, or nothing is supervising. Run `bin/fm-tg-setup.sh status`: `accepting: no` means run `enable`; `monitored: no` means the watcher check is missing, so re-run `enable`. |
| "Telegram rejected the bot token" | The token was revoked or replaced in BotFather. Re-run the `token` step with the new one. |
| "another client is polling this bot, or a webhook is still registered" | Two things are reading the same bot - another firstmate home, another tool, or a leftover webhook. Give each home its own bot, then re-run `enable` to clear the webhook. |
| a reply never arrived and firstmate says the outcome is unknown | A send timed out after the request went out, so Telegram may or may not have delivered it. Check the chat. Firstmate deliberately will not guess or silently resend. |
| your messages are ignored with no reply at all | They are arriving from a different Telegram account or chat than the paired one. Re-run `pair` from the phone you actually use. |
| `status` shows a last error | It is the most recent poll failure in plain language; it clears itself once polling recovers. |

## Where things live

- `config/telegram.json` - the channel configuration (gitignored, mode 0600).
- `config/telegram-token` - the fallback token file, only when you chose `--owner file` (gitignored, mode 0600).
- `state/tg/` - the durable message queue, update cursor, and reply ledger (mode 0700).
- `state/fm-telegram.check.sh` - the registered watcher check; it holds no secret.
- `config/check-cadence.env` - the generated 30-second check cadence, shared with X mode and removed when no channel is armed (gitignored, mode 0600).

## Verification evidence

Active maintainer verification for this channel's inertness, allowlisting, secret-handling, crash-safety, delivery, and no-exposure guarantees lives in [`verification/telegram-channel.md`](verification/telegram-channel.md).

Reproduce the current guarantees with:

```sh
bash tests/fm-telegram.test.sh
```
