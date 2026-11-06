# Windows Sandbox agent: runs inside the sandbox (interactive user session),
# polls <Bridge>\inbox for JSON requests and writes JSON responses to <Bridge>\outbox.
# Exit codes: 0 = restart requested (launcher restarts it), 99 = stop for good.
param([string]$Bridge = 'C:\Bridge')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AgentVersion = '1.0.0'
$Utf8 = New-Object System.Text.UTF8Encoding $false

$Dirs = @{}
foreach ($d in 'inbox', 'outbox', 'shots', 'files', 'jobs', 'logs') {
    $Dirs[$d] = Join-Path $Bridge $d
    if (-not (Test-Path $Dirs[$d])) { New-Item -ItemType Directory -Force -Path $Dirs[$d] | Out-Null }
}
$StatusFile = Join-Path $Bridge 'status.json'
$LogFile = Join-Path $Dirs.logs 'agent.log'

function Log([string]$msg) {
    try { [IO.File]::AppendAllText($LogFile, ('{0:yyyy-MM-dd HH:mm:ss.fff} {1}{2}' -f (Get-Date), $msg, "`r`n"), $Utf8) } catch {}
}

# ---------------------------------------------------------------- native layer
$nativeSrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native.cs'))
if (-not ('SbxNative' -as [type])) { Add-Type -TypeDefinition $nativeSrc -Language CSharp }
[SbxNative]::MakeDpiAware()
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
# Secure-desktop support (UAC / lock screen / Ctrl+Alt+Del). Loaded for input-desktop detection
# and for arming the SYSTEM helper; see secure-agent.ps1 / secure-broker.ps1.
$secureSrc = Join-Path $PSScriptRoot 'secure.cs'
if ((Test-Path $secureSrc) -and -not ('SbxSecure' -as [type])) {
    try { Add-Type -TypeDefinition ([IO.File]::ReadAllText($secureSrc)) -ReferencedAssemblies System.Drawing } catch {}
}
$script:IsElevated = $false
try {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:IsElevated = (New-Object Security.Principal.WindowsPrincipal $wi).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
$script:UiaLoaded = $false
function Use-Uia {
    if (-not $script:UiaLoaded) {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $script:UiaLoaded = $true
    }
}

# ---------------------------------------------------------------- helpers
function Write-JsonFile([string]$path, $obj) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 12 -Compress), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

$script:LastBeat = [DateTime]::MinValue
function Update-Heartbeat([string]$state = 'idle', [switch]$Force) {
    $now = Get-Date
    if (-not $Force -and ($now - $script:LastBeat).TotalSeconds -lt 2) { return }
    $script:LastBeat = $now
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    try {
        Write-JsonFile $StatusFile ([ordered]@{
            agent = $AgentVersion; pid = $PID; state = $state; time = $now.ToString('o'); utc = [DateTime]::UtcNow.ToString('o')
            user = $env:USERNAME; computer = $env:COMPUTERNAME
            screen = @{ x = $vs.X; y = $vs.Y; width = $vs.Width; height = $vs.Height }
        })
    } catch {}
}

function P($p, [string]$name, $default = $null) {
    if ($null -ne $p -and ($p.PSObject.Properties.Name -contains $name) -and $null -ne $p.$name -and "$($p.$name)" -ne '') { return $p.$name }
    return $default
}
function Need($p, [string]$name) {
    $v = P $p $name
    if ($null -eq $v) { throw "Missing required parameter '$name'" }
    return $v
}
function B($v) { return ($v -eq $true -or "$v" -match '^(?i:true|1|yes|on)$') }

# ---------------------------------------------------------------- exec
function New-ScriptFile([string]$shell, [string]$command, [string]$id) {
    $tmpDir = Join-Path $env:TEMP 'sbx'
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Force $tmpDir | Out-Null }
    if ($shell -eq 'cmd') {
        $f = Join-Path $tmpDir "$id.cmd"
        [IO.File]::WriteAllText($f, "@echo off`r`nchcp 65001 >nul`r`n$command`r`n", $Utf8)
        return @{ file = 'cmd.exe'; args = "/d /c `"$f`""; path = $f }
    }
    $f = Join-Path $tmpDir "$id.ps1"
    $body = "[Console]::OutputEncoding = [Text.Encoding]::UTF8`r`n`$OutputEncoding = [Text.Encoding]::UTF8`r`n`$ProgressPreference = 'SilentlyContinue'`r`n" +
            "$command`r`nif (`$LASTEXITCODE) { exit `$LASTEXITCODE }`r`n"
    [IO.File]::WriteAllText($f, $body, (New-Object System.Text.UTF8Encoding $true))
    return @{ file = 'powershell.exe'; args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$f`""; path = $f }
}

function Stop-Tree([int]$procId) { try { & taskkill.exe /T /F /PID $procId 2>&1 | Out-Null } catch {} }

# ---- self-protection: the agent, its launcher and the secure helper are all powershell.exe, so a
# plain `kill -name powershell` (or a tree kill of one of their ancestors) would take the agent down
# with no way back short of a reboot. Identify them and keep kill away from them.
function Get-ProcTable {
    $t = @{}
    foreach ($p in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate -ErrorAction SilentlyContinue)) {
        $t[[int]$p.ProcessId] = $p
    }
    return $t
}
function Get-ParentPid($t, [int]$procId) {
    $p = $t[$procId]; if (-not $p) { return $null }
    $ppid = [int]$p.ParentProcessId
    if ($ppid -eq $procId -or $ppid -eq 0) { return $null }
    $pp = $t[$ppid]; if (-not $pp) { return $null }
    if ($pp.CreationDate -and $p.CreationDate -and $pp.CreationDate -gt $p.CreationDate) { return $null }  # parent PID was reused
    return $ppid
}
$CriticalProcs = 'CExecSvc.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'lsass.exe', 'smss.exe'
# pid -> role (agent | launcher | secure) for the skill's own processes, 'system' for critical OS ones.
function Get-AgentRoles($t) {
    $roles = @{}
    foreach ($id in @($t.Keys)) {
        # Killing these ends the whole sandbox session (CExecSvc is the launcher's parent).
        if ($id -le 4 -or $t[$id].Name -in $CriticalProcs) { $roles[$id] = 'system'; continue }
        if ($t[$id].Name -notin 'powershell.exe', 'pwsh.exe') { continue }  # e.g. a cmd /c wrapper that mentions launcher.ps1
        $cl = [string]$t[$id].CommandLine
        if ($cl -match '(?i)[\\/]launcher\.ps1') { $roles[$id] = 'launcher' }
        elseif ($cl -match '(?i)[\\/](secure-agent|secure-broker)\.ps1') { $roles[$id] = 'secure' }
        elseif ($cl -match '(?i)[\\/]agent\.ps1') { $roles[$id] = 'agent' }
    }
    $roles[[int]$PID] = 'agent'
    # The launcher is the agent's powershell parent even if its command line cannot be read.
    $pp = Get-ParentPid $t $PID
    if ($null -ne $pp -and -not $roles.ContainsKey($pp) -and $t[$pp].Name -eq 'powershell.exe') { $roles[$pp] = 'launcher' }
    # The SYSTEM helper's command line is unreadable at Medium integrity; its heartbeat names its pid.
    try {
        $beat = Join-Path $Bridge 'secure\secure.status.json'
        if (Test-Path $beat) { $hp = [int](([IO.File]::ReadAllText($beat, $Utf8) | ConvertFrom-Json).pid); if ($t.ContainsKey($hp)) { $roles[$hp] = 'secure' } }
    } catch {}
    return $roles
}

