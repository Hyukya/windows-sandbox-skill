# Host-side controller for Windows Sandbox.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File sbx.ps1 <action> [-name value]... [-flag]
# Host actions : check, start, stop, status, push, pull, update-agent, logs, call
# Agent actions: anything else is forwarded to the in-sandbox agent (see references/actions.md)
# Output: one JSON object on stdout. Exit code 0 = ok, 1 = error.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Utf8 = New-Object System.Text.UTF8Encoding $false

$SkillDir = Split-Path -Parent $PSScriptRoot
$AgentSrc = Join-Path $PSScriptRoot 'agent'
# NOTE: keep the bridge OUTSIDE %APPDATA%/%LOCALAPPDATA%. Packaged (MSIX) apps such as the Claude desktop app
# get AppData writes redirected into their package LocalCache, so the sandbox would map an empty/nonexistent
# folder and fail with 0x80070003 "path not found".
$Bridge = if ($env:SBX_BRIDGE) { $env:SBX_BRIDGE } else { Join-Path $env:USERPROFILE 'WinSandboxBridge' }
$SandboxBridge = 'C:\Bridge'
$StatusFile = Join-Path $Bridge 'status.json'

function Out-Json($obj, [int]$code = 0) {
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 14))
    exit $code
}
function Fail([string]$msg, $extra = $null) {
    $o = [ordered]@{ ok = $false; error = $msg }
    if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
    Out-Json $o 1
}

# ---------------------------------------------------------------- arg parsing
$Action = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$Params = [ordered]@{}
$Positional = @()
for ($i = 1; $i -lt $args.Count; $i++) {
    $t = [string]$args[$i]
    if ($t -match '^-{1,2}([A-Za-z_][\w]*)=(.*)$') { $Params[$Matches[1]] = $Matches[2]; continue }   # -name=value
    if ($t -match '^-{1,2}([A-Za-z_][\w]*)$') {
        $name = $Matches[1]
        $next = if ($i + 1 -lt $args.Count) { [string]$args[$i + 1] } else { $null }
        # next token is a flag only if it is exactly "-word"; values like "-5" or "-NoProfile -File x" are values
        if ($null -eq $next -or ($next -match '^-{1,2}[A-Za-z_][\w]*(=.*)?$')) { $Params[$name] = $true }
        else { $Params[$name] = $args[$i + 1]; $i++ }
    } else { $Positional += $args[$i] }
}
function Convert-Value($v) {
    if ($v -is [string]) {
        if ($v -match '^-?\d+$') { return [int64]$v }
        if ($v -match '^-?\d+\.\d+$') { return [double]$v }
        if ($v -eq 'true') { return $true }; if ($v -eq 'false') { return $false }
    }
    return $v
}
# -paramsJson / -paramsFile merge raw JSON; -xxxFile reads text into xxx (textFile, commandFile, valueFile)
if ($Params.Contains('paramsJson')) { ($Params.paramsJson | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $Params[$_.Name] = $_.Value }; $Params.Remove('paramsJson') }
if ($Params.Contains('paramsFile')) { ([IO.File]::ReadAllText($Params.paramsFile, $Utf8) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $Params[$_.Name] = $_.Value }; $Params.Remove('paramsFile') }
foreach ($k in @($Params.Keys)) {
    if ($k -in 'textFile', 'commandFile', 'valueFile') { $Params[$k -replace 'File$', ''] = [IO.File]::ReadAllText([string]$Params[$k], $Utf8); $Params.Remove($k) }
}
$StringKeys = 'text', 'command', 'value', 'title', 'name', 'keys', 'path', 'src', 'dst', 'cwd', 'id', 'process', 'class', 'type', 'args', 'modifiers'
foreach ($k in @($Params.Keys)) { if ($k -notin $StringKeys) { $Params[$k] = Convert-Value $Params[$k] } }

function Get-Param([string]$name, $default = $null) { if ($Params.Contains($name)) { return $Params[$name] }; return $default }

# ---------------------------------------------------------------- helpers
function Get-Status {
    if (-not (Test-Path $StatusFile)) { return $null }
    try {
        $s = [IO.File]::ReadAllText($StatusFile, $Utf8) | ConvertFrom-Json
        $age = ([DateTime]::UtcNow - [DateTime]::Parse($s.utc).ToUniversalTime()).TotalSeconds
        $s | Add-Member -NotePropertyName ageSeconds -NotePropertyValue ([math]::Round($age, 1)) -Force
        return $s
    } catch { return $null }
}
function Get-SandboxProcs { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'WindowsSandbox*' -or $_.ProcessName -eq 'vmmemWindowsSandbox' }) }
function Test-AgentAlive([double]$maxAge = 15) { $s = Get-Status; return ($null -ne $s -and $s.state -ne 'stopped' -and $s.ageSeconds -lt $maxAge) }

