#!/bin/sh
# Usage: sh scripts/setup-remote.sh [--runner NAME [--project DIR] [--copy-login]] [SSH options] host
# The --runner options are for a server reached as root; see install-claude-remote.sh.
set -eu
options=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runner|--project)
      [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      # The value crosses the remote shell once, so it is single-quoted for it.
      options="$options $1 '$(printf '%s' "$2" | sed "s/'/'\\\\''/g")'"; shift 2 ;;
    --copy-login) options="$options $1"; shift ;;
    *) break ;;
  esac
done
if [ "$#" -eq 0 ]; then
  echo 'Usage: sh scripts/setup-remote.sh [--runner NAME [--project DIR] [--copy-login]] [-p port] [-i key] user@host' >&2
  exit 2
fi
# OpenSSH handles config aliases, keys, passwords and host-key verification.
ssh "$@" "bash -s --$options" < "$(dirname "$0")/install-claude-remote.sh"
