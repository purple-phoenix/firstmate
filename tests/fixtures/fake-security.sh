#!/usr/bin/env bash
set -u

action=${1:-}
shift || true
account=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -a ] && [ "$#" -gt 1 ]; then
    account=$2
    shift 2
    continue
  fi
  shift
done
[ -n "$account" ] || exit 2
keychain_file="$FM_FAKE_KEYCHAIN_DIR/$account"
mkdir -p "$FM_FAKE_KEYCHAIN_DIR"
case "$action" in
  add-generic-password)
    IFS= read -r secret
    printf '%s\n' "$secret" > "$keychain_file"
    chmod 600 "$keychain_file"
    ;;
  find-generic-password)
    [ -f "$keychain_file" ] || exit 44
    cat "$keychain_file"
    ;;
  delete-generic-password)
    [ "${FM_FAKE_KEYCHAIN_DELETE_FAIL:-0}" != 1 ] || exit 1
    rm -f "$keychain_file"
    ;;
  *)
    exit 2
    ;;
esac
