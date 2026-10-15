# Discord captain channel

The Discord captain channel is an optional, self-hosted conversation between one Firstmate home and one explicitly configured Discord guild text channel.
It uses the owner's Discord application and bot, opens no inbound port, needs no myfirstmate.io token or service, and ships disabled.

The bridge is another door to the same Firstmate conversation and task lifecycle, not a second chatbot, task engine, or supervisor.
It polls Discord's official HTTP API through the existing Firstmate supervision cycle, commits accepted messages to a private durable inbox, and posts substantive Firstmate replies through one outbound command.

[`configuration.md`](configuration.md#discord-captain-channel-configdiscordjson) owns the local schema and state layout.
`bin/fm-discord.sh --help` owns exact commands.
The `discord-captain-channel` skill owns how Firstmate handles messages and reports outcomes.

## Supported conversation

The configured owner can write ordinary messages in the configured channel without mentioning the bot.
Firstmate answers questions, accepts work through the normal lifecycle, asks for decisions, and can link longer-running work back to the Discord request that started it.
Only the configured owner's messages carry authority.
Other viewers, roles, users, bots, webhooks, applications, channels, guilds, edits, and replays are rejected even when they can see the channel.

Plain text, reply text, and attachment metadata are accepted as source content.
The bridge does not download attachments.
Quoted messages, forwarded material, and attachments never gain instruction or approval authority from the configured owner's act of including them.

Replies are plain text with all mentions disabled and split within Discord's 2,000-character message limit.
Large reports, raw logs, tool traces, hidden reasoning, secrets, unrelated private material, and historical local conversation are never copied into Discord.
Send a safe review or tailnet link when a result is too large for a concise answer.

Task linking supports later milestone and final outcomes for work that began in Discord.
The bridge does not mirror every local message or proactively copy unrelated work into Discord.
Unprompted reporting remains limited to captain-relevant decisions, review-ready work, terminal outcomes, real blockers, and credential needs, using stable event or task keys so retries cannot silently duplicate them.

## Private audience protection

Initial setup accepts only a channel whose effective viewers are the configured owner and the configured bot.
Before every intake poll and before every outbound chunk, the bridge fetches the channel, guild roles, and complete guild-member list and applies Discord's documented permission algorithm, including member overwrites and the fact that `Administrator` and the guild owner bypass channel overwrites.
Threads are not accepted as the configured destination; setup requires a guild text channel.

If the effective viewer set changes or cannot be completely verified, intake and private outbound reporting stop.
After reviewing the new scope locally, confirm the exact human viewer IDs with:

```sh
bin/fm-discord.sh confirm-audience --ids OWNER_ID,VIEWER_ID
```

Confirmed viewers receive no task, merge, spending, publishing, destructive-action, or administrative authority.
Only `owner_id` is accepted for inbound instructions, and Firstmate's ordinary merge and sensitive-action rules continue to apply.
The bridge never backfills local conversation or reports to newly confirmed viewers.
Discord itself may expose messages already present in the channel when its permissions grant a new viewer Read Message History; Firstmate cannot prevent that platform behavior.

Discord is not end-to-end encrypted.
Discord platform operators and anyone with effective server access may be able to access channel content.
The bridge's audience check proves the guild members who currently have `VIEW_CHANNEL`; it cannot prove what Discord personnel or infrastructure can access.
Do not enable this channel for material that cannot be entrusted to Discord.

## Discord application setup

Create a dedicated application and bot in the [Discord Developer Portal](https://discord.com/developers/applications).
Do not use a user token, personal-account automation, or a self-bot.

Enable only these privileged intents in the application's Bot settings:

- Message Content Intent, because Discord otherwise removes message content, embeds, and attachments from API message objects.
- Server Members Intent, because Discord requires it to list all guild members and Firstmate cannot prove the effective private audience without that complete list.

These intents are data access settings, not server permissions.
For small unverified applications Discord currently allows the application owner to enable them in the Developer Portal; larger applications can require Discord review under Discord's current policy.

Generate an installation URL with the `bot` scope and only these server permissions:

- View Channels.
- Send Messages.
- Read Message History.

Do not grant Administrator, Manage Server, Manage Channels, Manage Roles, Manage Messages, webhooks, attachments, embeds, reactions, or slash-command permissions.
Create a dedicated private guild text channel with `@everyone` denied View Channel and explicit access for only the owner and bot.
The safest initial topology is a dedicated server owned by the configured owner with no other human members or administrator roles, because the guild owner and administrators bypass channel denies.

No setup command creates an application, installs a bot, changes server permissions, enables intents, or posts a message.

## Local setup

Keep the token out of shell history and process arguments.
On macOS, store it in the login keychain from standard input:

```sh
pbpaste | bin/fm-discord.sh token
```

Use the Discord bot token from this dedicated application only.
Do not reuse an FMX or myfirstmate.io pairing token, another service credential, or a Discord user token.

The weaker cross-platform fallback is a gitignored mode-0600 file readable by anything that can read the Firstmate config directory:

```sh
pbpaste | bin/fm-discord.sh token --owner file
```

Copy numeric IDs with Discord Developer Mode, then bind the exact owner, guild, and channel:

```sh
bin/fm-discord.sh configure --guild GUILD_ID --channel CHANNEL_ID --owner OWNER_USER_ID
```

The command verifies the bot identity, exact channel type, required bot permissions, full effective audience, and owner membership before writing the disabled configuration.

Enable only after reviewing the redacted status:

```sh
bin/fm-discord.sh status
bin/fm-discord.sh enable
```

Enable seeds its cursor from the newest existing Discord message, so it does not import channel history.
It registers one credential-free Firstmate check and joins the shared 30-second inbound-channel cadence.
No webhook, public ingress, paid host, new LLM provider, or messaging subscription is added.
Existing AI inference and local hardware or hosting costs still apply, and Discord may change its own product limits or pricing.

## Delivery and recovery behavior

Polling is bounded to five 100-message history pages by default.
The cursor advances only after each accepted message is durably created or each rejected event is classified, so a restart can replay an event without duplicating work.
If the bounded history cannot reach the prior cursor, the bridge advances nothing and reports the backlog rather than silently skipping messages.

The local reply ledger claims a stable request, task-update, or event key before sending.
Discord's `nonce` plus `enforce_nonce` is also set for each chunk.
A confirmed receipt records the returned message identity; a rejected request is retryable; a network or server failure after a send begins is recorded as uncertain and requires explicit inspection plus `--resend`.
Rate-limit responses persist Discord's `Retry-After` before returning, so later checks wait without busy-looping.
Authentication, permission, privacy, and unavailable-API failures are deduplicated instead of waking Firstmate unchanged on every cycle.

## Rollback

Stop intake while preserving configuration, token, cursor, and queued messages:

```sh
bin/fm-discord.sh disable
```

Remove the local credential and configuration while retaining already received private state for deliberate review or deletion:

```sh
bin/fm-discord.sh uninstall
```

Then remove the bot from the server and reset or delete it in the Discord Developer Portal.
The Firstmate commands do not perform those live Discord actions.
Relay, Telegram, and the dashboard remain independent and unchanged throughout setup and rollback.

## Verification and live-test boundary

Deterministic behavioral coverage uses an owned loopback fake through the real CLI interfaces:

```sh
bash tests/fm-discord.test.sh
```

The test proves default-off behavior, owner/no-mention intake, identity rejection, replay suppression, cursor ordering, restart recovery, chunked output, 429 persistence, invalid credentials, uncertain sends, and audience-change refusal.
[`verification/discord-channel.md`](verification/discord-channel.md) records the maintained evidence.

No offline test proves Discord credentials, portal intent settings, live server permissions, or Discord's current production behavior for a particular account.
A credentialed smoke test remains an operator setup prerequisite and must use a dedicated private test channel without sensitive content.
