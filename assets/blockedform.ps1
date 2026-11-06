# Test window that opts out of screen capture with SetWindowDisplayAffinity, for checking
# screenshot's blockedWindows detection and the host cross-capture (screenshot -cross,
# run -screenshot). In-guest captures show it black (monitor) or not at all (exclude);
# host_screenshot shows its content.
#   push it in, then: launch -path powershell.exe -args '-ExecutionPolicy Bypass -File C:\...\blockedform.ps1 -Mode exclude'
param([ValidateSet('monitor', 'exclude')][string]$Mode = 'monitor')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Sbx -Name Wda -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(System.IntPtr h, uint a);'

$f = New-Object System.Windows.Forms.Form
$f.Text = "Capture Blocked ($Mode)"
$f.Size = New-Object System.Drawing.Size 520, 300
$f.StartPosition = 'CenterScreen'
$f.BackColor = [System.Drawing.Color]::FromArgb(30, 120, 200)
$l = New-Object System.Windows.Forms.Label
$l.Text = "This window blocks screen capture`r`n(SetWindowDisplayAffinity: $Mode)"
$l.ForeColor = [System.Drawing.Color]::White
$l.Font = New-Object System.Drawing.Font 'Segoe UI', 16
$l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'
$f.Controls.Add($l)
$f.Add_Shown({
    $a = if ($Mode -eq 'exclude') { 0x11 } else { 0x1 }
    if (-not [Sbx.Wda]::SetWindowDisplayAffinity($f.Handle, $a)) { $l.Text = "SetWindowDisplayAffinity failed" }
})
[void]$f.ShowDialog()
