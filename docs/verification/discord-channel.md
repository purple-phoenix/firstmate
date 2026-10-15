# Discord captain channel verification

This record supports the active inertness, identity binding, audience verification, durable delivery, and no-public-ingress guarantees of the optional direct Discord captain channel.
The operator contract lives in [`../discord-channel.md`](../discord-channel.md).

## Protocol basis

Verified on 2026-10-15 against Discord's current official documentation:

- [Message objects and Get Channel Messages](https://docs.discord.com/developers/resources/message#get-channel-messages) document that message-content fields are empty without the Message Content privileged intent, that history reads require View Channel and Read Message History, and that history pages contain at most 100 messages.
- [Create Message](https://docs.discord.com/developers/resources/message#create-message) documents the 2,000-character content limit, Send Messages requirement, `allowed_mentions`, and unique `nonce` enforcement.
- [Permissions](https://docs.discord.com/developers/topics/permissions#permission-overwrites) documents the effective-permission order and the guild-owner and Administrator bypasses applied by the bridge.
- [List Guild Members](https://docs.discord.com/developers/resources/guild#list-guild-members) documents the 1,000-member page limit and Server Members privileged-intent requirement.
- [Rate Limits](https://docs.discord.com/developers/topics/rate-limits#exceeding-a-rate-limit) requires clients to honor `Retry-After` or `retry_after` after HTTP 429.

The direct connector uses only those official bot endpoints.
It does not call myfirstmate.io, use a user token, automate the Discord client UI, or open a webhook or listening socket.

## Deterministic transport verification

Environment: macOS, Node.js `v26.11.1`, repository-owned loopback HTTP fake, no Discord credential.

Command:

```sh
bash tests/fm-discord.test.sh
```

Result on 2026-10-15: all 15 behavioral assertions passed.
The public `bin/fm-discord.sh` interface proved default-off no-network behavior; token and identity setup without posting; allowed-owner no-mention intake; rejection of other authors, bot self-echo, and wrong channels; replay suppression; identity-bound cursor reseeding, request quarantine, and stale-link refusal; cursor-before-ack restart behavior; quoted and attachment source labelling; ordered long-message chunks; mention suppression; bounded reply-capacity reservation; credential-backend migration and cleanup rollback; durable 429 backoff; deduplicated invalid-credential reporting; explicit uncertain-send recovery with Discord nonce convergence; changed-audience refusal and exact local confirmation; unavailable and inconsistent audience-context refusal; task-linked milestone and final outcomes; and clean disable.

The fake exercised HTTP responses and transport disconnects through the public connector rather than inspecting implementation source text.
Its fixtures do not prove a live Discord account, credential, Developer Portal intent, server permission, or production rate-limit bucket.

## Shared supervision regression

Command:

```sh
bash tests/fm-check-cadence.test.sh
```

Result on 2026-10-15: all 20 assertions passed.
A Discord-only home armed the existing single 30-second cadence owner, while default, Telegram-only, Relay-only, dashboard-only, and combined-channel behavior retained their prior outcomes.

The direct connector is an ordinary registered check and sender above the shared supervision boundary.
It adds no harness-specific hook, terminal scrape, runtime extension, or backend process.
Primary runtime and backend behavior therefore remains owned by the existing supervision protocol and is not claimed as independently live-tested by this record.

Commands:

```sh
bash tests/fm-telegram.test.sh
bash tests/fm-x-mode.test.sh
bash tests/fm-supervision-instructions.test.sh
bash tests/fm-watch-checkpoint.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
node --check bin/fm-discord.mjs
```

Result on 2026-10-15: every command exited 0.
The Telegram suite reported all checks passed, the Relay suite retained its direct X and relay-Discord behavior, every primary-harness supervision rendering assertion passed, every foreground-checkpoint assertion passed, ShellCheck `0.11.0` and actionlint `1.7.12` passed, the documentation inventory reported `ok surfaces=127 local_links=762`, and Node syntax validation was silent.

## Live prerequisite

A live smoke test remains deliberately undone.
It requires separate operator authority and a dedicated private test guild text channel, bot token, Message Content intent, Server Members intent, and minimum View Channels, Send Messages, and Read Message History permissions.
That test must contain no sensitive content and must recheck the redacted status and effective audience before the first real message.
