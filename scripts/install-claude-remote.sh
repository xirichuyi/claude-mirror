#!/usr/bin/env bash
# Runs on the target server. Does not read or write Claude credentials.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'This installer supports Linux, macOS and Linux under WSL.' >&2; exit 1 ;;
esac
if command -v claude >/dev/null 2>&1; then
  echo "Claude already installed: $(command -v claude)"
  claude --version || { echo 'Existing Claude cannot launch; repair its platform/libc compatibility before continuing.' >&2; exit 1; }
else
  command -v curl >/dev/null 2>&1 || { echo 'Install curl on the remote server first.' >&2; exit 1; }
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  echo 'Installing Claude Code using the official stable installer...'
  curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 180 https://claude.ai/install.sh -o "$installer"
  bash "$installer" stable
  hash -r
  claude --version
fi
if ! command -v node >/dev/null 2>&1 || ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>18||(a===18&&b>=14)?0:1)'; then
  echo 'Claude is installed. Claude Mirror additionally needs Node.js >=18.14 on the remote server.' >&2
  exit 3
fi
# systemd-logind with KillUserProcesses=yes kills every process of an SSH login when it ends,
# including Claude Mirror's background sessions. A lingering user manager lets them survive.
if command -v loginctl >/dev/null 2>&1 && [ "$(loginctl show-session -p KillUserProcesses --value 2>/dev/null)" = yes ]; then
  user=$(id -un)
  if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = yes ]; then
    echo 'Background sessions: user lingering already enabled.'
  elif loginctl enable-linger "$user" 2>/dev/null; then
    echo "Background sessions: enabled user lingering for $user, so replies continue after SSH disconnects."
  else
    echo "Warning: this server ends background sessions when SSH disconnects (KillUserProcesses=yes)." >&2
    echo "Ask an administrator to run: sudo loginctl enable-linger $user" >&2
  fi
fi
echo 'Ready. If Claude is not authenticated, SSH into this server and run: ~/.local/bin/claude auth login (or claude auth login for an existing PATH installation).'
echo 'Then connect to the same SSH host in Claude Mirror.'
