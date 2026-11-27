#!/usr/bin/env bash
# Runs on the target server. Without options it never needs root and does not read or write Claude credentials.
# Claude Mirror runs it over its own SSH connection ("一键安装"); setup-remote.sh runs it from a terminal.
#
# Options for a server reached as root (Claude refuses Full Access as root):
#   --runner NAME    create the ordinary account NAME and install Claude Code for it
#   --project DIR    create DIR if needed and give the runner read/write access to it only
#   --copy-login     copy root's Claude login file to the runner instead of logging in again
#
#   --node-only      only make sure Node.js is there; Claude Mirror runs this by itself when it connects
#
# Members of a shared server (root on Linux). Each one is an ordinary account with its own SSH key,
# Claude login, conversations and files; homes are private, so members cannot see each other.
#   --list-users                      print "member NAME FINGERPRINT" per member
#   --add-user NAME --key 'ssh-...'   create the account (or add the key to it) and install Claude Code
#   --remove-user NAME                delete the account and its home; only accounts added here
#   --invite NAME [--host ADDRESS]    create the member (or keep it) and print a one-use connection code
#                                     that is valid for 24 hours; the app pastes it in place of a manual setup
#   --claim 'ssh-...'                 run by the member: replace the invitation key with the app's own key
#
# Web panel (root on Linux with systemd), like the members page but in a browser:
#   --panel           install or update it; the first run prints its address, account and password
#   --panel-reset     print a new account name and password
#   --remove-panel    stop and delete it; members stay
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'This installer supports Linux, macOS and Linux under WSL.' >&2; exit 1 ;;
esac
runner=''; project=''; copy_login=no; node_only=no; members=''; member=''; key=''; invite_host=''; claim=''; panel=''
# Directories that are never opened to the runner.
protected() {
  case "$1" in
    /|/root|/root/*|/home|/etc|/etc/*|/usr|/usr/*|/var|/opt|/bin|/sbin|/lib|/lib64|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/tmp) return 0 ;;
  esac
  return 1
}
usage() { echo "$1" >&2; [ -n "${members:-}" ] || echo 'Options: [--runner NAME [--project /absolute/dir] [--copy-login]]' >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runner) [ "$#" -ge 2 ] || usage '--runner needs an account name.'; runner=$2; shift 2 ;;
    --project) [ "$#" -ge 2 ] || usage '--project needs a directory.'; project=$2; shift 2 ;;
    --copy-login) copy_login=yes; shift ;;
    --node-only) node_only=yes; shift ;;
    --list-users) members=list; shift ;;
    --add-user|--remove-user) [ "$#" -ge 2 ] || usage "$1 needs an account name."; members=${1#--}; members=${members%-user}; member=$2; shift 2 ;;
    --invite) [ "$#" -ge 2 ] || usage '--invite needs an account name.'; members=invite; member=$2; shift 2 ;;
    --key) [ "$#" -ge 2 ] || usage '--key needs a public key.'; key=$2; shift 2 ;;
    --host) [ "$#" -ge 2 ] || usage '--host needs an address.'; invite_host=$2; shift 2 ;;
    --claim) [ "$#" -ge 2 ] || usage '--claim needs a public key.'; claim=$2; shift 2 ;;
    --panel) panel=install; shift ;;
    --panel-reset) panel=reset; shift ;;
    --remove-panel) panel=remove; shift ;;
    *) usage "Unknown option: $1" ;;
  esac
done
if [ "$node_only" = yes ] && { [ -n "$runner$project" ] || [ "$copy_login" = yes ]; }; then usage '--node-only goes alone.'; fi
MEMBERS=/etc/claude-mirror/members
# A marker holds the uid it was created with, so an account recreated elsewhere under the same name is not managed.
managed() { [ -f "$MEMBERS/$1" ] && getent passwd "$1" >/dev/null && [ "$(cat -- "$MEMBERS/$1")" = "$(id -u -- "$1")" ]; }
[ -z "$key" ] || [ "$members" = add ] || usage '--key only goes with --add-user.'
[ -z "$invite_host" ] || [ "$members" = invite ] || usage '--host only goes with --invite.'
public_key() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*(\ [^[:cntrl:]]*)?$ ]] || return 1
  ! command -v ssh-keygen >/dev/null 2>&1 || ssh-keygen -lf /dev/stdin <<<"$1" >/dev/null 2>&1
}
# Adds a key to this account's authorized_keys; an invitation key replaces the previous one.
AUTHORIZE='umask 077 && mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" && f="$HOME/.ssh/authorized_keys" &&
  if [ "$2" = replace ]; then grep -v -- " claude-mirror-invite\$" "$f" > "$f.new" || true; mv -f "$f.new" "$f"; fi &&
  { grep -qxF -- "$1" "$f" || printf "%s\n" "$1" >> "$f"; } && chmod 700 "$HOME/.ssh" && chmod 600 "$f"'
if [ -n "$claim" ]; then
  [ -z "$members$panel$runner$project" ] && [ "$node_only" = no ] && [ "$copy_login" = no ] || usage '--claim goes alone.'
  public_key "$claim" && [[ "$claim" != *claude-mirror-invite* ]] || usage 'Not an SSH public key.'
  sh -c "$AUTHORIZE" sh "$claim" replace
  echo 'claimed'
  exit 0
fi
if [ -n "$panel" ]; then
  [ -z "$members$runner$project" ] && [ "$node_only" = no ] && [ "$copy_login" = no ] || usage 'Panel options go alone.'
  [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || usage 'The panel needs root on Linux.'
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || usage 'The panel needs systemd.'
fi
PANEL_LIB=/usr/local/lib/claude-mirror
PANEL_CONF=/etc/claude-mirror/panel
if [ "$panel" = remove ]; then
  systemctl disable --now claude-mirror-panel >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/claude-mirror-panel.service; systemctl daemon-reload
  rm -rf -- "$PANEL_LIB" "$PANEL_CONF"
  echo 'Removed the panel. Members are kept.'
  exit 0
fi
if [ -n "$members" ]; then
  [ "$node_only" = no ] && [ -z "$runner$project" ] && [ "$copy_login" = no ] || usage 'Member options go alone.'
  [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || usage 'Managing members needs a root SSH login on Linux.'
  command -v useradd >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || usage 'This server has no useradd or runuser.'
  if [ "$members" != list ]; then
    [[ "$member" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$member" != root ] || usage "Invalid account name: $member"
    if managed "$member"; then :
    elif [ "$members" = remove ]; then usage "$member is not a member added by Claude Mirror."
    elif getent passwd "$member" >/dev/null; then usage "Account $member already exists. Choose another name; existing accounts are never modified."
    fi
  fi
  if [ "$members" = add ]; then
    public_key "$key" || usage 'Not an SSH public key.'
  fi
  if [ "$members" = invite ]; then
    command -v ssh-keygen >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || usage 'This server has no ssh-keygen or base64.'
    [ -z "$invite_host" ] || [[ "$invite_host" =~ ^[A-Za-z0-9._:-]{1,253}$ ]] || usage "Invalid address: $invite_host"
  fi
fi
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
    protected "$(readlink -m -- "$project")" && usage "Refusing to open $project to the runner. Use a dedicated directory such as /opt/projects/my-app."
  fi
  [ "$copy_login" = no ] || [ -s "$HOME/.claude/.credentials.json" ] || usage '--copy-login: root has no Claude login file (~/.claude/.credentials.json). Log in as root first, or drop the option.'
elif [ -n "$project" ] || [ "$copy_login" = yes ]; then
  usage '--project and --copy-login only apply together with --runner.'
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
download() {
  if command -v curl >/dev/null 2>&1; then
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 300 "$1" -o "$2"
  else
    # BusyBox wget has neither option; the pinned checksum still guards what it fetches.
    if wget --help 2>&1 | grep -q -- --https-only; then wget --quiet --https-only --tries=2 --timeout=20 -O "$2" "$1"
    else wget -q -T 20 -O "$2" "$1"; fi
  fi
}

member_home() { getent passwd "$1" | cut -d: -f6; }
as_member() { local home; home=$(member_home "$member"); runuser -u "$member" -- env -i HOME="$home" PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
list_members() {
  local marker name fingerprint
  for marker in "$MEMBERS"/*; do
    [ -f "$marker" ] || continue
    name=${marker##*/}
    managed "$name" || continue
    fingerprint=$({ ssh-keygen -lf "$(member_home "$name")/.ssh/authorized_keys" 2>/dev/null || true; } | awk 'NR==1{print $2}')
    echo "member $name ${fingerprint:--}"
  done
}
usable_home() { local home; home=$(member_home "$member"); [ "$(id -u "$member")" -gt 0 ] && [[ "$home" = /?*/* ]] && ! protected "$home"; }
add_member() {
  local home source dir
  if getent passwd "$member" >/dev/null; then echo "Adding the key to $member."
  else
    useradd --create-home --shell /bin/bash -- "$member"
    mkdir -p "$MEMBERS" && id -u -- "$member" > "$MEMBERS/$member"
    echo "Created account $member."
  fi
  usable_home || { echo "Account $member is not usable." >&2; return 1; }
  home=$(member_home "$member")
  chmod 700 -- "$home"
  # Written by the member itself, never by root.
  as_member sh -c "$AUTHORIZE" sh "$key" "${1:-}"
  if as_member "$home/.local/bin/claude" --version >/dev/null 2>&1; then :
  elif command -v claude >/dev/null 2>&1 && source=$(readlink -f -- "$(command -v claude)") &&
    as_member sh -c 'mkdir -p "$HOME/.local/bin" && cat > "$HOME/.local/bin/.claude-new" && chmod 755 "$HOME/.local/bin/.claude-new" && mv "$HOME/.local/bin/.claude-new" "$HOME/.local/bin/claude"' < "$source" &&
    as_member "$home/.local/bin/claude" --version >/dev/null 2>&1; then echo "Installed Claude Code for $member."
  elif { command -v curl || command -v wget; } >/dev/null 2>&1 && download https://claude.ai/install.sh "$work/claude-install.sh" && as_member bash -s -- stable < "$work/claude-install.sh" >/dev/null; then
    echo "Installed Claude Code for $member."
  else echo "Claude Code is not installed for $member; they can install it from the app." >&2
  fi
  if command -v loginctl >/dev/null 2>&1 && [ "$(loginctl show-session -p KillUserProcesses --value 2>/dev/null)" = yes ]; then
    loginctl enable-linger "$member" 2>/dev/null || true
  fi
  for dir in /home/*/; do
    dir=${dir%/}
    [ "$dir" = "$home" ] || [ "$(( $(stat -c %a -- "$dir") % 10 ))" = 0 ] || echo "Readable by members: $dir (chmod 700 $dir)"
  done
  echo "Ready. $member connects as $member@$(hostname) and logs in to Claude in the app."
}
remove_member() {
  usable_home || { echo "Account $member is not usable." >&2; return 1; }
  local uid; uid=$(id -u -- "$member")
  loginctl terminate-user "$member" 2>/dev/null || true
  pkill -KILL -u "$member" 2>/dev/null || true
  loginctl disable-linger "$member" 2>/dev/null || true
  local tries=0
  until userdel -r -- "$member" 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -lt 5 ] || { echo "Could not remove $member." >&2; return 1; }
    pkill -KILL -u "$member" 2>/dev/null || true; sleep 1
  done
  # Outside the home; a later account reusing the uid would own it.
  rm -rf -- "/tmp/claudock-attachments-$uid"
  rm -f -- "$MEMBERS/$member"
  echo "Removed $member and their files."
}
# The code carries everything the app needs: address, port, account, the server's host keys and
# a fresh key that sshd accepts for 24 hours. The app swaps it for its own key on first connect.
invite_member() {
  local host port stamp version line payload file
  ssh-keygen -q -t ed25519 -N '' -C claude-mirror-invite -f "$work/invite" >/dev/null
  line=$(cat "$work/invite.pub")
  version=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
  # expiry-time needs OpenSSH 8.2; an older sshd would ignore the whole line.
  if [ -n "$version" ] && [ "${version% *}" -gt 8 -o \( "${version% *}" -eq 8 -a "${version#* }" -ge 2 \) ]; then
    stamp=$(date -d '+24 hours' +%Y%m%d%H%M 2>/dev/null || date -v+24H +%Y%m%d%H%M)
    line="expiry-time=\"$stamp\" $line"
  else echo 'This sshd is older than OpenSSH 8.2: the code does not expire, it only stops working once used.' >&2
  fi
  key=$line; add_member replace >&2
  host=$invite_host
  [ -n "$host" ] || host=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$host" ] || host=$(hostname)
  port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
  [ -n "$port" ] || port=$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
  payload="claude-mirror 1"$'\n'"name $(hostname)"$'\n'"host $host"$'\n'"port ${port:-22}"$'\n'"user $member"
  # Every client checks Ed25519, which keeps the code short; other key types only stand in for it.
  for file in /etc/ssh/ssh_host_ed25519_key.pub; do [ -f "$file" ] || file=/etc/ssh/ssh_host_*_key.pub; done
  for file in $file; do
    [ -f "$file" ] && payload+=$'\n'"hostkey $(awk '{print $1" "$2}' "$file")"
  done
  payload+=$'\n'"$(cat "$work/invite")"
  echo "Connection code for $member (one use, 24 hours):" >&2
  echo "invite cm1.$(printf '%s\n' "$payload" | base64 | tr -d '\n=' | tr '+/' '-_')"
}
case "$members" in
  list) list_members; exit 0 ;;
  add) add_member; exit ;;
  invite) invite_member; exit ;;
  remove) remove_member; exit ;;