function Stop-Guarded([int[]]$targets, [bool]$unprotect) {
    $t = Get-ProcTable; $roles = Get-AgentRoles $t
    $protected = @{}
    foreach ($k in @($roles.Keys)) { if ($k -eq $PID -or -not $unprotect) { $protected[$k] = $roles[$k] } }
    # Ancestors of a protected process: `taskkill /T` there would kill the protected one too.
    $anc = @{}
    foreach ($k in @($protected.Keys)) { $c = Get-ParentPid $t $k; $n = 0; while ($null -ne $c -and $n -lt 64) { $anc[$c] = $true; $c = Get-ParentPid $t $c; $n++ } }
    $kids = @{}
    foreach ($id in @($t.Keys)) { $pp = Get-ParentPid $t $id; if ($null -ne $pp) { if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.Generic.List[int] }; $kids[$pp].Add($id) } }
    $killed = @(); $skipped = @(); $notFound = @()
    foreach ($id in @($targets | Select-Object -Unique)) {
        if (-not $t.ContainsKey($id)) { $notFound += $id; continue }
        if ($protected.ContainsKey($id)) {
            $why = if ($id -eq $PID) { 'this is the agent itself; use restart_agent or stop_agent' } else { "protected $($protected[$id]) process; pass unprotect=true to kill it anyway" }
            $skipped += [ordered]@{ pid = $id; name = $t[$id].Name; role = $protected[$id]; reason = $why }; continue
        }
        if ($anc.ContainsKey($id)) {
            # Kill the subtree by hand, without descending into protected branches; leaves first.
            $order = New-Object System.Collections.Generic.List[int]
            $stack = New-Object System.Collections.Generic.Stack[int]; $stack.Push($id)
            while ($stack.Count -gt 0) {
                $x = $stack.Pop(); $order.Add($x)
                if ($kids.ContainsKey($x)) { foreach ($c in $kids[$x]) { if (-not $protected.ContainsKey($c)) { $stack.Push($c) } } }
            }
            for ($i = $order.Count - 1; $i -ge 0; $i--) { try { Stop-Process -Id $order[$i] -Force -ErrorAction Stop } catch {} }
        } else { Stop-Tree $id }
        $killed += $id
    }
    $res = [ordered]@{ killed = $killed; skipped = $skipped }
    if ($notFound.Count) { $res.notFound = $notFound }
    return $res
}

function Limit([string]$s, [int]$max) {
    if ($null -eq $s) { return @('', $false) }
    if ($s.Length -le $max) { return @($s, $false) }
    return @(($s.Substring($s.Length - $max)), $true)
}

function Invoke-Exec($p, [string]$id) {
    $shell = (P $p 'shell' 'powershell').ToString().ToLowerInvariant()
    $cmd = [string](Need $p 'command')
    $timeout = [int](P $p 'timeout' 120)
    $max = [int](P $p 'maxChars' 200000)
    $cwd = [string](P $p 'cwd' $env:USERPROFILE)
    $s = New-ScriptFile $shell $cmd $id

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $s.file; $psi.Arguments = $s.args; $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outT = $proc.StandardOutput.ReadToEndAsync(); $errT = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    while (-not $proc.WaitForExit(1000)) {
        Update-Heartbeat 'busy'
        if ($sw.Elapsed.TotalSeconds -ge $timeout) { $timedOut = $true; Stop-Tree $proc.Id; break }
    }
    $proc.WaitForExit(5000) | Out-Null
    [void]$outT.Wait(5000); [void]$errT.Wait(5000)
    $o = Limit $outT.Result $max; $e = Limit $errT.Result $max
    Remove-Item -LiteralPath $s.path -Force -ErrorAction SilentlyContinue
    $code = $null; if ($proc.HasExited) { $code = $proc.ExitCode }
    return [ordered]@{ exitCode = $code; timedOut = $timedOut; durationMs = $sw.ElapsedMilliseconds
        stdout = $o[0]; stderr = $e[0]; truncated = ($o[1] -or $e[1]) }
}

$script:Jobs = @{}
function Start-Job2($p, [string]$id) {
    $shell = (P $p 'shell' 'powershell').ToString().ToLowerInvariant()
    $cmd = [string](Need $p 'command')
    $cwd = [string](P $p 'cwd' $env:USERPROFILE)
    $s = New-ScriptFile $shell $cmd $id
    $out = Join-Path $Dirs.jobs "$id.out.txt"; $err = Join-Path $Dirs.jobs "$id.err.txt"
    $proc = Start-Process -FilePath $s.file -ArgumentList $s.args -WorkingDirectory $cwd -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $null = $proc.Handle  # cache handle so ExitCode is readable later
    $script:Jobs[$id] = @{ proc = $proc; out = $out; err = $err; script = $s.path; command = $cmd; started = (Get-Date).ToString('o') }
    return [ordered]@{ jobId = $id; pid = $proc.Id; stdoutFile = $out; stderrFile = $err }
}

function Read-Tail([string]$path, [int]$max) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        $sr = New-Object IO.StreamReader($fs, $Utf8)
        return (Limit $sr.ReadToEnd() $max)[0]
    } finally { $fs.Dispose() }
}

function Get-Job2($p) {
    $max = [int](P $p 'maxChars' 20000)
    $jid = P $p 'id'
    $ids = if ($jid) { @($jid) } else { @($script:Jobs.Keys) }
    $res = @()
    foreach ($k in $ids) {
        $j = $script:Jobs[$k]
        if (-not $j) { throw "Unknown job '$k'" }
        $done = $j.proc.HasExited
        $r = [ordered]@{ jobId = $k; pid = $j.proc.Id; running = (-not $done); command = $j.command; started = $j.started }
        if ($done) { $r.exitCode = $j.proc.ExitCode }
        if ($jid) { $r.stdout = Read-Tail $j.out $max; $r.stderr = Read-Tail $j.err $max }
        $res += $r
    }
    if ($jid) { return $res[0] }
    return @{ jobs = $res }
}

