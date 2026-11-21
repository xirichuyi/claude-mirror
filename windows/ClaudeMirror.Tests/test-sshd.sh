#!/bin/sh
# Starts a throwaway sshd on 127.0.0.1 for SystemSshTests and prints the SSH config to use:
#   export CLAUDE_MIRROR_TEST_SSH_CONFIG="$(sh test-sshd.sh /tmp/mirror-sshd)"
# Hosts in that config: mirror-target (direct), mirror-jumped (through mirror-target with ProxyJump),
# mirror-unknown (host key not trusted). Stop it with: kill "$(cat <dir>/sshd.pid)"
set -eu
dir="${1:?folder for keys and config}"; port="${2:-2222}"
mkdir -p "$dir"; chmod 700 "$dir"; dir="$(cd "$dir" && pwd)"
[ -f "$dir/host_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$dir/host_key"
[ -f "$dir/client_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$dir/client_key"
cp "$dir/client_key.pub" "$dir/authorized_keys"; chmod 600 "$dir/authorized_keys"
cat > "$dir/sshd_config" <<CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
CONFIG
[ ! -f "$dir/sshd.pid" ] || kill "$(cat "$dir/sshd.pid")" 2>/dev/null || true
"$(command -v sshd)" -f "$dir/sshd_config" -E "$dir/sshd.log"
printf '[127.0.0.1]:%s %s\n' "$port" "$(cut -d' ' -f1,2 "$dir/host_key.pub")" > "$dir/known_hosts"
: > "$dir/empty_known_hosts"
cat > "$dir/ssh_config" <<CONFIG
Host mirror-target mirror-jumped mirror-unknown
  HostName 127.0.0.1
  Port $port
  User $(id -un)
  IdentityFile $dir/client_key
  IdentitiesOnly yes
  IdentityAgent none
Host mirror-target mirror-jumped
  UserKnownHostsFile $dir/known_hosts
Host mirror-unknown
  UserKnownHostsFile $dir/empty_known_hosts
  GlobalKnownHostsFile /dev/null
Host mirror-jumped
  ProxyJump mirror-target
CONFIG
echo "$dir/ssh_config"
