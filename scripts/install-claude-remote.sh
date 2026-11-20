#!/usr/bin/env bash
# Runs on the target server. Without options it never needs root and does not read or write Claude credentials.
# Claude Mirror runs it over its own SSH connection ("一键安装"); setup-remote.sh runs it from a terminal.
#
# Options for a server reached as root (Claude refuses Full Access as root):
#   --runner NAME    create the ordinary account NAME and install Claude Code for it
#   --project DIR    create DIR if needed and give the runner read/write access to it only
#   --copy-login     copy root's Claude login file to the runner instead of logging in again
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'This installer supports Linux, macOS and Linux under WSL.' >&2; exit 1 ;;
esac
runner=''; project=''; copy_login=no
usage() { echo "$1" >&2; echo 'Options: [--runner NAME [--project /absolute/dir] [--copy-login]]' >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runner) [ "$#" -ge 2 ] || usage '--runner needs an account name.'; runner=$2; shift 2 ;;
    --project) [ "$#" -ge 2 ] || usage '--project needs a directory.'; project=$2; shift 2 ;;
    --copy-login) copy_login=yes; shift ;;
    *) usage "Unknown option: $1" ;;
  esac
done
# Everything about the runner is checked before anything is installed.
if [ -n "$runner" ]; then
  [[ "$runner" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$runner" != root ] || usage "Invalid account name: $runner"
  [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || usage '--runner is for a root SSH login on Linux. An ordinary SSH user can already use Full Access.'
  command -v runuser >/dev/null 2>&1 || usage 'This server has no runuser (util-linux); connect as an ordinary user instead.'
  if getent passwd "$runner" >/dev/null && [ ! -f "/etc/claude-mirror/runners/$runner" ]; then
    usage "Account $runner already exists and was not created by this installer. Choose another name; existing accounts are never modified."
  fi
  if [ -n "$project" ]; then
    [[ "$project" = /* ]] || usage '--project must be an absolute path.'
    case "$(readlink -m -- "$project")" in
      /|/root|/root/*|/home|/etc|/etc/*|/usr|/usr/*|/var|/opt|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/tmp)
        usage "Refusing to open $project to the runner. Use a dedicated directory such as /opt/projects/my-app." ;;
    esac
  fi
  [ "$copy_login" = no ] || [ -s "$HOME/.claude/.credentials.json" ] || usage '--copy-login: root has no Claude login file (~/.claude/.credentials.json). Log in as root first, or drop the option.'
elif [ -n "$project" ] || [ "$copy_login" = yes ]; then
  usage '--project and --copy-login only apply together with --runner.'
fi
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
  elif loginctl enable-linger "$user" 2>/dev/null || { command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "$user" 2>/dev/null; }; then
    echo "Background sessions: enabled user lingering for $user, so replies continue after SSH disconnects."
  else
    echo "Warning: this server ends background sessions when SSH disconnects (KillUserProcesses=yes)." >&2
    echo "Ask an administrator to run: sudo loginctl enable-linger $user" >&2
  fi
else
  echo 'Background sessions keep running after SSH disconnects.'
fi

# Claude refuses Full Access as root. The runner is an ordinary account that Claude Mirror
# switches to with runuser; it gets its own Claude install and login, and only the project.
setup_runner() {
  local home source real parent
  if getent passwd "$runner" >/dev/null; then
    echo "Account $runner was created by an earlier run."
  else
    useradd --create-home --shell /bin/bash -- "$runner"
    mkdir -p /etc/claude-mirror/runners && : > "/etc/claude-mirror/runners/$runner"
    echo "Created account $runner."
  fi
  home=$(getent passwd "$runner" | cut -d: -f6)
  [ "$(id -u "$runner")" -gt 0 ] && [[ "$home" = /* ]] && [ "$home" != / ] && [ "$home" != /root ] || { echo "Account $runner is not usable." >&2; return 1; }
  # Files in the runner's home are written by the runner itself, never by root.
  as_runner() { runuser -u "$runner" -- env -i HOME="$home" PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

  if as_runner "$home/.local/bin/claude" --version >/dev/null 2>&1; then
    echo "Claude Code already installed for $runner."
  else
    source=$(readlink -f -- "$(command -v claude)")
    as_runner sh -c 'mkdir -p "$HOME/.local/bin" && cat > "$HOME/.local/bin/.claude-new" && chmod 755 "$HOME/.local/bin/.claude-new" && mv "$HOME/.local/bin/.claude-new" "$HOME/.local/bin/claude"' < "$source"
    as_runner "$home/.local/bin/claude" --version >/dev/null || { echo "The copied Claude Code does not run as $runner. Install it for that account: runuser -u $runner -- bash -c 'curl -fsSL https://claude.ai/install.sh | bash'" >&2; return 1; }
    echo "Installed Claude Code for $runner."
  fi

  if [ -n "$project" ]; then
    if ! command -v setfacl >/dev/null 2>&1; then
      echo 'Installing the acl package (setfacl)...'
      if command -v apt-get >/dev/null 2>&1; then { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q acl; } >/dev/null
      elif command -v dnf >/dev/null 2>&1; then dnf install -y -q acl >/dev/null
      elif command -v yum >/dev/null 2>&1; then yum install -y -q acl >/dev/null
      elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive --quiet install acl >/dev/null
      elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm --quiet acl >/dev/null
      fi
      command -v setfacl >/dev/null 2>&1 || { echo 'Install the acl package (setfacl) and run this again.' >&2; return 1; }
    fi
    mkdir -p -- "$project"
    real=$(readlink -f -- "$project")
    # Parents get traversal only; the project itself gets read/write, also for files created later.
    parent=$(dirname "$real")
    while [ "$parent" != / ]; do
      # A parent the runner can already enter is left alone: it may be an earlier project.
      as_runner test -x "$parent" || setfacl -m "u:$runner:--x" -- "$parent"
      parent=$(dirname "$parent")
    done
    setfacl -R -P -m "u:$runner:rwX" -- "$real"
    find "$real" -type d -exec setfacl -m "d:u:$runner:rwx" -- {} +
    as_runner sh -c 'cd -- "$1" && test -r . && test -w .' sh "$real" || { echo "$runner still cannot write to $real; the filesystem may not support ACLs." >&2; return 1; }
    echo "$runner can read and write $real."
  fi

  if as_runner test -s "$home/.claude/.credentials.json"; then
    echo "$runner is already logged in to Claude."
  elif [ "$copy_login" = yes ]; then
    # A new file, so an existing empty one cannot keep looser permissions.
    as_runner sh -c 'umask 077 && mkdir -p "$HOME/.claude" && cat > "$HOME/.claude/.credentials-new" && chmod 600 "$HOME/.claude/.credentials-new" && mv -f "$HOME/.claude/.credentials-new" "$HOME/.claude/.credentials.json"' < "$HOME/.claude/.credentials.json"
    echo "Copied root's Claude login file to $runner (that one file, mode 600)."
  else
    echo "Log in once as $runner:  runuser -u $runner -- $home/.local/bin/claude auth login"
  fi
  echo "In Claude Mirror, start a new conversation, choose Full Access and enter the execution account: $runner"
}
if [ -n "$runner" ]; then
  echo '==> Full Access account'
  setup_runner
fi
if [ -n "$runner" ]; then
  echo 'Ready. Connect to the same SSH host in Claude Mirror.'
else
  echo 'Ready. If Claude is not authenticated, SSH into this server and run: ~/.local/bin/claude auth login (or claude auth login for an existing PATH installation).'
  echo 'Then connect to the same SSH host in Claude Mirror.'
fi
