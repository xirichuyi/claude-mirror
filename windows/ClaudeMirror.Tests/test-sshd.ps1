# Starts a throwaway sshd on 127.0.0.1 for SystemSshTests on Windows and prints the SSH config to use:
#   $env:CLAUDE_MIRROR_TEST_SSH_CONFIG = ./test-sshd.ps1 C:\temp\mirror-sshd
# It serves the same hosts as test-sshd.sh. Commands run in Git's bash, so the tests can use cat and sleep.
# Needs an elevated shell: it sets the OpenSSH default shell for this machine.
param([Parameter(Mandatory)][string]$Directory, [int]$Port = 2222)
$ErrorActionPreference = 'Stop'
$openssh = Join-Path $env:SystemRoot 'System32\OpenSSH'
if (!(Test-Path "$openssh\sshd.exe")) { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null }
$null = New-Item -ItemType Directory -Force $Directory
$dir = (Resolve-Path $Directory).Path -replace '\\', '/'
foreach ($key in 'host_key', 'client_key') {
    if (!(Test-Path "$dir/$key")) { & "$openssh\ssh-keygen.exe" -q -t ed25519 -N '' -f "$dir/$key"; if ($LASTEXITCODE) { throw "ssh-keygen failed for $key" } }
    # OpenSSH refuses a private key other accounts can read.
    $null = icacls "$dir/$key" /inheritance:r /grant:r "${env:USERNAME}:F"
}
Copy-Item "$dir/client_key.pub" "$dir/authorized_keys" -Force
$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if (!(Test-Path $bash)) { throw 'Git for Windows is needed for the remote shell' }
$null = New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $bash
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -Value '-c'
@"
Port $Port
ListenAddress 127.0.0.1
HostKey $dir/host_key
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
StrictModes no
AllowTcpForwarding yes
"@ | Set-Content "$dir/sshd_config" -Encoding ascii
$server = Start-Process "$openssh\sshd.exe" -ArgumentList '-f', "$dir/sshd_config", '-E', "$dir/sshd.log" -WindowStyle Hidden -PassThru
$server.Id | Set-Content "$dir/sshd.pid"
$public = (Get-Content "$dir/host_key.pub").Split(' ')[0..1] -join ' '
"[127.0.0.1]:$Port $public" | Set-Content "$dir/known_hosts" -Encoding ascii
'' | Set-Content "$dir/empty_known_hosts" -Encoding ascii
@"
Host mirror-target mirror-jumped mirror-unknown
  HostName 127.0.0.1
  Port $Port
  User $env:USERNAME
  IdentityFile $dir/client_key
  IdentitiesOnly yes
  IdentityAgent none
Host mirror-target mirror-jumped
  UserKnownHostsFile $dir/known_hosts
Host mirror-unknown
  UserKnownHostsFile $dir/empty_known_hosts
  GlobalKnownHostsFile $dir/empty_known_hosts
Host mirror-jumped
  ProxyJump mirror-target
"@ | Set-Content "$dir/ssh_config" -Encoding ascii
# Wait until the server answers, so a failure shows here with the server's log rather than in a test.
$deadline = [DateTime]::UtcNow.AddSeconds(20)
do {
    $answer = & "$openssh\ssh.exe" -F "$dir/ssh_config" -o BatchMode=yes mirror-target 'echo ready' 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Milliseconds 500
} while ([DateTime]::UtcNow -lt $deadline)
if ($LASTEXITCODE -ne 0) {
    Write-Host "ssh said: $answer"; if (Test-Path "$dir/sshd.log") { Get-Content "$dir/sshd.log" | Write-Host }
    throw 'The test sshd did not accept a login'
}
"$dir/ssh_config"
