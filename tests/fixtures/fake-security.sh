#!/usr/bin/env bash
set -u

action=${1:-}
case "$action" in
  add-generic-password)
    IFS= read -r secret
    printf '%s\n' "$secret" > "$FM_FAKE_KEYCHAIN"
    chmod 600 "$FM_FAKE_KEYCHAIN"
    ;;
  find-generic-password)
    [ -f "$FM_FAKE_KEYCHAIN" ] || exit 44
    cat "$FM_FAKE_KEYCHAIN"
    ;;
  delete-generic-password)
    [ "${FM_FAKE_KEYCHAIN_DELETE_FAIL:-0}" != 1 ] || exit 1
    rm -f "$FM_FAKE_KEYCHAIN"
    ;;
  *)
    exit 2
    ;;
esac
