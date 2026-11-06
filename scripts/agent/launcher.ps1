# Started by the sandbox LogonCommand. Keeps agent.ps1 alive:
#   agent exit 0  -> restart (picks up updated agent files)
#   agent exit 99 -> stop
param([string]$Bridge = 'C:\Bridge')
$agent = Join-Path $PSScriptRoot 'agent.ps1'
$log = Join-Path $Bridge 'logs\launcher.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
while ($true) {
    Add-Content -Path $log -Value ("{0:s} starting agent" -f (Get-Date))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $agent -Bridge $Bridge
    $code = $LASTEXITCODE
    Add-Content -Path $log -Value ("{0:s} agent exited code={1}" -f (Get-Date), $code)
    if ($code -eq 99) { break }
    Start-Sleep -Seconds 1
}
