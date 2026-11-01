#!/bin/sh
# Usage: sh scripts/setup-remote.sh [SSH options] host
set -eu
if [ "$#" -eq 0 ]; then
  echo 'Usage: sh scripts/setup-remote.sh [-p port] [-i key] user@host' >&2
  exit 2
fi
# OpenSSH handles config aliases, keys, passwords and host-key verification.
ssh "$@" 'bash -s' < "$(dirname "$0")/install-claude-remote.sh"