function Stop-Job2($p) {
    $jid = Need $p 'id'; $j = $script:Jobs[$jid]
    if (-not $j) { throw "Unknown job '$jid'" }
    if (-not $j.proc.HasExited) { Stop-Tree $j.proc.Id }
    return @{ jobId = $jid; stopped = $true }
}

# ---------------------------------------------------------------- screen
function Get-ScreenInfo {
    $screens = @()
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $screens += @{ name = $s.DeviceName; primary = $s.Primary; x = $s.Bounds.X; y = $s.Bounds.Y; width = $s.Bounds.Width; height = $s.Bounds.Height }
    }
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $pt = New-Object SbxNative+POINT; [void][SbxNative]::GetCursorPos([ref]$pt)
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpi = $g.DpiX; $g.Dispose()
    return [ordered]@{ virtual = @{ x = $vs.X; y = $vs.Y; width = $vs.Width; height = $vs.Height }; screens = $screens; dpi = $dpi; cursor = @{ x = $pt.X; y = $pt.Y } }
}

function Save-Screenshot($p, [string]$id) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = [int](P $p 'x' $vs.X); $y = [int](P $p 'y' $vs.Y)
    $w = [int](P $p 'width' ($vs.Width - ($x - $vs.X))); $h = [int](P $p 'height' ($vs.Height - ($y - $vs.Y)))
    $hw = P $p 'hwnd'; $title = P $p 'title'
    if ($hw -or $title) {
        $win = Resolve-Window $p
        $r = New-Object SbxNative+RECT; [void][SbxNative]::GetWindowRect($win, [ref]$r)
        $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    }
    $scale = [double](P $p 'scale' 1.0)
    $name = [string](P $p 'name' ("shot_{0:yyyyMMdd_HHmmss_fff}.png" -f (Get-Date)))
    if ($name -notmatch '\.(png|jpg|jpeg)$') { $name += '.png' }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $pt = New-Object SbxNative+POINT; [void][SbxNative]::GetCursorPos([ref]$pt)
    if ((B (P $p 'cursor' $true))) {
        $cx = $pt.X - $x; $cy = $pt.Y - $y
        if ($cx -ge 0 -and $cy -ge 0 -and $cx -lt $w -and $cy -lt $h) {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Red), 2
            $g.DrawEllipse($pen, $cx - 8, $cy - 8, 16, 16); $g.DrawLine($pen, $cx - 12, $cy, $cx + 12, $cy); $g.DrawLine($pen, $cx, $cy - 12, $cx, $cy + 12)
            $pen.Dispose()
        }
    }
    $g.Dispose()
    if ($scale -gt 0 -and $scale -ne 1.0) {
        $nw = [Math]::Max(1, [int]($w * $scale)); $nh = [Math]::Max(1, [int]($h * $scale))
        $small = New-Object System.Drawing.Bitmap $nw, $nh
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($bmp, 0, 0, $nw, $nh); $g2.Dispose(); $bmp.Dispose(); $bmp = $small
    }
    $out = Join-Path $Dirs.shots $name
    $fmt = if ($name -match '\.jpe?g$') { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
    $bmp.Save($out, $fmt); $bmp.Dispose()
    return [ordered]@{ file = "shots/$name"; sandboxPath = $out; region = @{ x = $x; y = $y; width = $w; height = $h }; scale = $scale; cursor = @{ x = $pt.X; y = $pt.Y }
        note = 'Image pixel (px,py) -> screen (region.x + px/scale, region.y + py/scale)' }
}

# ---------------------------------------------------------------- mouse
function Move-Mouse([int]$x, [int]$y, [int]$steps = 0, [int]$durationMs = 0) {
    if ($steps -gt 1) {
        $pt = New-Object SbxNative+POINT; [void][SbxNative]::GetCursorPos([ref]$pt)
        for ($i = 1; $i -le $steps; $i++) {
            [void][SbxNative]::SetCursorPos([int]($pt.X + ($x - $pt.X) * $i / $steps), [int]($pt.Y + ($y - $pt.Y) * $i / $steps))
            if ($durationMs -gt 0) { Start-Sleep -Milliseconds ([Math]::Max(1, [int]($durationMs / $steps))) }
        }
    }
    [void][SbxNative]::SetCursorPos($x, $y)
}
function Get-Cursor { $pt = New-Object SbxNative+POINT; [void][SbxNative]::GetCursorPos([ref]$pt); return @{ x = $pt.X; y = $pt.Y } }

function Invoke-Click($p) {
    if ($null -ne (P $p 'x') -and $null -ne (P $p 'y')) { Move-Mouse ([int]$p.x) ([int]$p.y); Start-Sleep -Milliseconds 30 }
    $btn = [string](P $p 'button' 'left')
    $count = [int](P $p 'count' 1); if (B (P $p 'double' $false)) { $count = 2 }
    $mods = Get-Vks ([string](P $p 'modifiers' ''))
    foreach ($m in $mods) { [SbxNative]::KeyEvent($m, $true) }
    try {
        for ($i = 0; $i -lt $count; $i++) { [SbxNative]::MouseButton($btn, $true); Start-Sleep -Milliseconds 20; [SbxNative]::MouseButton($btn, $false); if ($i -lt $count - 1) { Start-Sleep -Milliseconds 60 } }
    } finally { [array]::Reverse($mods); foreach ($m in $mods) { [SbxNative]::KeyEvent($m, $false) } }
    return @{ cursor = (Get-Cursor); button = $btn; count = $count }
}

function Invoke-Drag($p) {
    $btn = [string](P $p 'button' 'left'); $steps = [int](P $p 'steps' 20); $dur = [int](P $p 'duration' 300)
    Move-Mouse ([int](Need $p 'x1')) ([int](Need $p 'y1')); Start-Sleep -Milliseconds 50
    [SbxNative]::MouseButton($btn, $true); Start-Sleep -Milliseconds 80
    try { Move-Mouse ([int](Need $p 'x2')) ([int](Need $p 'y2')) $steps $dur; Start-Sleep -Milliseconds 80 }
    finally { [SbxNative]::MouseButton($btn, $false) }
    return @{ cursor = (Get-Cursor) }
}

