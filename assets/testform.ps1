Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form; $f.Text = 'SBX Test Form'; $f.Width = 600; $f.Height = 420; $f.StartPosition = 'Manual'; $f.Left = 100; $f.Top = 100
$tb = New-Object Windows.Forms.TextBox; $tb.Multiline = $true; $tb.Left = 10; $tb.Top = 10; $tb.Width = 560; $tb.Height = 200; $tb.Name = 'editor'; $tb.ScrollBars = 'Vertical'
$btn = New-Object Windows.Forms.Button; $btn.Text = 'Save'; $btn.Left = 10; $btn.Top = 220; $btn.Width = 100; $btn.Height = 40
$lbl = New-Object Windows.Forms.Label; $lbl.Left = 120; $lbl.Top = 230; $lbl.Width = 450; $lbl.Text = 'events:'
$pnl = New-Object Windows.Forms.Panel; $pnl.Left = 10; $pnl.Top = 270; $pnl.Width = 560; $pnl.Height = 90; $pnl.BackColor = 'LightSteelBlue'
$log = { param($m) $lbl.Text = "events: $m"; Add-Content C:\Bridge\files\events.txt $m -Encoding UTF8 }
$btn.Add_Click({ Set-Content C:\Bridge\files\saved.txt $tb.Text -Encoding UTF8; & $log 'save-clicked' })
$pnl.Add_MouseDown({ & $log "down $($_.Button) $($_.X),$($_.Y)" })
$pnl.Add_MouseUp({ & $log "up $($_.Button) $($_.X),$($_.Y)" })
$pnl.Add_MouseDoubleClick({ & $log "dbl $($_.Button)" })
$f.Add_MouseWheel({ & $log "wheel $($_.Delta)" })
$tb.Add_MouseWheel({ & $log "wheel $($_.Delta)" })
$f.Add_KeyDown({ if ($_.Control -and $_.Shift -and $_.KeyCode -eq 'S') { & $log 'ctrl+shift+s' } }); $f.KeyPreview = $true
$f.Controls.AddRange(@($tb, $btn, $lbl, $pnl))
[void]$f.ShowDialog()
