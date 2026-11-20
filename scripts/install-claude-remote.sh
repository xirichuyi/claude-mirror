#!/usr/bin/env bash
# Runs on the target server. Does not read or write Claude credentials and never needs root.
# Claude Mirror runs it over its own SSH connection ("一键安装"); setup-remote.sh runs it from a terminal.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'This installer supports Linux, macOS and Linux under WSL.' >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
download() {
  curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 300 "$1" -o "$2"
}

echo '==> Claude Code'
if command -v claude >/dev/null 2>&1; then
  echo "Claude already installed: $(command -v claude)"
  claude --version || { echo 'Existing Claude cannot launch; repair its platform/libc compatibility before continuing.' >&2; exit 1; }
else
  command -v curl >/dev/null 2>&1 || { echo 'Install curl on the remote server first.' >&2; exit 1; }
  echo 'Installing Claude Code using the official stable installer...'
  download https://claude.ai/install.sh "$work/install.sh"
  bash "$work/install.sh" stable
  hash -r
  claude --version
fi

# Node.js runs Claude Mirror's remote agent. A missing or outdated system Node is not replaced:
# an official build goes into ~/.local/share/claude-mirror/node, which the app prefers.
echo '==> Node.js'
NODE_HOME="$HOME/.local/share/claude-mirror/node"
node_ok() { "$1" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>18||(a===18&&b>=14)?0:1)' >/dev/null 2>&1; }
install_node() {
  local os arch glibc base line name expected actual
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "No official Node.js build for $(uname -m); install Node.js 18.14 or newer with the system package manager." >&2; return 1 ;;
  esac
  if [ "$os" = linux ]; then
    if ldd --version 2>&1 | grep -qi musl; then
      echo 'This is a musl system (for example Alpine). Install Node.js with the package manager: apk add nodejs' >&2; return 1
    fi
    glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$glibc" ] && [ "$(printf '%s\n2.28\n' "$glibc" | sort -V | head -1)" != 2.28 ]; then
      echo "glibc $glibc is older than 2.28, which official Node.js builds require. Install Node.js 18.14+ from the system's packages." >&2; return 1
    fi
  fi
  command -v curl >/dev/null 2>&1 || { echo 'Install curl on the remote server first.' >&2; return 1; }
  base="${CLAUDE_MIRROR_NODE_DIST:-https://nodejs.org/dist/latest-v22.x}"
  download "$base/SHASUMS256.txt" "$work/SHASUMS256.txt"
  line=$(grep -E "  node-v[0-9.]+-$os-$arch\.tar\.gz\$" "$work/SHASUMS256.txt" | head -1)
  [ -n "$line" ] || { echo "Node.js download list has no $os-$arch build." >&2; return 1; }
  expected=${line%% *}; name=${line##* }
  echo "Downloading $name (no root needed)..."
  download "$base/$name" "$work/$name"
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$work/$name" | awk '{print $1}')
  else actual=$(shasum -a 256 "$work/$name" | awk '{print $1}'); fi
  [ "$actual" = "$expected" ] || { echo 'Node.js download failed its checksum; nothing was installed.' >&2; return 1; }
  mkdir -p "$work/node" "$(dirname "$NODE_HOME")" "$HOME/.local/bin"
  tar -xzf "$work/$name" -C "$work/node" --strip-components 1
  node_ok "$work/node/bin/node" || { echo 'The downloaded Node.js cannot run on this server.' >&2; return 1; }
  rm -rf "$NODE_HOME.old"; [ -e "$NODE_HOME" ] && mv "$NODE_HOME" "$NODE_HOME.old"
  mv "$work/node" "$NODE_HOME"; rm -rf "$NODE_HOME.old"
  # Never replace a node the user put in ~/.local/bin themselves; the app finds NODE_HOME directly.
  if [ ! -e "$HOME/.local/bin/node" ] || [ "$(readlink "$HOME/.local/bin/node" 2>/dev/null)" = "$NODE_HOME/bin/node" ]; then
    ln -sf "$NODE_HOME/bin/node" "$HOME/.local/bin/node"
  fi
  echo "Installed Node.js $("$NODE_HOME/bin/node" --version) to $NODE_HOME"
}
if [ -x "$NODE_HOME/bin/node" ] && node_ok "$NODE_HOME/bin/node"; then
  echo "Node.js ready: $("$NODE_HOME/bin/node" --version) ($NODE_HOME)"
elif command -v node >/dev/null 2>&1 && node_ok node; then
  echo "Node.js ready: $(node --version) ($(command -v node))"
else
  if command -v node >/dev/null 2>&1; then echo "Node.js $(node --version 2>/dev/null) is too old; Claude Mirror needs 18.14 or newer."; fi
  install_node || { echo 'Claude is installed. Claude Mirror additionally needs Node.js >=18.14 on the remote server.' >&2; exit 3; }
fi

# systemd-logind with KillUserProcesses=yes kills every process of an SSH login when it ends,
# including Claude Mirror's background sessions. A lingering user manager lets them survive.
echo '==> Background sessions'
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
else
  echo 'Background sessions keep running after SSH disconnects.'
fi
echo 'Ready. If Claude is not authenticated, SSH into this server and run: ~/.local/bin/claude auth login (or claude auth login for an existing PATH installation).'
echo 'Then connect to the same SSH host in Claude Mirror.'