# ---------------------------------------------------------------- keyboard
$KeyMap = @{
    'ctrl' = 0x11; 'control' = 0x11; 'lctrl' = 0xA2; 'rctrl' = 0xA3; 'alt' = 0x12; 'menu' = 0x12; 'lalt' = 0xA4; 'ralt' = 0xA5
    'shift' = 0x10; 'lshift' = 0xA0; 'rshift' = 0xA1; 'win' = 0x5B; 'lwin' = 0x5B; 'rwin' = 0x5C; 'super' = 0x5B; 'cmd' = 0x5B; 'meta' = 0x5B
    'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20; 'spacebar' = 0x20
    'backspace' = 0x08; 'bksp' = 0x08; 'back' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D; 'ins' = 0x2D
    'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pgup' = 0x21; 'pagedown' = 0x22; 'pgdn' = 0x22
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
    'capslock' = 0x14; 'numlock' = 0x90; 'scrolllock' = 0x91; 'printscreen' = 0x2C; 'prtsc' = 0x2C; 'pause' = 0x13
    'apps' = 0x5D; 'contextmenu' = 0x5D; 'hangul' = 0x15; 'hanja' = 0x19; 'kana' = 0x15
    'volumemute' = 0xAD; 'volumedown' = 0xAE; 'volumeup' = 0xAF; 'medianext' = 0xB0; 'mediaprev' = 0xB1; 'mediastop' = 0xB2; 'mediaplay' = 0xB3
    'browserback' = 0xA6; 'browserforward' = 0xA7; 'browserrefresh' = 0xA8
    'multiply' = 0x6A; 'add' = 0x6B; 'subtract' = 0x6D; 'decimal' = 0x6E; 'divide' = 0x6F
    'plus' = 0xBB; 'minus' = 0xBD; 'comma' = 0xBC; 'period' = 0xBE
}
for ($i = 1; $i -le 24; $i++) { $KeyMap["f$i"] = 0x6F + $i }
for ($i = 0; $i -le 9; $i++) { $KeyMap["num$i"] = 0x60 + $i; $KeyMap["numpad$i"] = 0x60 + $i }

function Get-Vk([string]$name) {
    $n = $name.Trim()
    if ($n -eq '') { throw 'Empty key name' }
    $l = $n.ToLowerInvariant()
    if ($KeyMap.ContainsKey($l)) { return [uint16]$KeyMap[$l] }
    if ($l -match '^0x[0-9a-f]+$') { return [uint16]([Convert]::ToInt32($l.Substring(2), 16)) }
    if ($n.Length -eq 1) {
        $c = [char]$n.ToLowerInvariant()
        if ($c -match '[a-z0-9]') { return [uint16][int][char]$n.ToUpperInvariant() }
        $r = [SbxNative]::CharToVk($c)
        if ($r -ne -1) { return [uint16]($r -band 0xFF) }
    }
    throw "Unknown key '$name'"
}
function Get-Vks([string]$combo) {
    $list = New-Object System.Collections.Generic.List[uint16]
    if ([string]::IsNullOrWhiteSpace($combo)) { return , $list.ToArray() }
    # split on '+' but allow literal '+' key written as 'plus'
    foreach ($part in ($combo -split '\+')) { if ($part -ne '') { $list.Add((Get-Vk $part)) } }
    return , $list.ToArray()
}

function Invoke-Keys($p) {
    $keys = [string](Need $p 'keys')
    $repeat = [int](P $p 'repeat' 1); $delay = [int](P $p 'delay' 50)
    $sent = @()
    for ($r = 0; $r -lt $repeat; $r++) {
        foreach ($combo in ($keys -split '\s+' | Where-Object { $_ -ne '' })) {
            [SbxNative]::Chord((Get-Vks $combo)); $sent += $combo
            Start-Sleep -Milliseconds $delay
        }
    }
    return @{ sent = $sent }
}
function Invoke-KeyState($p, [bool]$down) {
    $vks = Get-Vks ([string](Need $p 'keys'))
    if (-not $down) { [array]::Reverse($vks) }
    foreach ($v in $vks) { [SbxNative]::KeyEvent($v, $down) }
    return @{ keys = $p.keys; down = $down }
}

# ---------------------------------------------------------------- windows
function Get-WindowInfo([IntPtr]$h) {
    $r = New-Object SbxNative+RECT; [void][SbxNative]::GetWindowRect($h, [ref]$r)
    $procId = [uint32]0; [void][SbxNative]::GetWindowThreadProcessId($h, [ref]$procId)
    $pname = $null; try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
    return [ordered]@{ hwnd = $h.ToInt64(); title = [SbxNative]::WindowText($h); class = [SbxNative]::ClassOf($h); pid = $procId; process = $pname
        x = $r.Left; y = $r.Top; width = $r.Right - $r.Left; height = $r.Bottom - $r.Top
        minimized = [SbxNative]::IsIconic($h); maximized = [SbxNative]::IsZoomed($h); foreground = ([SbxNative]::GetForegroundWindow() -eq $h) }
}

function Find-Windows($p) {
    $title = [string](P $p 'title' ''); $proc = [string](P $p 'process' ''); $cls = [string](P $p 'class' '')
    $all = B (P $p 'all' $false)
    $res = @()
    foreach ($h in [SbxNative]::TopWindows($all)) {
        $i = Get-WindowInfo $h
        if ($title -and -not ($i.title -like $title -or $i.title -like "*$title*")) { continue }
        if ($proc -and -not ($i.process -like $proc -or "$($i.process).exe" -like $proc)) { continue }
        if ($cls -and -not ($i.class -like $cls)) { continue }
        $res += $i
    }
    return $res   # callers wrap in @(); 'return ,@()' would count as one element
}

function Resolve-Window($p) {
    $hw = P $p 'hwnd'
    if ($hw) { $h = [IntPtr][int64]$hw; if (-not [SbxNative]::IsWindow($h)) { throw "hwnd $hw is not a window" }; return $h }
    $w = @(Find-Windows $p)
    if ($w.Count -eq 0) { throw "No window matches title='$(P $p 'title')' process='$(P $p 'process')'" }
    return [IntPtr][int64]$w[0].hwnd
}

function Invoke-WindowOp($p) {
    $op = [string](Need $p 'op'); $h = Resolve-Window $p
    switch ($op.ToLowerInvariant()) {
        'focus' { $ok = [SbxNative]::Focus($h) }
        'minimize' { $ok = [SbxNative]::ShowWindow($h, 6) }
        'maximize' { $ok = [SbxNative]::ShowWindow($h, 3) }
        'restore' { $ok = [SbxNative]::ShowWindow($h, 9) }
        'close' { $ok = [SbxNative]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        'move' {
            $r = New-Object SbxNative+RECT; [void][SbxNative]::GetWindowRect($h, [ref]$r)
            $ok = [SbxNative]::MoveWindow($h, [int](P $p 'x' $r.Left), [int](P $p 'y' $r.Top), [int](P $p 'width' ($r.Right - $r.Left)), [int](P $p 'height' ($r.Bottom - $r.Top)), $true)
        }
        default { throw "Unknown window op '$op' (focus|minimize|maximize|restore|close|move)" }
    }
    Start-Sleep -Milliseconds 150
    $info = $null; if ([SbxNative]::IsWindow($h)) { $info = Get-WindowInfo $h }
    return @{ ok = [bool]$ok; window = $info }
}

function Wait-Window($p) {
    $timeout = [double](P $p 'timeout' 30); $gone = B (P $p 'gone' $false)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        $w = @(Find-Windows $p)
        if (-not $gone -and $w.Count -gt 0) { return @{ found = $true; window = $w[0]; waitedMs = $sw.ElapsedMilliseconds } }
        if ($gone -and $w.Count -eq 0) { return @{ gone = $true; waitedMs = $sw.ElapsedMilliseconds } }
        Update-Heartbeat 'busy'; Start-Sleep -Milliseconds 250
    }
    throw "Timed out after $timeout s waiting for window title='$(P $p 'title')' process='$(P $p 'process')' gone=$gone"
}

