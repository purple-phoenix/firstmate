# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent hook-nudge use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `fm-capacity.mjs`        | Classify meaningful fleet capacity and replace the private offline pipeline dashboard |
| `fm-wait-progress.mjs`   | Honest wait-progress estimator and the private rolling observed-duration record behind the dashboard's self-clearing waits |
| `fm-decision-document.mjs` | Parse bounded structured dashboard decision records for snapshot and service consumers |
| `fm-dash-serve.mjs`      | Serve the capacity dashboard tailnet-only with captain-authenticated interactions (docs/dashboard-service.md) |
| `fm-dash-install.sh`     | Install the persistent dashboard service: launchd agent, never-Funnel tailscale serve mapping, and registered fm-dash check |
| `fm-dash-inbox.sh`       | List and claim durable captain dashboard commands from `state/dash-inbox/`           |
| `fm-dash-chat.sh`        | Claim captain dashboard chat messages and record the one reply per message           |
| `fm-dash-pr-evidence.mjs` | Read-only typed merge-review evidence for one task's recorded GitHub PR             |
| `fm-dash-merge.sh`       | Validate and one-time-consume an exact dashboard merge approval through the guarded merge owner |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and secondmate homes from origin          |
| `fm-task-add.sh`         | Create backlog items with creation-time task-ID validation and safe mint fitting     |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-decision-hold.sh`    | Create, verify, complete, and resolve durable captain-held decisions                 |
| `fm-brief.sh`            | Scaffold ship, scout, secondmate-charter, and Herdr-lab briefs                       |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-herdr-session-cleanup.sh` | Conservatively retire stale restored-shell Herdr presentation children at locked session start |
| `fm-doc-audience-check.sh` | Validate the tracked documentation audience inventory and local links              |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `fm-test-isolation-proof.sh` | Concurrent isolation proof and proven-isolated candidate set owner |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and stale watcher liveness   |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for fm-lock.sh and the Claude Stop auto-arm |
| `fm-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a secondmate home and maintain `data/secondmates.md`       |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/herdr-workspace-move.py` | Send and verify the whitelisted Herdr presentation workspace move request |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live secondmates mid-session and send a pointer to the literal-content config reread when config changed |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`           |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and one-shot escalation |
| `fm-secondmate-report.sh` | Optional helper to append a correlated parent status or document-pointer report       |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `fm-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-supervision-lib.sh`  | Shared armed-captain-channel and in-flight-work-without-fresh-watcher-beacon predicates |
| `fm-cadence.sh`          | Single owner of the watcher check cadence: reconcile and validate `config/check-cadence.env`, then apply the fixed interval at watcher launch |
| `fm-cadence-lib.sh`      | Shared check-cadence constants and generated-file body for the cadence owner and status consumers |
| `fm-push-transition-lib.sh` | Shared watcher owner for native push-transition escalation                       |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes, emit bounded best-effort status-event annotations, then assert watcher liveness |
| `fm-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher identity/health helpers       |
| `fm-classify-lib.sh`     | Shared captain-relevant and declared-external-wait wake classification vocabulary    |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, composer capture, and verified submit |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication and identity-bound retirement |
| `fm-pr-poll.sh`          | Provide the byte-static PR/MR merge and GitHub ready-preview watcher for validated sidecars |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `fm-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm the static PR watcher |
| `fm-pr-merge.sh`         | Record PR metadata, then merge a task's canonical full GitHub URL                    |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task                               |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash newly offered mentions and emit their once-only wake |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for an X-mode-linked task                |
| `fm-tg-lib.sh`           | Shared Telegram-channel config, secret-owner, transport, and durable-record helpers  |
| `fm-tg-setup.sh`         | Guarded Telegram channel setup, pairing, enable, disable, status, and removal        |
| `fm-tg-poll.sh`          | One bounded Telegram long poll: validate, commit, and wake on new captain messages   |
| `fm-tg-inbox.sh`         | List and claim durable captain messages from `state/tg/inbox/`                       |
| `fm-tg-reply.sh`         | Send one at-most-once captain-facing reply operation, split within Telegram's limit |
| `fm-tg-link.sh`          | Bind a task to the Telegram message that asked for it, so its outcome returns there |
