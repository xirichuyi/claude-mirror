param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$Output)

# Renders every demo scene of the published client to a PNG, in light and dark.
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Executable).Path
$folder = (New-Item -ItemType Directory -Force $Output).FullName
$shots = @(
    @{ Name = 'home'; Scene = 'home' },
    @{ Name = 'chat'; Scene = 'chat' },
    @{ Name = 'chat-top'; Scene = 'chat'; Scroll = '0' },
    @{ Name = 'chat-narrow'; Scene = 'chat'; Size = '760x820' }
)
try {
    foreach ($shot in $shots) {
        foreach ($theme in 'light', 'dark') {
            $png = Join-Path $folder "$($shot.Name)-$theme.png"
            $env:CLAUDE_MIRROR_DEMO = $shot.Scene
            $env:CLAUDE_MIRROR_THEME = $theme
            $env:CLAUDE_MIRROR_SIZE = if ($shot.Size) { $shot.Size } else { '1280x860' }
            $env:CLAUDE_MIRROR_SCROLL = $shot.Scroll
            $env:CLAUDE_MIRROR_SNAPSHOT = $png
            $app = Start-Process -FilePath $exe -PassThru
            if (-not $app.WaitForExit(60000)) { $app.Kill(); throw "Timed out rendering $($shot.Name)-$theme" }
            if (-not (Test-Path $png)) {
                $reason = if (Test-Path "$png.error.txt") { Get-Content "$png.error.txt" -Raw } else { "exit code $($app.ExitCode)" }
                throw "No screenshot for $($shot.Name)-${theme}: $reason"
            }
            Write-Output "$($shot.Name)-$theme.png"
        }
    }
} finally {
    foreach ($name in 'DEMO', 'THEME', 'SIZE', 'SCROLL', 'SNAPSHOT') { Remove-Item "Env:CLAUDE_MIRROR_$name" -ErrorAction SilentlyContinue }
}