# ---------------------------------------------------------------- UI Automation
function Get-UiaRoot($p) {
    Use-Uia
    if ((P $p 'hwnd') -or (P $p 'title') -or (P $p 'process')) { return [System.Windows.Automation.AutomationElement]::FromHandle((Resolve-Window $p)) }
    $fg = [SbxNative]::GetForegroundWindow()
    return [System.Windows.Automation.AutomationElement]::FromHandle($fg)
}
function ConvertTo-UiNode($el) {
    $c = $el.Current; $r = $c.BoundingRectangle
    $n = [ordered]@{ name = $c.Name; type = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''; id = $c.AutomationId; class = $c.ClassName; enabled = $c.IsEnabled }
    if (-not $r.IsEmpty -and -not [double]::IsInfinity($r.X)) { $n.rect = @{ x = [int]$r.X; y = [int]$r.Y; width = [int]$r.Width; height = [int]$r.Height }; $n.center = @{ x = [int]($r.X + $r.Width / 2); y = [int]($r.Y + $r.Height / 2) } }
    try { $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $n.value = $vp.Current.Value } catch {}
    return $n
}
function Get-UiTree($p) {
    $root = Get-UiaRoot $p; $depth = [int](P $p 'depth' 3); $max = [int](P $p 'max' 400)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $script:uiCount = 0
    function Walk($el, [int]$d) {
        $node = ConvertTo-UiNode $el; $script:uiCount++
        if ($d -lt $depth -and $script:uiCount -lt $max) {
            $kids = @(); $ch = $walker.GetFirstChild($el)
            while ($null -ne $ch -and $script:uiCount -lt $max) { $kids += (Walk $ch ($d + 1)); $ch = $walker.GetNextSibling($ch) }
            if ($kids.Count) { $node.children = $kids }
        }
        return $node
    }
    return @{ tree = (Walk $root 0); count = $script:uiCount; truncated = ($script:uiCount -ge $max) }
}
function Find-UiElements($p) {
    $root = Get-UiaRoot $p
    $name = [string](P $p 'name' ''); $aid = [string](P $p 'id' ''); $type = [string](P $p 'type' ''); $max = [int](P $p 'max' 50)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $res = New-Object System.Collections.ArrayList
    foreach ($el in $all) {
        $c = $el.Current
        if ($name -and -not ($c.Name -like $name)) { continue }
        if ($aid -and -not ($c.AutomationId -like $aid)) { continue }
        if ($type -and -not (($c.ControlType.ProgrammaticName -replace '^ControlType\.', '') -like $type)) { continue }
        [void]$res.Add($el); if ($res.Count -ge $max) { break }
    }
    return , $res   # ArrayList: comma keeps it intact (Count is correct even when empty)
}
function Invoke-UiFind($p) { $els = Find-UiElements $p; return @{ count = $els.Count; elements = @($els | ForEach-Object { ConvertTo-UiNode $_ }) } }
function Get-OneUi($p) {
    if (-not ((P $p 'name') -or (P $p 'id') -or (P $p 'type'))) { throw "Specify name, id or type of the element" }
    $els = Find-UiElements $p; $idx = [int](P $p 'index' 0)
    if ($els.Count -le $idx) { throw "No UI element matches name='$(P $p 'name')' id='$(P $p 'id')' type='$(P $p 'type')'" }
    return $els[$idx]
}
function Invoke-UiInvoke($p) {
    $el = Get-OneUi $p; $how = $null
    foreach ($pat in @([System.Windows.Automation.InvokePattern]::Pattern, [System.Windows.Automation.TogglePattern]::Pattern, [System.Windows.Automation.SelectionItemPattern]::Pattern, [System.Windows.Automation.ExpandCollapsePattern]::Pattern)) {
        $obj = $null
        if ($el.TryGetCurrentPattern($pat, [ref]$obj)) {
            switch ($pat.ProgrammaticName) {
                'InvokePatternIdentifiers.Pattern' { $obj.Invoke() }
                'TogglePatternIdentifiers.Pattern' { $obj.Toggle() }
                'SelectionItemPatternIdentifiers.Pattern' { $obj.Select() }
                'ExpandCollapsePatternIdentifiers.Pattern' { if ($obj.Current.ExpandCollapseState -eq 'Collapsed') { $obj.Expand() } else { $obj.Collapse() } }
            }
            $how = $pat.ProgrammaticName -replace 'PatternIdentifiers.Pattern', ''; break
        }
    }
    if (-not $how) {
        $r = $el.Current.BoundingRectangle
        if ($r.IsEmpty) { throw 'Element has no supported pattern and no bounding rectangle' }
        Invoke-Click ([pscustomobject]@{ x = [int]($r.X + $r.Width / 2); y = [int]($r.Y + $r.Height / 2) }) | Out-Null; $how = 'Click'
    }
    return @{ method = $how; element = (ConvertTo-UiNode $el) }
}
function Invoke-UiSetValue($p) {
    $el = Get-OneUi $p; $val = [string](Need $p 'value'); $obj = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$obj)) { $obj.SetValue($val); $how = 'ValuePattern' }
    else { $el.SetFocus(); Start-Sleep -Milliseconds 100; [SbxNative]::Chord(@([uint16]0x11, [uint16]0x41)); [SbxNative]::TypeText($val, 0); $how = 'Typed' }
    return @{ method = $how; element = (ConvertTo-UiNode $el) }
}