esac

if [ "$node_only" = yes ] || [ -n "$panel" ]; then :
else
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
fi

# Node.js runs Claude Mirror's remote agent. A missing or outdated system Node is not replaced:
# an official build goes into ~/.local/share/claude-mirror/node, which the app prefers.
echo '==> Node.js'
NODE_HOME="$HOME/.local/share/claude-mirror/node"
node_ok() { "$1" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>18||(a===18&&b>=14)?0:1)' >/dev/null 2>&1; }
# Pinned, so a mirror can only hand over these exact files.
NODE_VERSION=v22.23.5
node_sum() {
  case "$1" in
    linux-x64) echo c54118104acc524633b5abe106bbf44a53126ec8b4e5fa105cb92b5d7de8a1a1 ;;
    linux-arm64) echo 8bd3dc69eee8f3f226315a80d7d1d4faccf217a4c8fae500168ac2e38f3bdba3 ;;
    linux-x64-musl) echo 5916fad10a05e47f2dcbd70f993a03967ffd51330f40415ec8afdd9928dc10be ;;
    linux-arm64-musl) echo 51c72e3a1385b10d4c862a40c845fc7bea5b19e30c7e109dbdcc2077c55e39bb ;;
    linux-x64-glibc-217) echo 3422012451c9450b353e49bfa3b8b2b92684957316dde2961b13f433ba8f91a5 ;;
    darwin-x64) echo c53383238206b9ae4db23c5d8a63645e2e753bec8ab51a49cc81939aa64e9422 ;;
    darwin-arm64) echo e7131995759b61a0170b646010d2ad35a5d37b4cb0d471f3e8317eac6f742f3d ;;
  esac
}
install_node() {
  local os arch platform glibc mirrors base line name expected actual
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "No Node.js build for $(uname -m); install Node.js 18.14 or newer with the system package manager." >&2; return 1 ;;
  esac
  platform="$os-$arch"
  mirrors="https://nodejs.org/dist/$NODE_VERSION https://npmmirror.com/mirrors/node/$NODE_VERSION"
  if [ "$os" = linux ]; then
    glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    # Alpine and other musl systems, and glibc older than 2.28 (CentOS 7), take the unofficial builds.
    if { ldd --version 2>&1 || true; } | grep -qi musl; then platform="$platform-musl"
    elif [ -n "$glibc" ] && [ "$(printf '%s\n2.28\n' "$glibc" | sort -V | head -1)" != 2.28 ]; then
      [ "$arch" = x64 ] || { echo "glibc $glibc is too old for Node.js on $arch. Install Node.js 18.14+ from the system's packages." >&2; return 1; }
      platform="$platform-glibc-217"
    fi
    [ "$platform" = "$os-$arch" ] || mirrors="https://unofficial-builds.nodejs.org/download/release/$NODE_VERSION"
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { echo 'Install curl or wget on the remote server first.' >&2; return 1; }
  name="node-$NODE_VERSION-$platform.tar.gz"; expected=$(node_sum "$platform")
  if [ -n "${CLAUDE_MIRROR_NODE_DIST:-}" ]; then
    # The checksum list comes from the same mirror, so only an HTTPS-only download can be trusted.
    command -v curl >/dev/null 2>&1 || wget --help 2>&1 | grep -q -- --https-only ||
      { echo 'CLAUDE_MIRROR_NODE_DIST needs curl or GNU wget.' >&2; return 1; }
    mirrors=$CLAUDE_MIRROR_NODE_DIST
    download "$mirrors/SHASUMS256.txt" "$work/SHASUMS256.txt"
    line=$(grep -E "  node-v[0-9.]+-$platform\.tar\.gz\$" "$work/SHASUMS256.txt" | head -1)
    [ -n "$line" ] || { echo "Node.js download list has no $platform build." >&2; return 1; }
    expected=${line%% *}; name=${line##* }
  fi
  actual=''
  for base in $mirrors; do
    line=${base#https://}; echo "Downloading $name from ${line%%/*}..."
    download "$base/$name" "$work/$name" || continue
    if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$work/$name" | awk '{print $1}')
    else actual=$(shasum -a 256 "$work/$name" | awk '{print $1}'); fi
    [ "$actual" = "$expected" ] && break
  done
  [ -n "$actual" ] || { echo 'Could not download Node.js.' >&2; return 1; }
  [ "$actual" = "$expected" ] || { echo 'Node.js download failed its checksum; nothing was installed.' >&2; return 1; }
  mkdir -p "$work/node" "$(dirname "$NODE_HOME")" "$HOME/.local/bin"
  tar -xzf "$work/$name" -C "$work/node" --strip-components 1 || { echo 'Could not unpack Node.js (needs tar and gzip).' >&2; return 1; }
  # The musl builds link libstdc++, which stock Alpine does not have.
  if ! node_ok "$work/node/bin/node" && [ "${platform%-musl}" != "$platform" ]; then
    if [ "$(id -u)" = 0 ] && command -v apk >/dev/null 2>&1; then apk add --no-cache -q libstdc++ >/dev/null || true
    else echo 'Node.js needs libstdc++: run apk add libstdc++ as root.' >&2; fi
  fi
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
# --node-only runs because the app's own search found no usable node; another one on PATH would not help.
elif [ "$node_only" = no ] && command -v node >/dev/null 2>&1 && node_ok node; then
  echo "Node.js ready: $(node --version) ($(command -v node))"
else
  if command -v node >/dev/null 2>&1 && ! node_ok node; then echo "Node.js $(node --version 2>/dev/null) is too old; Claude Mirror needs 18.14 or newer."; fi
  install_node || { echo 'Claude Mirror needs Node.js >=18.14 on the remote server.' >&2; exit 3; }
fi
[ "$node_only" = no ] || exit 0

# Pinned to the release this script came from; a checkout or test points CLAUDE_MIRROR_PANEL_SOURCE at a folder.
PANEL_RELEASE=latest
install_panel() {
  local node source url ip port path account cert
  if [ -x "$NODE_HOME/bin/node" ] && node_ok "$NODE_HOME/bin/node"; then node=$NODE_HOME/bin/node; else node=$(command -v node); fi
  command -v openssl >/dev/null 2>&1 || { echo 'The panel needs openssl for its HTTPS certificate.' >&2; return 1; }
  mkdir -p "$work/panel"
  if [ -n "${CLAUDE_MIRROR_PANEL_SOURCE:-}" ]; then
    cp -- "$CLAUDE_MIRROR_PANEL_SOURCE/claude-mirror-panel.cjs" "$CLAUDE_MIRROR_PANEL_SOURCE/install-claude-remote.sh" "$work/panel/"
  else
    if [ "$PANEL_RELEASE" = latest ]; then url=https://github.com/xirichuyi/claude-mirror/releases/latest/download
    else url=https://github.com/xirichuyi/claude-mirror/releases/download/$PANEL_RELEASE; fi
    echo 'Downloading the panel...'
    for source in claude-mirror-panel.cjs install-claude-remote.sh; do
      download "$url/$source" "$work/panel/$source" || { echo "Could not download $source." >&2; return 1; }
    done
  fi
  install -d -m 755 "$PANEL_LIB"
  install -m 644 "$work/panel/claude-mirror-panel.cjs" "$PANEL_LIB/claude-mirror-panel.cjs"
  install -m 755 "$work/panel/install-claude-remote.sh" "$PANEL_LIB/install-claude-remote.sh"
  install -d -m 700 /etc/claude-mirror "$PANEL_CONF"
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ ! -s "$PANEL_CONF/cert.pem" ]; then
    # Self-signed: the browser warns once; the fingerprint below tells it is this server.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj '/CN=Claude Mirror' \
      ${ip:+-addext "subjectAltName=IP:$ip"} -keyout "$PANEL_CONF/key.pem" -out "$PANEL_CONF/cert.pem" >/dev/null 2>&1 ||
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=Claude Mirror' -keyout "$PANEL_CONF/key.pem" -out "$PANEL_CONF/cert.pem" >/dev/null 2>&1 ||
      { echo 'Could not create the HTTPS certificate.' >&2; return 1; }
    chmod 600 "$PANEL_CONF/key.pem"
  fi
  if [ "$panel" = reset ]; then account=$("$node" "$PANEL_LIB/claude-mirror-panel.cjs" reset "$PANEL_CONF")
  else account=$("$node" "$PANEL_LIB/claude-mirror-panel.cjs" init "$PANEL_CONF"); fi
  read -r port path < <("$node" "$PANEL_LIB/claude-mirror-panel.cjs" address "$PANEL_CONF")
  cat > /etc/systemd/system/claude-mirror-panel.service <<UNIT
[Unit]
Description=Claude Mirror panel
After=network-online.target

[Service]
ExecStart=$node $PANEL_LIB/claude-mirror-panel.cjs serve $PANEL_CONF
Environment=CLAUDE_MIRROR_SCRIPT=$PANEL_LIB/install-claude-remote.sh
Restart=on-failure
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable claude-mirror-panel >/dev/null 2>&1
  systemctl restart claude-mirror-panel
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$port/tcp" >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --quiet --permanent --add-port="$port/tcp" && firewall-cmd --quiet --reload
  fi
  cert=$(openssl x509 -noout -fingerprint -sha256 -in "$PANEL_CONF/cert.pem" | cut -d= -f2)
  echo "Panel: https://${ip:-SERVER}:$port/$path/"
  [ -z "$account" ] || printf '%s\n' "$account"
  echo "Certificate SHA-256: $cert"
  echo 'Open the port in the cloud provider firewall if the page does not load.'
}
if [ -n "$panel" ]; then install_panel; exit; fi

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

# A large JPEG or WebP previews from a small copy made on the server, which needs one image tool.
# PNG needs none. Installing it is a convenience: without it previews download the original.
if python3 -c 'import PIL' 2>/dev/null || command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || command -v ffmpeg >/dev/null 2>&1; then :
elif [ "$(id -u)" -eq 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-pil; } >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q python3-pillow >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then yum install -y -q python3-pillow >/dev/null 2>&1 || true
  fi
  python3 -c 'import PIL' 2>/dev/null && echo 'Image previews: installed Pillow.' || echo 'Image previews: JPEG and WebP load in full. Install python3-pil, ImageMagick or ffmpeg for faster previews.'
else
  echo 'Image previews: JPEG and WebP load in full. Install python3-pil, ImageMagick or ffmpeg for faster previews.'
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
    # Enter the directory and work on "." from here on: a path could be swapped for a
    # link to somewhere else after it was checked, the directory we are in cannot.
    cd -- "$project"
    real=$(pwd -P)
    if protected "$real"; then echo "Refusing to open $real to the runner." >&2; return 1; fi
    # Parents get traversal only; the project itself gets read/write, also for files created later.
    parent=$(dirname "$real")
    while [ "$parent" != / ]; do
      # A parent the runner can already enter is left alone: it may be an earlier project.
      as_runner test -x "$parent" || setfacl -m "u:$runner:--x" -- "$parent"
      parent=$(dirname "$parent")
    done
    setfacl -R -P -m "u:$runner:rwX" -- .
    find . -type d -exec setfacl -m "d:u:$runner:rwx" -- {} +
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
