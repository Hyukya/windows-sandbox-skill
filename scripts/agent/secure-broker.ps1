# Runs as SYSTEM via the SbxSecure scheduled task (session 0). Starts secure-agent.ps1 in the
# interactive session (1) attached to winsta0\Winlogon so the helper can reach the secure desktop.
# Re-launches the helper if it is not alive, so the task's restart settings keep it running.
param([string]$Bridge = 'C:\Bridge')
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Dir = Join-Path $Bridge 'secure'
if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force $Dir | Out-Null }
$Log = Join-Path $Dir 'broker.log'
$Beat = Join-Path $Dir 'secure.status.json'
function Log([string]$m) { try { [IO.File]::AppendAllText($Log, ('{0:HH:mm:ss.fff} {1}{2}' -f (Get-Date), $m, "`r`n"), $Utf8) } catch {} }

$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'secure.cs'))
if (-not ('SbxSecure' -as [type])) { Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing }
Log "broker up as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) session $((Get-Process -Id $PID).SessionId)"

function Test-HelperAlive {
    # A read can collide with the helper replacing the file; retry before calling it dead, since a
    # false "dead" spawns a second helper.
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-Path $Beat)) { return $false }
        try { $s = [IO.File]::ReadAllText($Beat, $Utf8) | ConvertFrom-Json
            return (([DateTime]::UtcNow - [DateTime]::Parse($s.time).ToUniversalTime()).TotalSeconds -lt 10) } catch { Start-Sleep -Milliseconds 100 }
    }
    return $false
}

# The interactive sandbox session is 1 (WTSGetActiveConsoleSessionId returns -1 here).
$agent = Join-Path $PSScriptRoot 'secure-agent.ps1'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`" -Bridge `"$Bridge`""
while ($true) {
    if (-not (Test-HelperAlive)) {
        try { $pid2 = [SbxSecure]::StartInSession(1, 'Winlogon', $cmd); Log "spawned helper pid $pid2" }
        catch { Log "spawn failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 3
    }
    Start-Sleep -Seconds 2
}