# ---------------------------------------------------------------- files / processes / system
function Resolve-BridgePath([string]$rel) { return (Join-Path $Bridge ($rel -replace '/', '\')) }

function Get-Listing($p) {
    $path = [string](P $p 'path' $env:USERPROFILE)
    $items = Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Select-Object -First ([int](P $p 'max' 500))
    return @{ path = (Resolve-Path -LiteralPath $path).Path; items = @($items | ForEach-Object {
        [ordered]@{ name = $_.Name; dir = $_.PSIsContainer; size = $(if ($_.PSIsContainer) { $null } else { $_.Length }); modified = $_.LastWriteTime.ToString('s') } }) }
}

function Invoke-Copy($p) {
    $src = [string](Need $p 'src'); $dst = [string](Need $p 'dst')
    if ($src -like 'bridge:*') { $src = Resolve-BridgePath $src.Substring(7) }
    if ($dst -like 'bridge:*') { $dst = Resolve-BridgePath $dst.Substring(7) }
    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    return @{ src = $src; dst = $dst }
}

function Get-SysInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { $_.IPAddress })
    return [ordered]@{ agent = $AgentVersion; computer = $env:COMPUTERNAME; user = $id.Name; elevated = $admin; os = $os.Caption; version = $os.Version
        memoryMB = [int]($os.TotalVisibleMemorySize / 1024); freeMemoryMB = [int]($os.FreePhysicalMemory / 1024); ipv4 = $ips
        psVersion = $PSVersionTable.PSVersion.ToString(); screen = (Get-ScreenInfo); bridge = $Bridge }
}

# ---------------------------------------------------------------- secure desktop
$SecureDir = Join-Path $Bridge 'secure'
$PolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Get-InputDesktopName {
    if (-not ('SbxSecure' -as [type])) { return 'Default' }
    try { $n = [SbxSecure]::InputDesktop(); if ($n) { return $n } } catch {}
    # OpenInputDesktop is refused from the user session while a secure desktop (Winlogon: UAC,
    # lock, Ctrl+Alt+Del) is the input desktop, so a failure here means "not ours". Ask the
    # SYSTEM helper, which can open it; without a helper report it as Unknown, never Default.
    if (Test-SecureHelperAlive) {
        try { $d = (Invoke-Secure 'desktop' @{} 4).desktop; if ($d) { return [string]$d } } catch {}
    }
    return 'Unknown'
}
function Test-SecureHelperAlive {
    $beat = Join-Path $SecureDir 'secure.status.json'
    for ($i = 0; $i -lt 5; $i++) {   # retry: a read can collide with the helper replacing the file
        if (-not (Test-Path $beat)) { return $false }
        try { $s = [IO.File]::ReadAllText($beat, $Utf8) | ConvertFrom-Json
            return (([DateTime]::UtcNow - [DateTime]::Parse($s.time).ToUniversalTime()).TotalSeconds -lt 12) } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}
# Route an input/capture op to the secure helper when the current input desktop is not Default
# (UAC / lock / Ctrl+Alt+Del), unless the caller forces direct. Honours an explicit -secure flag.
function Test-UseSecure($p) {
    if (B (P $p 'direct' $false)) { return $false }
    if (B (P $p 'secure' $false)) { return $true }
    if ((Get-InputDesktopName) -ne 'Default') { return $true }
    return $false
}
function Invoke-Secure($op, $params, [double]$timeoutSec = 15) {
    if (-not (Test-SecureHelperAlive)) {
        throw "Secure helper is not running. It must be armed while the agent is elevated (start/restart the sandbox, or run action 'secure_arm' before raising UAC). Input desktop is '$(Get-InputDesktopName)'."
    }
    $in = Join-Path $SecureDir 'inbox'; $out = Join-Path $SecureDir 'outbox'
    foreach ($d in $in, $out) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }
    $sid = '{0:yyyyMMddHHmmssfff}_{1}' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $req = [ordered]@{ id = $sid; op = $op }
    foreach ($k in @($params.PSBase.Keys)) { $req[$k] = $params[$k] }
    $tmp = Join-Path $in "$sid.tmp"
    [IO.File]::WriteAllText($tmp, ($req | ConvertTo-Json -Compress -Depth 8), $Utf8)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $in "$sid.json") -Force
    $outFile = Join-Path $out "$sid.json"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if (Test-Path -LiteralPath $outFile) {
            Start-Sleep -Milliseconds 20
            try { $txt = [IO.File]::ReadAllText($outFile, $Utf8) } catch { Start-Sleep -Milliseconds 40; continue }
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            $r = $txt | ConvertFrom-Json
            if (-not $r.ok) { throw "secure helper: $($r.error)" }
            return $r.result
        }
        Update-Heartbeat 'busy'; Start-Sleep -Milliseconds 60
    }
    throw "Timed out after $timeoutSec s waiting for secure helper op '$op'."
}

# Translate a space/plus key spec (e.g. 'ctrl+alt+del') to a flat VK array for one chord.
function ConvertTo-VkArray([string]$keys) {
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($combo in ($keys -split '\s+' | Where-Object { $_ -ne '' })) {
        foreach ($v in (Get-Vks $combo)) { $out.Add([int]$v) }
    }
    return , $out.ToArray()
}

function Initialize-Secure {
    # Idempotent. Registers + starts the SYSTEM helper task (AtStartup so it survives the reboot
    # into UAC-enabled mode). Needs elevation; at Medium integrity it logs and relies on an
    # existing AtStartup task from an earlier elevated boot.
    $broker = Join-Path $PSScriptRoot 'secure-broker.ps1'
    if (-not (Test-Path $broker)) { return @{ armed = $false; reason = 'secure-broker.ps1 missing' } }
    $existing = $null; try { $existing = Get-ScheduledTask -TaskName 'SbxSecure' -ErrorAction SilentlyContinue } catch {}
    if (-not $existing) {
        if (-not $script:IsElevated) { Log 'secure: not elevated and no SbxSecure task; cannot arm'; return @{ armed = $false; reason = 'not elevated' } }
        try {
            $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$broker`" -Bridge `"$Bridge`""
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
            $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $trg = New-ScheduledTaskTrigger -AtStartup
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName 'SbxSecure' -Action $act -Principal $pr -Trigger $trg -Settings $set -Force | Out-Null
            Log 'secure: registered SbxSecure task'
        } catch { Log "secure: register failed: $($_.Exception.Message)"; return @{ armed = $false; reason = $_.Exception.Message } }
    }
    try { if (-not (Test-SecureHelperAlive)) { Start-ScheduledTask -TaskName 'SbxSecure' -ErrorAction Stop } } catch { Log "secure: start failed: $($_.Exception.Message)" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 8 -and -not (Test-SecureHelperAlive)) { Start-Sleep -Milliseconds 300 }
    return @{ armed = (Test-SecureHelperAlive); registered = $true }
}

