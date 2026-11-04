param(
    [string]$PublishDir = (Join-Path $PSScriptRoot 'dist/claude-mirror'),
    [string]$Version = '0.21.1',
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+(\.\d+){1,3}$') { throw "Invalid installer version: $Version" }
$payload = (Resolve-Path -LiteralPath $PublishDir).Path
foreach ($asset in 'claude-mirror.exe','claude-mirror.pri','App.xbf','server/manifest.json','server/remote-agent.cjs') {
    if (!(Test-Path -LiteralPath (Join-Path $payload $asset) -PathType Leaf)) { throw "Incomplete publish directory: missing $asset" }
}
$iscc = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (!$iscc) { throw 'Install Inno Setup 6 (winget install -e --id JRSoftware.InnoSetup).' }
$out = (New-Item -ItemType Directory -Force $OutputDir).FullName
& $iscc /Qp "/DAppVersion=$Version" "/DPayload=$payload" "/O$out" "$PSScriptRoot\installer\ClaudeMirror.iss"
if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed ($LASTEXITCODE)" }
$setup = Join-Path $out 'Claude-Mirror-Setup-x64.exe'
(Get-FileHash -Algorithm SHA256 $setup).Hash | Set-Content -Encoding ascii "$setup.sha256"
Write-Output $setup
