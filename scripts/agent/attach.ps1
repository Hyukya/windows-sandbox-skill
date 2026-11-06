# Run by `sbx.ps1 attach` through `wsb exec -r ExistingLogin` in a sandbox that was not started by sbx.ps1.
# `wsb exec` waits for its command to exit, so start the launcher detached and return at once.
# If a launcher is already running (e.g. a second attach), do nothing: two agents must never share one inbox.
param([string]$Bridge = 'C:\Bridge')
$log = Join-Path $Bridge 'logs\launcher.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
$running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*launcher.ps1*' })
if ($running.Count -gt 0) {
    Add-Content -Path $log -Value ("{0:s} attach: launcher already running (pid {1})" -f (Get-Date), ($running.ProcessId -join ','))
    exit 0
}
$launcher = Join-Path $PSScriptRoot 'launcher.ps1'
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`" -Bridge `"$Bridge`""
Add-Content -Path $log -Value ("{0:s} attach: launcher started" -f (Get-Date))
exit 0