function Get-SecureStatus {
    $beat = Join-Path $SecureDir 'secure.status.json'; $s = $null
    if (Test-Path $beat) { try { $s = [IO.File]::ReadAllText($beat, $Utf8) | ConvertFrom-Json } catch {} }
    $task = $null; try { $task = (Get-ScheduledTask -TaskName 'SbxSecure' -ErrorAction SilentlyContinue).State } catch {}
    return [ordered]@{ armed = (Test-SecureHelperAlive); alive = (Test-SecureHelperAlive); task = $task
        inputDesktop = (Get-InputDesktopName); elevated = $script:IsElevated; helper = $s }
}

function Set-UacPolicy($p) {
    if (-not $script:IsElevated) { throw "Setting UAC policy needs an elevated agent. Restart the sandbox (fresh boot is elevated) and run this before raising UAC." }
    $mode = ([string](P $p 'mode' 'prompt')).ToLowerInvariant()
    # mode -> EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop
    $cfg = switch ($mode) {
        'off'     { @{ lua = 0; consent = 5; secure = 1 } }  # sandbox default: fully elevated, no prompts
        'prompt'  { @{ lua = 1; consent = 5; secure = 1 } }  # real UAC on the secure desktop (helper handles it)
        'desktop' { @{ lua = 1; consent = 5; secure = 0 } }  # UAC on the normal desktop (agent clicks directly)
        'allow'   { @{ lua = 1; consent = 0; secure = 0 } }  # elevate without prompting, UAC subsystem on
        default   { throw "Unknown uac mode '$mode' (off|prompt|desktop|allow)" }
    }
    $before = (Get-ItemProperty $PolicyKey).EnableLUA
    Set-ItemProperty $PolicyKey -Name EnableLUA -Value $cfg.lua -Type DWord
    Set-ItemProperty $PolicyKey -Name ConsentPromptBehaviorAdmin -Value $cfg.consent -Type DWord
    Set-ItemProperty $PolicyKey -Name PromptOnSecureDesktop -Value $cfg.secure -Type DWord
    $needReboot = ($before -ne $cfg.lua)
    $res = [ordered]@{ mode = $mode; enableLua = $cfg.lua; consentPromptBehaviorAdmin = $cfg.consent; promptOnSecureDesktop = $cfg.secure; rebootRequired = $needReboot }
    if ($needReboot -and (B (P $p 'reboot' $true))) {
        if ($mode -ne 'off') { try { Initialize-Secure | Out-Null } catch {} }  # ensure AtStartup helper survives the reboot
        $res.rebooting = $true
        $script:PendingReboot = $true
    }
    return $res
}

