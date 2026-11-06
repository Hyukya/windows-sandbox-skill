# Host-side controller for Windows Sandbox.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File sbx.ps1 <action> [-name value]... [-flag]
# Host actions : check, start, stop, status, run, host_screenshot, push, pull, update-agent, logs, call
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
$StringKeys = 'text', 'command', 'value', 'title', 'name', 'keys', 'path', 'src', 'dst', 'cwd', 'id', 'process', 'class', 'type', 'args', 'modifiers', 'sandboxPath', 'entry', 'as'
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

# Direct channel to the SYSTEM secure-desktop helper, bypassing the main agent. Needed because a
# pending UAC prompt blocks the agent (its launch/exec waits for the elevation to be answered),
# so the agent cannot drive the very prompt you need to click. The helper is a separate process.
function Test-SecureAlive {
    $beat = Join-Path $Bridge 'secure\secure.status.json'
    if (-not (Test-Path $beat)) { return $false }
    try { $s = [IO.File]::ReadAllText($beat, $Utf8) | ConvertFrom-Json
        return (([DateTime]::UtcNow - [DateTime]::Parse($s.time).ToUniversalTime()).TotalSeconds -lt 12) } catch { return $false }
}
function Send-Secure([string]$op, $params, [double]$waitSec = 20) {
    $secDir = Join-Path $Bridge 'secure'
    if (-not (Test-SecureAlive) -and -not (Get-Param 'force' $false)) {
        Fail "Secure-desktop helper is not running. It is armed automatically at an elevated sandbox start; run 'sbx.ps1 secure_status', or restart the sandbox." @{ secureStatus = (Join-Path $secDir 'secure.status.json') }
    }
    $in = Join-Path $secDir 'inbox'; $out = Join-Path $secDir 'outbox'
    foreach ($d in $in, $out) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }
    $sid = '{0:yyyyMMddHHmmssfff}_{1}' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $req = [ordered]@{ id = $sid; op = $op }
    foreach ($k in $params.Keys) { $req[$k] = $params[$k] }
    $tmp = Join-Path $in "$sid.tmp"
    [IO.File]::WriteAllText($tmp, ($req | ConvertTo-Json -Compress -Depth 8), $Utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $in "$sid.json") -Force
    $outFile = Join-Path $out "$sid.json"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $waitSec) {
        if (Test-Path -LiteralPath $outFile) {
            Start-Sleep -Milliseconds 20
            try { $txt = [IO.File]::ReadAllText($outFile, $Utf8) } catch { Start-Sleep -Milliseconds 40; continue }
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            return ($txt | ConvertFrom-Json)
        }
        Start-Sleep -Milliseconds 50
    }
    Fail "Timed out after $waitSec s waiting for secure helper op '$op'."
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

function Start-Sandbox([double]$timeout = 240) {
    # returns an ordered result (alreadyRunning or started+info); calls Fail on error
    if (-not (Test-Path (Join-Path $env:windir 'System32\WindowsSandbox.exe'))) { Fail 'Windows Sandbox is not installed. Run: sbx.ps1 check' }
    if (Test-AgentAlive) { return [ordered]@{ ok = $true; alreadyRunning = $true; status = (Get-Status) } }
    if (@(Get-SandboxProcs | Where-Object { $_.ProcessName -eq 'WindowsSandboxRemoteSession' -or $_.ProcessName -eq 'WindowsSandbox' }).Count -gt 0 -and -not (Get-Param 'force' $false)) {
        Fail 'A Windows Sandbox instance is already running without the agent (only one instance is allowed). Close it, or run: sbx.ps1 stop -kill' @{ processes = @(Get-SandboxProcs | ForEach-Object { $_.ProcessName }) }
    }
    Initialize-Bridge
    foreach ($d in 'inbox', 'outbox') { Get-ChildItem (Join-Path $Bridge $d) -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
    $wsb = Join-Path $Bridge 'sandbox.wsb'
    [IO.File]::WriteAllText($wsb, (New-WsbConfig), $Utf8)
    Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsSandbox.exe') -ArgumentList "`"$wsb`""
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        if (Test-AgentAlive) {
            Start-Sleep -Milliseconds 500
            $info = (Send-Request 'info' ([ordered]@{}) 30).result
            return [ordered]@{ ok = $true; started = $true; bootSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); config = $wsb; info = $info }
        }
        Start-Sleep -Seconds 1
    }
    Fail "Sandbox did not report an agent heartbeat within $timeout s. Check that the sandbox window opened and look at $Bridge\logs." @{ config = $wsb; processes = @(Get-SandboxProcs | ForEach-Object { $_.ProcessName }) }
}

