#!/usr/bin/env bash
# fm-discord.sh - optional self-hosted Discord captain conversation.
#
# This is the public entry point for setup, bounded polling, durable inbox
# consumption, replies, and task links. The implementation and exact command
# help live in bin/fm-discord.mjs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-discord.mjs" "$@"