# ---------------------------------------------------------------- dispatch
$script:ExitCode = $null
$script:PendingReboot = $false
function Invoke-Action($req) {
    $p = $req.params; $id = [string]$req.id
    switch ([string]$req.action) {
        'ping' { return @{ pong = $true; agent = $AgentVersion; pid = $PID } }
        'info' { return (Get-SysInfo) }
        'exec' { return (Invoke-Exec $p $id) }
        'job_start' { return (Start-Job2 $p $id) }
        'job_status' { return (Get-Job2 $p) }
        'job_stop' { return (Stop-Job2 $p) }
        'launch' {
            $args2 = P $p 'args'; $sp = @{ FilePath = [string](Need $p 'path'); PassThru = $true }
            if ($args2) { $sp.ArgumentList = $args2 }
            if (P $p 'cwd') { $sp.WorkingDirectory = [string]$p.cwd }
            if (B (P $p 'admin' $false)) { $sp.Verb = 'RunAs' }
            $pr = Start-Process @sp
            if (B (P $p 'waitWindow' $false)) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                while ($sw.Elapsed.TotalSeconds -lt [double](P $p 'timeout' 20)) { $pr.Refresh(); if ($pr.MainWindowHandle -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 200 }
            }
            return @{ pid = $pr.Id; name = $pr.ProcessName }
        }
        'screen' { return (Get-ScreenInfo) }
        'screenshot' {
            if (Test-UseSecure $p) {
                $r = Invoke-Secure 'shot' @{ name = ([string](P $p 'name' "sec_$id.png")) }
                $r | Add-Member -NotePropertyName via -NotePropertyValue 'secure' -Force
                $r | Add-Member -NotePropertyName note -NotePropertyValue 'Captured on the secure desktop (full screen; scale/region/cursor options are ignored).' -Force
                return $r
            }
            return (Save-Screenshot $p $id)
        }
        'cursor' { return (Get-Cursor) }
        'move' {
            if (Test-UseSecure $p) { return (Invoke-Secure 'move' @{ x = [int](Need $p 'x'); y = [int](Need $p 'y') }) }
            Move-Mouse ([int](Need $p 'x')) ([int](Need $p 'y')) ([int](P $p 'steps' 0)) ([int](P $p 'duration' 0)); return @{ cursor = (Get-Cursor) }
        }
        'click' {
            if (Test-UseSecure $p) { return (Invoke-Secure 'click' @{ x = [int](Need $p 'x'); y = [int](Need $p 'y'); button = ([string](P $p 'button' 'left')); count = ([int]$(if (B (P $p 'double' $false)) { 2 } else { P $p 'count' 1 })) }) }
            return (Invoke-Click $p)
        }
        'mouse_down' { if ($null -ne (P $p 'x')) { Move-Mouse ([int]$p.x) ([int]$p.y) }; [SbxNative]::MouseButton([string](P $p 'button' 'left'), $true); return @{ cursor = (Get-Cursor) } }
        'mouse_up' { if ($null -ne (P $p 'x')) { Move-Mouse ([int]$p.x) ([int]$p.y) }; [SbxNative]::MouseButton([string](P $p 'button' 'left'), $false); return @{ cursor = (Get-Cursor) } }
        'drag' { return (Invoke-Drag $p) }
        'scroll' {
            if ($null -ne (P $p 'x')) { Move-Mouse ([int]$p.x) ([int]$p.y); Start-Sleep -Milliseconds 30 }
            [SbxNative]::Wheel([int](P $p 'clicks' -3), (B (P $p 'horizontal' $false))); return @{ cursor = (Get-Cursor); clicks = [int](P $p 'clicks' -3) }
        }
        'type' {
            $t = [string](Need $p 'text')
            if (Test-UseSecure $p) { return (Invoke-Secure 'type' @{ text = $t }) }
            [SbxNative]::TypeText($t, [int](P $p 'delay' 0)); return @{ typed = $t.Length }
        }
        'keys' {
            if (Test-UseSecure $p) {
                $keys = [string](Need $p 'keys'); $sent = @()
                for ($r = 0; $r -lt [int](P $p 'repeat' 1); $r++) {
                    foreach ($combo in ($keys -split '\s+' | Where-Object { $_ -ne '' })) {
                        # Get-Vks returns its array as one pipeline object; unroll it before mapping.
                        Invoke-Secure 'key' @{ vks = @((Get-Vks $combo) | ForEach-Object { [int]$_ }) } | Out-Null; $sent += $combo
                        Start-Sleep -Milliseconds ([int](P $p 'delay' 50))
                    }
                }
                return @{ sent = $sent; via = 'secure' }
            }
            return (Invoke-Keys $p)
        }
        'key_down' { return (Invoke-KeyState $p $true) }
        'key_up' { return (Invoke-KeyState $p $false) }
        'secure_arm' { return (Initialize-Secure) }
        'secure_status' { return (Get-SecureStatus) }
        'secure_sas' { return (Invoke-Secure 'sas' @{ asUser = (B (P $p 'asUser' $false)) }) }
        'uac' { return (Set-UacPolicy $p) }
        'windows' { return @{ windows = @(Find-Windows $p) } }
        'window' { return (Invoke-WindowOp $p) }
        'wait_window' { return (Wait-Window $p) }
        'foreground' { $h = [SbxNative]::GetForegroundWindow(); if ($h -eq [IntPtr]::Zero) { return @{ window = $null } }; return @{ window = (Get-WindowInfo $h) } }
        'ui_tree' { return (Get-UiTree $p) }
        'ui_find' { return (Invoke-UiFind $p) }
        'ui_invoke' { return (Invoke-UiInvoke $p) }
        'ui_set_value' { return (Invoke-UiSetValue $p) }
        'clipboard_get' { return @{ text = (Get-Clipboard -Raw) } }
        'clipboard_set' { Set-Clipboard -Value ([string](Need $p 'text')); return @{ ok = $true } }
        'ls' { return (Get-Listing $p) }
        'read_text' {
            $path = [string](Need $p 'path'); $max = [int](P $p 'maxChars' 200000)
            $t = [IO.File]::ReadAllText($path); $l = Limit $t $max
            return @{ path = $path; text = $l[0]; truncated = $l[1]; length = $t.Length }
        }
        'write_text' {
            $path = [string](Need $p 'path'); $parent = Split-Path -Parent $path
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
            if (B (P $p 'append' $false)) { [IO.File]::AppendAllText($path, [string]$p.text, $Utf8) } else { [IO.File]::WriteAllText($path, [string]$p.text, $Utf8) }
            return @{ path = $path; bytes = (Get-Item -LiteralPath $path).Length }
        }
        'copy' { return (Invoke-Copy $p) }
        'delete' { Remove-Item -LiteralPath ([string](Need $p 'path')) -Recurse -Force; return @{ deleted = $p.path } }
        'ps' {
            $name = [string](P $p 'name' '*')
            $roles = @{}; try { $roles = Get-AgentRoles (Get-ProcTable) } catch {}
            return @{ processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First ([int](P $p 'max' 200)) | ForEach-Object {
                $o = [ordered]@{ pid = $_.Id; name = $_.ProcessName; title = $_.MainWindowTitle; memMB = [int]($_.WorkingSet64 / 1MB); cpu = $(try { [math]::Round($_.CPU, 1) } catch { $null }) }
                if ($roles.ContainsKey($_.Id)) { $o.role = $roles[$_.Id] }
                $o }) }
        }
        'kill' {
            if (-not ((P $p 'pid') -or (P $p 'name'))) { throw "Specify pid or name" }
            $targets = @()
            if (P $p 'pid') { $targets += [int]$p.pid }
            if (P $p 'name') { $targets += @(Get-Process -Name ([string]$p.name) -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
            return (Stop-Guarded $targets (B (P $p 'unprotect' $false)))
        }
        'sleep' { Start-Sleep -Milliseconds ([int](P $p 'ms' 1000)); return @{ ok = $true } }
        'restart_agent' { $script:ExitCode = 0; return @{ restarting = $true } }
        'stop_agent' { $script:ExitCode = 99; return @{ stopping = $true } }
        'shutdown' { $script:ExitCode = 98; return @{ shuttingDown = $true } }
        default { throw "Unknown action '$($req.action)'" }
    }
}

# ---------------------------------------------------------------- main loop
Log "agent $AgentVersion started pid=$PID user=$env:USERNAME bridge=$Bridge elevated=$script:IsElevated"
Update-Heartbeat 'idle' -Force
# Arm the secure-desktop helper (best-effort; needs elevation to register, which the default
# sandbox boot has). An AtStartup trigger keeps it running after a reboot into UAC-enabled mode.
try { $armRes = Initialize-Secure; Log "secure arm: $($armRes | ConvertTo-Json -Compress)" } catch { Log "secure arm error: $($_.Exception.Message)" }
# The mapped folder is served over vSMB: plain polling sees new files only after the SMB directory
# cache expires (~10-20 s). An active change-notify watcher invalidates that cache, so new requests
# are seen in milliseconds. WaitForChanged doubles as the idle sleep.
$watcher = New-Object System.IO.FileSystemWatcher $Dirs.inbox, '*.json'
$watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'
$watcher.EnableRaisingEvents = $true
while ($true) {
    Update-Heartbeat 'idle'
    $files = @(Get-ChildItem -LiteralPath $Dirs.inbox -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { [void]$watcher.WaitForChanged([IO.WatcherChangeTypes]'Created, Renamed, Changed', 500); continue }
    foreach ($f in $files) {
        $work = "$($f.FullName).work"
        try { Move-Item -LiteralPath $f.FullName -Destination $work -ErrorAction Stop } catch { continue }  # still being written / taken
        $req = $null; $id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $resp = [ordered]@{ id = $id; ok = $false }
        try {
            $req = [IO.File]::ReadAllText($work, $Utf8) | ConvertFrom-Json
            if ($req.id) { $id = [string]$req.id; $resp.id = $id }
            $resp.action = $req.action
            Update-Heartbeat 'busy' -Force
            $resp.result = Invoke-Action $req
            $resp.ok = $true
        } catch {
            $resp.error = $_.Exception.Message
            $resp.where = "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line)".Trim()
            Log "ERROR $id $($req.action): $($_.Exception.Message)"
        }
        $resp.ms = $sw.ElapsedMilliseconds
        try { Write-JsonFile (Join-Path $Dirs.outbox "$id.json") $resp } catch { Log "WRITE FAIL $id $($_.Exception.Message)" }
        Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
        if ($script:PendingReboot) {
            Log 'uac policy change: rebooting'
            Update-Heartbeat 'stopped' -Force
            Start-Sleep -Milliseconds 500; & shutdown.exe /r /t 1 /f; exit 0
        }
        if ($null -ne $script:ExitCode) {
            Log "exit requested code=$($script:ExitCode)"
            Update-Heartbeat 'stopped' -Force
            if ($script:ExitCode -eq 98) { Start-Sleep -Milliseconds 500; & shutdown.exe /s /t 0 /f; exit 99 }
            exit $script:ExitCode
        }
    }
}
