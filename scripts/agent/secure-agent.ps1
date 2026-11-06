# Secure-desktop helper for Windows Sandbox. Runs as SYSTEM in the interactive session
# (started by secure-broker.ps1 attached to winsta0\Winlogon) and serves screenshot / input
# requests against whatever desktop is currently active (Default, the UAC secure desktop,
# the lock screen, or Ctrl+Alt+Del). The main agent routes to it when the input desktop is
# not Default, or when direct SendInput is refused (elevated / secure-desktop target).
#
# Protocol: JSON requests in <Bridge>\secure\inbox, responses in <Bridge>\secure\outbox.
param([string]$Bridge = 'C:\Bridge')
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Dir = Join-Path $Bridge 'secure'
$In = Join-Path $Dir 'inbox'; $Out = Join-Path $Dir 'outbox'; $Shots = Join-Path $Dir 'shots'
foreach ($d in $In, $Out, $Shots) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }
$Log = Join-Path $Dir 'secure.log'
$Beat = Join-Path $Dir 'secure.status.json'
function Log([string]$m) { try { [IO.File]::AppendAllText($Log, ('{0:HH:mm:ss.fff} {1}{2}' -f (Get-Date), $m, "`r`n"), $Utf8) } catch {} }

Add-Type -AssemblyName System.Drawing
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'secure.cs'))
if (-not ('SbxSecure' -as [type])) { Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing }

$id = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$sess = (Get-Process -Id $PID).SessionId

# One helper only. The broker re-spawns whenever the heartbeat looks stale (e.g. a slow first
# Add-Type), and duplicates used to pile up and overwrite each other's heartbeat.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\SbxSecureHelper')
$owned = $false
try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Log "helper pid $PID exiting: another helper holds the mutex"; exit 0 }
Log "helper up as $id session $sess pid $PID"

# Minimal key map so the helper can parse 'ctrl+alt+del' style specs on its own (independent of
# the main agent, which may be blocked behind a pending elevation prompt).
$KeyMap = @{
    'ctrl'=0x11;'control'=0x11;'alt'=0x12;'menu'=0x12;'shift'=0x10;'win'=0x5B;'lwin'=0x5B;'rwin'=0x5C
    'enter'=0x0D;'return'=0x0D;'tab'=0x09;'esc'=0x1B;'escape'=0x1B;'space'=0x20;'backspace'=0x08;'bksp'=0x08
    'delete'=0x2E;'del'=0x2E;'insert'=0x2D;'ins'=0x2D;'home'=0x24;'end'=0x23;'pageup'=0x21;'pagedown'=0x22
    'up'=0x26;'down'=0x28;'left'=0x25;'right'=0x27;'apps'=0x5D;'printscreen'=0x2C
}
for ($i = 1; $i -le 24; $i++) { $KeyMap["f$i"] = 0x6F + $i }
function Resolve-Vk([string]$name) {
    $l = $name.Trim().ToLowerInvariant()
    if ($KeyMap.ContainsKey($l)) { return [uint16]$KeyMap[$l] }
    if ($l -match '^0x[0-9a-f]+$') { return [uint16]([Convert]::ToInt32($l.Substring(2), 16)) }
    if ($name.Length -eq 1) {
        if ($name -match '[A-Za-z0-9]') { return [uint16][int][char]$name.ToUpperInvariant() }
        $r = [SbxSecure]::CharToVk([char]$name); if ($r -ne -1) { return [uint16]($r -band 0xFF) }
    }
    throw "Unknown key '$name'"
}

function Write-Json([string]$path, $obj) {
    $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Compress -Depth 8), $Utf8); Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Beat2 { try { Write-Json $Beat ([ordered]@{ pid = $PID; session = $sess; user = $id; time = [DateTime]::UtcNow.ToString('o'); desktop = ([SbxSecure]::InputDesktop()) }) } catch {} }