function Initialize-Bridge {
    foreach ($d in 'inbox', 'outbox', 'shots', 'files', 'jobs', 'logs', 'agent') { New-Item -ItemType Directory -Force (Join-Path $Bridge $d) | Out-Null }
    Copy-Item -Path (Join-Path $AgentSrc '*') -Destination (Join-Path $Bridge 'agent') -Force
}

function Send-Request([string]$action, $params, [double]$waitSec = 0) {
    if (-not (Test-AgentAlive) -and -not (Get-Param 'force' $false)) {
        $s = Get-Status
        Fail "Sandbox agent is not running (no fresh heartbeat). Run: sbx.ps1 start" @{ lastStatus = $s; sandboxProcesses = @(Get-SandboxProcs | ForEach-Object { $_.ProcessName }) }
    }
    $id = '{0:yyyyMMddHHmmssfff}_{1}' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $req = [ordered]@{ id = $id; action = $action; params = $params }
    $inbox = Join-Path $Bridge 'inbox'; $out = Join-Path $Bridge "outbox\$id.json"
    $tmp = Join-Path $inbox "$id.tmp"
    [IO.File]::WriteAllText($tmp, ($req | ConvertTo-Json -Depth 12 -Compress), $Utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $inbox "$id.json") -Force
    if ($waitSec -le 0) {
        $t = 0; if ($params.Contains('timeout')) { $t = [double]$params['timeout'] }
        $waitSec = [Math]::Max(60, $t + 30)
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $waitSec) {
        if (Test-Path -LiteralPath $out) {
            Start-Sleep -Milliseconds 20
            try { $txt = [IO.File]::ReadAllText($out, $Utf8) } catch { Start-Sleep -Milliseconds 50; continue }
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            return ($txt | ConvertFrom-Json)
        }
        if ($sw.Elapsed.TotalSeconds -gt 10 -and -not (Test-AgentAlive 20)) {
            Fail "Agent stopped responding while handling '$action' (heartbeat stale)." @{ id = $id }
        }
        Start-Sleep -Milliseconds 50
    }
    Fail "Timed out after $waitSec s waiting for agent response to '$action'. The request may still run; see logs." @{ id = $id }
}