function Push-Item([string]$src, [string]$dst) {
    # copy a host file/folder to an exact sandbox path via the bridge; returns the agent response
    $stage = 'push_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $stageDir = Join-Path $Bridge "files\$stage"; New-Item -ItemType Directory -Force $stageDir | Out-Null
    try {
        Copy-Item -LiteralPath $src -Destination $stageDir -Recurse -Force
        $leaf = Split-Path -Leaf $src
        return (Send-Request 'copy' ([ordered]@{ src = "bridge:files/$stage/$leaf"; dst = $dst }) 900)
    } finally { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Agent([string]$action, $params, [string]$step) {
    # agent call that aborts the whole host action on failure
    $r = Send-Request $action $params
    if (-not $r.ok) { Fail "run: $step failed: $($r.error)" @{ step = $step; response = $r } }
    if ($action -eq 'exec' -and $step -ne 'exec' -and ($r.result.exitCode -ne 0 -or $r.result.timedOut)) {
        # helper steps (probe/unzip/mount) must succeed; the user's own program may return any code
        Fail "run: $step failed (exit $($r.result.exitCode)): $(([string]$r.result.stderr).Trim())" @{ step = $step; result = $r.result }
    }
    return $r.result
}

function Get-RunKind([string]$p, [bool]$isDir) {
    if ($p -match '^(https?|ftp)://') { return 'url' }
    if ($isDir) { return 'folder' }
    switch ([IO.Path]::GetExtension($p).ToLowerInvariant()) {
        { $_ -in '.exe', '.com', '.scr' } { return 'exe' }
        '.msi' { return 'msi' }
        '.msp' { return 'msp' }
        '.ps1' { return 'ps1' }
        { $_ -in '.bat', '.cmd' } { return 'cmd' }
        { $_ -in '.vbs', '.vbe', '.js', '.jse', '.wsf' } { return 'wsh' }
        '.reg' { return 'reg' }
        { $_ -in '.msix', '.msixbundle', '.appx', '.appxbundle' } { return 'appx' }
        '.zip' { return 'zip' }
        '.iso' { return 'disk' }
        { $_ -in '.vhd', '.vhdx' } { return 'vhd' }
        default { return 'open' }
    }
}

function Get-RunSpec([string]$kind, [string]$f, [string]$a, [bool]$wait, [bool]$silent) {
    # -> @{ file; args; mode = any|wait|launch }   (args is a raw command-line string)
    $q = '"' + $f + '"'
    $tail = if ($a) { ' ' + $a } else { '' }
    switch ($kind) {
        'exe' { return @{ file = $f; args = $a; mode = 'any' } }
        'msi' { return @{ file = 'msiexec.exe'; args = "/i $q" + $(if ($silent) { ' /qn /norestart' }) + $tail; mode = 'any' } }
        'msp' { return @{ file = 'msiexec.exe'; args = "/p $q" + $(if ($silent) { ' /qn /norestart' }) + $tail; mode = 'any' } }
        'ps1' { return @{ file = 'powershell.exe'; args = '-NoProfile -ExecutionPolicy Bypass' + $(if (-not $wait) { ' -NoExit' }) + " -File $q$tail"; mode = 'any' } }
        'cmd' { return @{ file = 'cmd.exe'; args = $(if ($wait) { '/c' } else { '/k' }) + " `"$q$tail`""; mode = 'any' } }
        'wsh' { if ($wait) { return @{ file = 'cscript.exe'; args = "//NoLogo $q$tail"; mode = 'any' } }; return @{ file = 'wscript.exe'; args = "$q$tail"; mode = 'any' } }
        'reg' { return @{ file = 'reg.exe'; args = "import $q"; mode = 'wait' } }
        'appx' { return @{ file = 'powershell.exe'; args = "-NoProfile -ExecutionPolicy Bypass -Command `"Add-AppxPackage -Path '$($f -replace "'", "''")'`""; mode = 'wait' } }
        'url' { return @{ file = 'msedge.exe'; args = "$q$tail"; mode = 'launch' } }
        default { return @{ file = 'explorer.exe'; args = $q; mode = 'launch' } }   # folder / open (default file association)
    }
}

function PsQuote([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

function Use-HostNative {
    if (-not ('SbxHost' -as [type])) {
        Add-Type -AssemblyName System.Drawing
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hostnative.cs'))) -ReferencedAssemblies System.Drawing
    }
    [SbxHost]::MakeDpiAware()
}

function Save-HostScreenshot {
    # Captures the sandbox window from the HOST (no agent needed). Works when the guest blocks screen capture,
    # the agent is dead/hung, or during boot/logon. -area display|window, -method auto|print|screen,
    # -restore, -activate, -scale, -name, -dst, -x -y -width -height (crop, sandbox coordinates; display area only)
    Use-HostNative
    $procIds = @(Get-SandboxProcs | ForEach-Object { $_.Id })
    $wins = @(if ($procIds.Count) { [SbxHost]::WindowsOf([int[]]$procIds) })
    if ($wins.Count -eq 0) { throw 'No Windows Sandbox window found on the host. Is the sandbox running? (sbx.ps1 status)' }
    # prefer the window that hosts a guest display, then the largest
    $hwnd = $wins | Sort-Object @{ e = { [int]([SbxHost]::FindDisplay($_) -ne [IntPtr]::Zero) } }, @{ e = { $r = [SbxHost]::FrameRect($_); ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } } -Descending | Select-Object -First 1

    $restored = $false
    if ([SbxHost]::IsIconic($hwnd)) {
        if (-not ((Get-Param 'restore' $false) -or (Get-Param 'activate' $false))) {
            throw 'The sandbox window is minimized, so there is nothing to capture (and the guest may stop rendering). Pass -restore to restore it without focusing it, or -activate to bring it to the front.'
        }
        [void][SbxHost]::ShowWindow($hwnd, 4); $restored = $true   # SW_SHOWNOACTIVATE
    }
    if (Get-Param 'activate' $false) { [SbxHost]::Activate($hwnd); $restored = $true }
    if ($restored) { Start-Sleep -Milliseconds ([int]([double](Get-Param 'settle' 0.7) * 1000)) }

    $area = ([string](Get-Param 'area' 'display')).ToLowerInvariant()
    if ($area -notin 'display', 'window') { throw "host_screenshot: -area must be display or window (got '$area')" }
    $method = ([string](Get-Param 'method' 'auto')).ToLowerInvariant()
    if ($method -notin 'auto', 'print', 'screen') { throw "host_screenshot: -method must be auto, print or screen (got '$method')" }

    $wr = New-Object SbxHost+RECT; [void][SbxHost]::GetWindowRect($hwnd, [ref]$wr)
    $disp = [SbxHost]::FindDisplay($hwnd)
    $dr = if ($disp -ne [IntPtr]::Zero) { $t = New-Object SbxHost+RECT; [void][SbxHost]::GetWindowRect($disp, [ref]$t); $t } else { [SbxHost]::ClientScreenRect($hwnd) }
    $kr = if ($area -eq 'window') { [SbxHost]::FrameRect($hwnd) } else { $dr }   # host-screen rect to keep
    $cx = [int]$kr.Left; $cy = [int]$kr.Top; $cw = [int]($kr.Right - $kr.Left); $ch = [int]($kr.Bottom - $kr.Top)
    if ($cw -le 0 -or $ch -le 0) { throw 'The sandbox window has no visible area.' }

    # guest screen size (from the last heartbeat) -> ratio between guest pixels and host display pixels (1 unless scaled)
    $st = Get-Status
    $gw = $dr.Right - $dr.Left; $gh = $dr.Bottom - $dr.Top
    if ($st -and $st.screen -and [int]$st.screen.width -gt 0) { $gw = [int]$st.screen.width; $gh = [int]$st.screen.height }
    $ratio = $gw / [double]($dr.Right - $dr.Left)   # guest px per host px

    # crop in sandbox coordinates (display area only)
    $sub = $null
    if ($area -eq 'display' -and ($Params.Contains('x') -or $Params.Contains('y') -or $Params.Contains('width') -or $Params.Contains('height'))) {
        $sx = [int](Get-Param 'x' 0); $sy = [int](Get-Param 'y' 0)
        $sw = [int](Get-Param 'width' ($gw - $sx)); $sh = [int](Get-Param 'height' ($gh - $sy))
        $sub = @{ x = $sx; y = $sy; width = $sw; height = $sh }
        $cx = $dr.Left + [int][Math]::Floor($sx / $ratio); $cy = $dr.Top + [int][Math]::Floor($sy / $ratio)
        $cw = [int][Math]::Ceiling($sw / $ratio); $ch = [int][Math]::Ceiling($sh / $ratio)
        if ($cw -le 0 -or $ch -le 0) { throw 'host_screenshot: crop region is empty' }
    }

    $used = $null; $bmp = $null; $printBmp = $null; $warn = @()
    if ($method -in 'auto', 'print') {
        try {
            $full = [SbxHost]::CapturePrint($hwnd)
            # judge blankness on the whole guest display: a small crop of a plain area is legitimately one color,
            # while the title bar would hide a black guest screen
            $chk = [SbxHost]::Crop($full, $dr.Left - $wr.Left, $dr.Top - $wr.Top, $dr.Right - $dr.Left, $dr.Bottom - $dr.Top)
            try { $fullBlank = [SbxHost]::LooksBlank($chk) } finally { $chk.Dispose() }
            try { $printBmp = [SbxHost]::Crop($full, $cx - $wr.Left, $cy - $wr.Top, $cw, $ch) } finally { $full.Dispose() }
            if ($method -eq 'print' -or -not $fullBlank) { $bmp = $printBmp; $used = 'print' }
        } catch { if ($method -eq 'print') { throw "host_screenshot: PrintWindow capture failed: $($_.Exception.Message)" }; $warn += "PrintWindow failed ($($_.Exception.Message)); trying a screen copy." }
    }
    if (-not $bmp) {
        try {
            $bmp = [SbxHost]::CaptureScreen($cx, $cy, $cw, $ch); $used = 'screen'
            if ($printBmp) { $printBmp.Dispose(); $warn += 'PrintWindow returned a blank image; used a screen copy instead.' }
            if ([SbxHost]::GetForegroundWindow() -ne $hwnd) { $warn += 'Screen copy grabs whatever is on top of the host screen there; the sandbox window is not in the foreground, so other windows may cover it. Pass -activate to bring it to the front.' }
        } catch {
            $why = "screen copy failed ($($_.Exception.InnerException.Message)): the host desktop is not readable from this process (locked, or a minimized/disconnected Remote Desktop session)"
            if (-not $printBmp) { throw "host_screenshot: $why. Use -method print." }
            $bmp = $printBmp; $used = 'print'; $warn += "$why; kept the PrintWindow image."
        }
    }
    $blank = [SbxHost]::LooksBlank($bmp)
    if ($blank) { $warn += 'The captured image is a single color (guest screen black or booting; the UAC / lock / Ctrl+Alt+Del secure desktop, which only secure-shot can capture; or capture blocked on the host).' }

    $scale = [double](Get-Param 'scale' 1.0)
    if ($scale -gt 0 -and $scale -ne 1.0) {
        $nw = [Math]::Max(1, [int]($bmp.Width * $scale)); $nh = [Math]::Max(1, [int]($bmp.Height * $scale))
        $small = New-Object System.Drawing.Bitmap $nw, $nh
        $g = [System.Drawing.Graphics]::FromImage($small)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($bmp, 0, 0, $nw, $nh); $g.Dispose(); $bmp.Dispose(); $bmp = $small
    } else { $scale = 1.0 }

    $name = [string](Get-Param 'name' ("host_{0:yyyyMMdd_HHmmss_fff}.png" -f (Get-Date)))
    if ($name -notmatch '\.(png|jpg|jpeg)$') { $name += '.png' }
    $dst = [string](Get-Param 'dst' '')
    $outPath = if ($dst) { $dst } else { New-Item -ItemType Directory -Force (Join-Path $Bridge 'shots') | Out-Null; Join-Path $Bridge "shots\$name" }
    $parent = Split-Path -Parent $outPath; if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    $fmt = if ($outPath -match '\.jpe?g$') { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
    $bmp.Save($outPath, $fmt); $iw = $bmp.Width; $ih = $bmp.Height; $bmp.Dispose()

    $res = [ordered]@{ hostPath = (Resolve-Path -LiteralPath $outPath).Path; method = $used; area = $area; width = $iw; height = $ih; blank = $blank
        window = [ordered]@{ hwnd = [int64]$hwnd; title = [SbxHost]::WindowText($hwnd); foreground = ([SbxHost]::GetForegroundWindow() -eq $hwnd); restored = $restored }
        hostRect = [ordered]@{ x = $cx; y = $cy; width = $cw; height = $ch } }
    if ($area -eq 'display') {
        # same mapping as the agent screenshot: sandbox = region.x + px/scale
        $rx = if ($sub) { $sub.x } else { 0 }; $ry = if ($sub) { $sub.y } else { 0 }
        $res.region = [ordered]@{ x = $rx; y = $ry; width = [int][Math]::Round($cw * $ratio); height = [int][Math]::Round($ch * $ratio) }
        $res.scale = [Math]::Round($scale / $ratio, 6)
        $res.note = 'Image pixel (px,py) -> sandbox screen (region.x + px/scale, region.y + py/scale)'
    } else {
        $res.scale = $scale
        $res.displayInImage = [ordered]@{ x = [int](($dr.Left - $cx) * $scale); y = [int](($dr.Top - $cy) * $scale); width = [int](($dr.Right - $dr.Left) * $scale); height = [int](($dr.Bottom - $dr.Top) * $scale) }
        $res.note = 'Whole sandbox window incl. title bar. displayInImage is where the guest screen sits inside the image.'
    }
    if ($warn.Count) { $res.warnings = $warn }
    return $res
}

function Invoke-Run {
    # run -path <host file|folder|URL> | -sandboxPath <path already in sandbox>
    #     [-args "..."] [-wait] [-timeout 600] [-silent] [-withFolder] [-dst <sandbox dir>] [-entry <file in zip/iso>]
    #     [-as kind] [-waitWindow] [-screenshot] [-settle 3] [-noStart] [-bootTimeout 240] (+ start options when it boots)
    $hostPath = [string](Get-Param 'path' ''); $sbPath = [string](Get-Param 'sandboxPath' '')
    if (-not $hostPath -and -not $sbPath) { Fail 'run needs -path <host file|folder|URL> or -sandboxPath <path inside sandbox>' }
    $argStr = [string](Get-Param 'args' ''); $wait = [bool](Get-Param 'wait' $false); $silent = [bool](Get-Param 'silent' $false)
    $isUrl = $hostPath -match '^(https?|ftp)://'
    $out = [ordered]@{ ok = $true }

    $isDir = $false
    if ($hostPath -and -not $isUrl) {
        if (-not (Test-Path -LiteralPath $hostPath)) { Fail "run: host path not found: $hostPath" }
        $hostPath = (Resolve-Path -LiteralPath $hostPath).Path
        $isDir = Test-Path -LiteralPath $hostPath -PathType Container
        $out.hostPath = $hostPath
    }

    if (-not (Get-Param 'as' '') -and ($hostPath + $sbPath) -match '\.vhdx?$') { Fail 'run: VHD/VHDX is not supported - mounting a virtual disk inside Windows Sandbox can crash the sandbox VM (0x80370106).' }
    if (-not (Test-AgentAlive)) {
        if (Get-Param 'noStart' $false) { Fail 'Sandbox agent is not running and -noStart was given. Run: sbx.ps1 start' }
        $out.boot = Start-Sandbox ([double](Get-Param 'bootTimeout' 240))
    }

    # 1. get the target into the sandbox
    $target = if ($isUrl) { $hostPath } elseif ($sbPath) { $sbPath } else { $null }
    if (-not $target) {
        $dstDir = ([string](Get-Param 'dst' 'C:\Users\WDAGUtilityAccount\Desktop')).TrimEnd('\')
        $copySrc = $hostPath
        if ((Get-Param 'withFolder' $false) -and -not $isDir) { $copySrc = [IO.Path]::GetDirectoryName($hostPath) }   # bring sibling DLLs/configs along
        $copyDst = [IO.Path]::Combine($dstDir, [IO.Path]::GetFileName($copySrc))
        if (Test-Path -LiteralPath $copySrc -PathType Container) { Send-Request 'delete' ([ordered]@{ path = $copyDst }) | Out-Null }   # avoid nesting on re-run
        $r = Push-Item $copySrc $copyDst
        if (-not $r.ok) { Fail "run: copy into sandbox failed: $($r.error)" @{ step = 'copy'; response = $r } }
        $target = if ($copySrc -ne $hostPath) { [IO.Path]::Combine($copyDst, [IO.Path]::GetFileName($hostPath)) } else { $copyDst }
    }
    $out.sandboxPath = $target

    # 2. pick a runner
    $kind = [string](Get-Param 'as' '')
    if (-not $kind) {
        $sbIsDir = $isDir
        if ($sbPath -and -not $hostPath) { $sbIsDir = [bool](Invoke-Agent 'exec' ([ordered]@{ command = "if (Test-Path -LiteralPath $(PsQuote $target) -PathType Container) { 'D' } else { 'F' }"; timeout = 30 }) 'probe').stdout.Trim().Equals('D') }
        $kind = Get-RunKind $target $sbIsDir
    }
    $entry = [string](Get-Param 'entry' '')
    if ($kind -in 'zip', 'disk') {
        if ($kind -eq 'zip') {
            $root = [IO.Path]::Combine([IO.Path]::GetDirectoryName($target), [IO.Path]::GetFileNameWithoutExtension($target))
            $null = Invoke-Agent 'exec' ([ordered]@{ command = "Expand-Archive -LiteralPath $(PsQuote $target) -DestinationPath $(PsQuote $root) -Force"; timeout = 600 }) 'unzip'
            $out.extractedTo = $root
        } else {
            # ISO only (VHD is refused above). The partition branch is kept as a fallback for odd images.
            $cmd = (@'
$img = __IMG__
if (-not (Get-DiskImage -ImagePath $img).Attached) { Mount-DiskImage -ImagePath $img | Out-Null }
$di = Get-DiskImage -ImagePath $img; $letter = $null
for ($k = 0; $k -lt 30 -and -not $letter; $k++) {
    if ($di.StorageType -eq 1) { $letter = ($di | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1).DriveLetter }
    else {
        $parts = @(Get-Disk -Number $di.Number -ErrorAction SilentlyContinue | Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.Type -notin 'Reserved', 'System', 'Recovery' })
        $letter = ($parts | Where-Object DriveLetter | Select-Object -First 1).DriveLetter
        if (-not $letter -and $parts.Count) { $parts | Sort-Object Size -Descending | Select-Object -First 1 | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue }
    }
    if (-not $letter) { Start-Sleep -Milliseconds 500; $di = Get-DiskImage -ImagePath $img }
}
if (-not $letter) { throw 'image mounted but no drive letter appeared' }
"$($letter):\"
'@).Replace('__IMG__', (PsQuote $target))
            $root = (Invoke-Agent 'exec' ([ordered]@{ command = $cmd; timeout = 120 }) 'mount').stdout.Trim()
            $out.mountedAt = $root
        }
        if ($entry) { $target = [IO.Path]::Combine($root, $entry); $kind = Get-RunKind $target $false; $out.sandboxPath = $target }
        else { $target = $root; $kind = 'folder' }
    }
    $out.kind = $kind
    if ($kind -eq 'vhd') { Fail 'run: VHD/VHDX is not supported - mounting a virtual disk inside Windows Sandbox can crash the sandbox VM (0x80370106). Extract the files on the host and run them instead.' }

    # 3. run it
    $spec = Get-RunSpec $kind $target $argStr $wait $silent
    $mode = if ($spec.mode -ne 'any') { $spec.mode } elseif ($wait) { 'wait' } else { 'launch' }
    $cwd = if ($kind -in 'url', 'folder') { 'C:\Users\WDAGUtilityAccount' } else { [IO.Path]::GetDirectoryName($target) }
    $out.mode = $mode; $out.command = [ordered]@{ file = $spec.file; args = $spec.args; cwd = $cwd }
    if ($mode -eq 'wait') {
        # Start-Process -Wait waits for child processes too (installers), and the redirect captures console output
        $ps = "`$o = Join-Path `$env:TEMP ('run_' + [guid]::NewGuid().ToString('N')); `$e = `$o + '.err'`r`n" +
              "`$sp = @{ FilePath = $(PsQuote $spec.file); WorkingDirectory = $(PsQuote $cwd); Wait = `$true; PassThru = `$true; NoNewWindow = `$true; RedirectStandardOutput = `$o; RedirectStandardError = `$e }`r`n" +
              $(if ($spec.args) { "`$sp.ArgumentList = $(PsQuote $spec.args)`r`n" } else { '' }) +
              "`$p = Start-Process @sp`r`n" +
              "foreach (`$x in @(@(`$o, [Console]::Out), @(`$e, [Console]::Error))) { if (Test-Path `$x[0]) { `$x[1].Write([IO.File]::ReadAllText(`$x[0], [Text.Encoding]::Default)); Remove-Item `$x[0] -Force } }`r`n" +
              "exit `$p.ExitCode"
        $out.exec = Invoke-Agent 'exec' ([ordered]@{ command = $ps; timeout = [int](Get-Param 'timeout' 600); cwd = $cwd }) 'exec'
    } else {
        $lp = [ordered]@{ path = $spec.file; cwd = $cwd }
        if ($spec.args) { $lp.args = $spec.args }
        if (Get-Param 'waitWindow' $false) { $lp.waitWindow = $true; $lp.timeout = [int](Get-Param 'timeout' 20) }
        $out.launch = Invoke-Agent 'launch' $lp 'launch'
    }

    # 4. optional look at the result
    if (Get-Param 'screenshot' $false) {
        if ($mode -eq 'launch') { Start-Sleep -Milliseconds ([int]([double](Get-Param 'settle' 3) * 1000)) }
        $s = Add-HostPaths (Send-Request 'screenshot' ([ordered]@{ name = "run_$(Get-Date -Format 'HHmmss').png" }))
        $out.screenshot = if ($s.ok) { $s.result } else {
            # in-guest capture failed (e.g. the app blocks screen capture) -> capture the sandbox window from the host
            try { $h = Save-HostScreenshot; $h.agentError = $s.error; $h } catch { [ordered]@{ error = $s.error } }
        }
    }
    Out-Json $out
}

# ---------------------------------------------------------------- host actions
switch ($Action.ToLowerInvariant()) {
    'help' {
        Out-Json ([ordered]@{ ok = $true; usage = 'sbx.ps1 <action> [-param value]...'; hostActions = 'check start stop status run host_screenshot push pull update-agent logs call secure-shot secure-click secure-type secure-keys secure-move secure-desktop secure-sas'
            agentActions = 'ping info exec job_start job_status job_stop launch screen screenshot cursor move click mouse_down mouse_up drag scroll type keys key_down key_up windows window wait_window foreground ui_tree ui_find ui_invoke ui_set_value clipboard_get clipboard_set ls read_text write_text copy delete ps kill sleep secure_arm secure_status secure_sas uac restart_agent stop_agent shutdown'
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
    'start' { Out-Json (Start-Sandbox ([double](Get-Param 'timeout' 240))) }
    { $_ -in 'host_screenshot', 'host-screenshot' } { try { $hs = Save-HostScreenshot } catch { Fail $_.Exception.Message }; Out-Json ([ordered]@{ ok = $true; action = 'host_screenshot'; result = $hs }) }
    'run' { Invoke-Run }
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
        $r = Push-Item $src $dst
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
    { $_ -match '^secure[-_](shot|click|type|keys|move|desktop|sas)$' } {
        # Host-direct secure-desktop ops (bypass the agent; work even when a UAC prompt blocks it).
        $op = ($Action -replace '^secure[-_]', '').ToLowerInvariant()
        if ($Params.Contains('force')) { $Params.Remove('force') }
        $r = Send-Secure $op $Params
        if ($r.ok -and $r.result) { $r = Add-HostPaths $r }
        Out-Json $r ([int](-not $r.ok))
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