function Invoke-SecureOp($req) {
    $op = [string]$req.op
    switch ($op) {
        'ping' { return @{ pong = $true; session = $sess; desktop = ([SbxSecure]::InputDesktop()) } }
        'desktop' { return @{ desktop = ([SbxSecure]::InputDesktop()) } }
        'shot' {
            $name = if ($req.name) { [string]$req.name } else { "sec_$($req.id).png" }
            if ($name -notmatch '\.png$') { $name += '.png' }
            $path = Join-Path $Shots $name
            $desk = [SbxSecure]::Capture($path)
            return @{ file = "secure/shots/$name"; sandboxPath = $path; desktop = $desk }
        }
        'click' {
            $desk = [SbxSecure]::Click([int]$req.x, [int]$req.y, [string]$req.button, [int]$(if ($req.count) { $req.count } else { 1 }))
            return @{ clicked = @{ x = [int]$req.x; y = [int]$req.y }; desktop = $desk }
        }
        'move' { return @{ desktop = ([SbxSecure]::Move([int]$req.x, [int]$req.y)) } }
        'type' { return @{ typed = ([string]$req.text).Length; desktop = ([SbxSecure]::TypeText([string]$req.text)) } }
        'key' {
            $vks = [uint16[]]@($req.vks | ForEach-Object { [uint16][int]$_ })
            return @{ desktop = ([SbxSecure]::Chord($vks)) }
        }
        'keys' {
            $spec = [string]$req.keys; $sent = @(); $desk = $null
            for ($r = 0; $r -lt [int]$(if ($req.repeat) { $req.repeat } else { 1 }); $r++) {
                foreach ($combo in ($spec -split '\s+' | Where-Object { $_ -ne '' })) {
                    $vks = [uint16[]]@(($combo -split '\+' | Where-Object { $_ -ne '' }) | ForEach-Object { Resolve-Vk $_ })
                    $desk = [SbxSecure]::Chord($vks); $sent += $combo
                    Start-Sleep -Milliseconds $(if ($req.delay) { [int]$req.delay } else { 40 })
                }
            }
            return @{ sent = $sent; desktop = $desk }
        }
        'sas' {
            if (-not ('Sas' -as [type])) { Add-Type -MemberDefinition '[DllImport("sas.dll")] public static extern void SendSAS(bool asUser);' -Name Sas -Namespace N }
            [N.Sas]::SendSAS([bool]$req.asUser)
            return @{ sas = $true; desktop = ([SbxSecure]::InputDesktop()) }
        }
        default { throw "Unknown secure op '$op'" }
    }
}

$watcher = New-Object System.IO.FileSystemWatcher $In, '*.json'
$watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'
$watcher.EnableRaisingEvents = $true
$lastBeat = [DateTime]::MinValue
while ($true) {
    if (([DateTime]::UtcNow - $lastBeat).TotalSeconds -ge 2) { Beat2; $lastBeat = [DateTime]::UtcNow }
    $files = @(Get-ChildItem -LiteralPath $In -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { [void]$watcher.WaitForChanged([IO.WatcherChangeTypes]'Created, Renamed, Changed', 500); continue }
    foreach ($f in $files) {
        $work = "$($f.FullName).work"
        try { Move-Item -LiteralPath $f.FullName -Destination $work -ErrorAction Stop } catch { continue }
        $rid = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $resp = [ordered]@{ id = $rid; ok = $false }
        try {
            $req = [IO.File]::ReadAllText($work, $Utf8) | ConvertFrom-Json
            if ($req.id) { $rid = [string]$req.id; $resp.id = $rid }
            $resp.result = Invoke-SecureOp $req
            $resp.ok = $true
        } catch { $resp.error = $_.Exception.Message }
        try { Write-Json (Join-Path $Out "$rid.json") $resp } catch { Log "write fail $rid $($_.Exception.Message)" }
        Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
        Log "$rid $($req.op) ok=$($resp.ok) $($resp.error)"
    }
}