function Add-HostPaths($resp) {
    # translate bridge-relative file paths (shots/x.png) to host paths so the host can open them
    if ($resp.ok -and $resp.result -and ($resp.result.PSObject.Properties.Name -contains 'file')) {
        $resp.result | Add-Member -NotePropertyName hostPath -NotePropertyValue (Join-Path $Bridge ($resp.result.file -replace '/', '\')) -Force
    }
    return $resp
}

function New-WsbConfig {
    $net = if (Get-Param 'noNetwork' $false) { 'Disable' } else { 'Enable' }
    $gpu = if (Get-Param 'vgpu' $false) { 'Enable' } else { 'Disable' }
    $mem = [int](Get-Param 'memory' 4096)
    $clip = if (Get-Param 'noClipboard' $false) { 'Disable' } else { 'Enable' }
    $maps = New-Object System.Text.StringBuilder
    [void]$maps.AppendLine("    <MappedFolder><HostFolder>$([Security.SecurityElement]::Escape($Bridge))</HostFolder><SandboxFolder>$SandboxBridge</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>")
    # -map "C:\host\dir" or "C:\host\dir=C:\in\sandbox" or "...;ro" ; multiple separated by '|'
    $mapArg = [string](Get-Param 'map' '')
    foreach ($m in ($mapArg -split '\|' | Where-Object { $_ })) {
        $ro = 'false'; if ($m -match ';ro$') { $ro = 'true'; $m = $m -replace ';ro$', '' }
        $parts = $m -split '=', 2
        $hostDir = (Resolve-Path -LiteralPath $parts[0]).Path
        $sbDir = if ($parts.Count -gt 1) { $parts[1] } else { 'C:\Users\WDAGUtilityAccount\Desktop\' + (Split-Path -Leaf $hostDir) }
        [void]$maps.AppendLine("    <MappedFolder><HostFolder>$([Security.SecurityElement]::Escape($hostDir))</HostFolder><SandboxFolder>$([Security.SecurityElement]::Escape($sbDir))</SandboxFolder><ReadOnly>$ro</ReadOnly></MappedFolder>")
    }
    $logon = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $SandboxBridge\agent\launcher.ps1 -Bridge $SandboxBridge"
    return @"
<Configuration>
  <Networking>$net</Networking>
  <VGpu>$gpu</VGpu>
  <MemoryInMB>$mem</MemoryInMB>
  <ClipboardRedirection>$clip</ClipboardRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MappedFolders>
$($maps.ToString().TrimEnd())
  </MappedFolders>
  <LogonCommand><Command>$([Security.SecurityElement]::Escape($logon))</Command></LogonCommand>
</Configuration>
"@
}

# ---------------------------------------------------------------- host actions
switch ($Action.ToLowerInvariant()) {
    'help' {
        Out-Json ([ordered]@{ ok = $true; usage = 'sbx.ps1 <action> [-param value]...'; hostActions = 'check start stop status push pull update-agent logs call'
            agentActions = 'ping info exec job_start job_status job_stop launch screen screenshot cursor move click mouse_down mouse_up drag scroll type keys key_down key_up windows window wait_window foreground ui_tree ui_find ui_invoke ui_set_value clipboard_get clipboard_set ls read_text write_text copy delete ps kill sleep restart_agent stop_agent shutdown'
            reference = (Join-Path $SkillDir 'references\actions.md') })
    }
    'check' {
        $exe = Join-Path $env:windir 'System32\WindowsSandbox.exe'
        $cs = Get-CimInstance Win32_ComputerSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $ready = (Test-Path $exe) -and $cs.HypervisorPresent
        $hints = @()
        if (-not (Test-Path $exe)) { $hints += 'Windows Sandbox is not installed: enable "Windows Sandbox" in Turn Windows features on or off (or, as admin: Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All), then use Start > Power > Restart (not Shut down: Fast Startup skips pending installs).' }
        if ($pending) { $hints += 'A reboot is pending. Use Restart (not Shut down) to finish installing features.' }
        if ($Bridge -like "$env:APPDATA*" -or $Bridge -like "$env:LOCALAPPDATA*") { $hints += "Bridge folder $Bridge is under AppData; packaged apps virtualize it and the sandbox cannot see it. Set SBX_BRIDGE to a folder outside AppData." }
        if (-not $cs.HypervisorPresent) { $hints += 'Hypervisor is not running. Requires VT-x/AMD-V enabled in BIOS and a full restart after enabling the feature.' }
        Out-Json ([ordered]@{ ok = $ready; installed = (Test-Path $exe); hypervisorPresent = $cs.HypervisorPresent; rebootPending = $pending
            virtualizationFirmwareEnabled = $cpu.VirtualizationFirmwareEnabled; bridge = $Bridge; running = (@(Get-SandboxProcs).Count -gt 0); agentAlive = (Test-AgentAlive); hints = $hints }) ([int](-not $ready))
    }
    'status' {
        $s = Get-Status
        Out-Json ([ordered]@{ ok = $true; agentAlive = (Test-AgentAlive); status = $s; sandboxProcesses = @(Get-SandboxProcs | ForEach-Object { $_.ProcessName }); bridge = $Bridge })
    }
    'start' {
        if (-not (Test-Path (Join-Path $env:windir 'System32\WindowsSandbox.exe'))) { Fail 'Windows Sandbox is not installed. Run: sbx.ps1 check' }
        if (Test-AgentAlive) { Out-Json ([ordered]@{ ok = $true; alreadyRunning = $true; status = (Get-Status) }) }
        if (@(Get-SandboxProcs | Where-Object { $_.ProcessName -eq 'WindowsSandboxRemoteSession' -or $_.ProcessName -eq 'WindowsSandbox' }).Count -gt 0 -and -not (Get-Param 'force' $false)) {
            Fail 'A Windows Sandbox instance is already running without the agent (only one instance is allowed). Close it, or run: sbx.ps1 stop -kill' @{ processes = @(Get-SandboxProcs | ForEach-Object { $_.ProcessName }) }
        }
        Initialize-Bridge
        foreach ($d in 'inbox', 'outbox') { Get-ChildItem (Join-Path $Bridge $d) -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
        Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
        $wsb = Join-Path $Bridge 'sandbox.wsb'
        [IO.File]::WriteAllText($wsb, (New-WsbConfig), $Utf8)
        Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsSandbox.exe') -ArgumentList "`"$wsb`""
        $timeout = [double](Get-Param 'timeout' 240)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $timeout) {
            if (Test-AgentAlive) {
                Start-Sleep -Milliseconds 500
                $info = (Send-Request 'info' ([ordered]@{}) 30).result
                Out-Json ([ordered]@{ ok = $true; started = $true; bootSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); config = $wsb; info = $info })
            }
            Start-Sleep -Seconds 1
        }
        Fail "Sandbox did not report an agent heartbeat within $timeout s. Check that the sandbox window opened and look at $Bridge\logs." @{ config = $wsb; processes = @(Get-SandboxProcs | ForEach-Object { $_.ProcessName }) }
    }
    'stop' {
        $how = 'none'
        if ((Test-AgentAlive) -and -not (Get-Param 'kill' $false)) {
            try { Send-Request 'shutdown' ([ordered]@{}) 20 | Out-Null; $how = 'guest-shutdown' } catch {}
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 40 -and @(Get-SandboxProcs | Where-Object { $_.ProcessName -eq 'WindowsSandboxRemoteSession' -or $_.ProcessName -eq 'WindowsSandbox' }).Count -gt 0) { Start-Sleep -Seconds 1 }
        }
        $left = @(Get-SandboxProcs | Where-Object { $_.ProcessName -in 'WindowsSandbox', 'WindowsSandboxRemoteSession', 'WindowsSandboxClient' })
        if ($left.Count -gt 0) { $left | Stop-Process -Force -ErrorAction SilentlyContinue; $how = if ($how -eq 'none') { 'killed' } else { "$how+killed" } }
        Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
        Out-Json ([ordered]@{ ok = $true; stopped = $true; method = $how })
    }
    'update-agent' {
        Initialize-Bridge
        $r = Send-Request 'restart_agent' ([ordered]@{}) 20
        Start-Sleep -Seconds 3
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 30) { $s = Get-Status; if ($s -and $s.state -eq 'idle' -and $s.ageSeconds -lt 5) { break }; Start-Sleep -Milliseconds 500 }
        Out-Json ([ordered]@{ ok = $true; restarted = $r.ok; status = (Get-Status) })
    }
    'logs' {
        $n = [int](Get-Param 'lines' 40)
        $o = [ordered]@{ ok = $true }
        foreach ($f in 'agent', 'launcher') { $p = Join-Path $Bridge "logs\$f.log"; $o[$f] = if (Test-Path $p) { @(Get-Content $p -Tail $n -Encoding UTF8) } else { @() } }
        Out-Json $o
    }
    'push' {
        # push -src <host path> -dst <sandbox path>
        $src = [string](Get-Param 'src'); $dst = [string](Get-Param 'dst')
        if (-not $src -or -not $dst) { Fail 'push needs -src <host path> -dst <sandbox path>' }
        $stage = 'push_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $stageDir = Join-Path $Bridge "files\$stage"; New-Item -ItemType Directory -Force $stageDir | Out-Null
        Copy-Item -LiteralPath $src -Destination $stageDir -Recurse -Force
        $leaf = Split-Path -Leaf $src
        $r = Send-Request 'copy' ([ordered]@{ src = "bridge:files/$stage/$leaf"; dst = $dst })
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($r.ok) { Out-Json ([ordered]@{ ok = $true; src = $src; dst = $r.result.dst }) } else { Out-Json $r 1 }
    }
    'pull' {
        # pull -src <sandbox path> -dst <host path>
        $src = [string](Get-Param 'src'); $dst = [string](Get-Param 'dst')
        if (-not $src -or -not $dst) { Fail 'pull needs -src <sandbox path> -dst <host path>' }
        $stage = 'pull_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $leaf = Split-Path -Leaf $src
        $r = Send-Request 'copy' ([ordered]@{ src = $src; dst = "bridge:files/$stage/$leaf" })
        if (-not $r.ok) { Out-Json $r 1 }
        $staged = Join-Path $Bridge "files\$stage\$leaf"
        $parent = Split-Path -Parent $dst; if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
        Copy-Item -LiteralPath $staged -Destination $dst -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $Bridge "files\$stage") -Recurse -Force -ErrorAction SilentlyContinue
        Out-Json ([ordered]@{ ok = $true; src = $src; dst = (Resolve-Path -LiteralPath $dst).Path })
    }
    default {
        $act = $Action
        if ($act -eq 'call') { if ($Positional.Count -lt 1) { Fail 'call needs an action name: sbx.ps1 call <action> -paramsJson {...}' }; $act = [string]$Positional[0] }
        $act = $act -replace '-', '_'
        $wait = [double](Get-Param 'wait' 0); if ($Params.Contains('wait')) { $Params.Remove('wait') }
        if ($Params.Contains('force')) { $Params.Remove('force') }
        $r = Add-HostPaths (Send-Request $act $Params $wait)
        Out-Json $r ([int](-not $r.ok))
    }
}
