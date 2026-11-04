param([Parameter(Mandatory)][string]$Executable)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
$process = Start-Process -FilePath (Resolve-Path $Executable) -PassThru
function Find-Control([string]$name) {
    $process.Refresh()
    if ($process.HasExited) { throw "Client exited with code $($process.ExitCode)" }
    if ($process.MainWindowHandle -eq 0) { return }
    $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}
function Wait-Control([string]$name, [bool]$visible = $true) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $control = Find-Control $name
        if ([bool]$control -eq $visible) { return $control }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for '$name' (expected visible: $visible)"
}
try {
    foreach ($button in @('添加主机', '连接')) {
        (Wait-Control $button).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        (Wait-Control '取消').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-Control '取消' $false
    }
    Write-Output 'Both SSH setup buttons opened and dismissed their dialog.'
} finally {
    if (!$process.HasExited) {
        $null = $process.CloseMainWindow()
        if (!$process.WaitForExit(5000)) { $process.Kill() }
    }
}
