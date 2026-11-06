---
name: windows-sandbox
description: Control Windows Sandbox (the disposable Windows VM built into Windows 10/11 Pro) from the host — start/stop it, run PowerShell/cmd commands with captured output and exit codes, take screenshots, drive the mouse and keyboard (click, drag, scroll, type Unicode/CJK text, hotkeys), find/focus/close windows, use UI Automation to inspect and click controls, copy files in and out, use the clipboard, and manage processes and background jobs. Use this skill whenever the user wants to do anything inside Windows Sandbox or a throwaway Windows VM — testing an installer or untrusted exe, reproducing a bug on a clean Windows, GUI automation in isolation, "run this in the sandbox", "test on a clean Windows", "샌드박스에서 실행해줘", "윈도우 샌드박스 제어", "サンドボックスで実行して", "在沙盒里运行" — even if they don't say "skill".
---

# Windows Sandbox control

Call `scripts/sbx.ps1` on the host. An agent running inside the sandbox (in the logged-in user session) executes the request and returns the result as JSON.

```
host: sbx.ps1 ──JSON──▶ %USERPROFILE%\WinSandboxBridge\inbox ═(mapped folder)═▶ C:\Bridge\inbox ──▶ agent.ps1 (in sandbox)
host ◀──JSON── outbox ◀════════════════════════════════════════════════════════ (result, screenshots in shots\)
```

- No network is needed. All traffic goes through the mapped folder, and a round trip takes about 0.6 s.
- The agent runs in the interactive `WDAGUtilityAccount` session (elevated), so SendInput, screen capture and UI Automation act on the real desktop.

## How to call it

```bash
SBX="powershell -NoProfile -ExecutionPolicy Bypass -File $HOME/.claude/skills/windows-sandbox/scripts/sbx.ps1"
$SBX <action> -name value -flag ...
```

- Output is always a single JSON object: `{"ok":true,"result":{...}}` on success, `{"ok":false,"error":"..."}` on failure, and the process exits with code 1 on failure.
- **Call it from the Bash tool.** When PowerShell 5.1 invokes a native exe, double quotes inside arguments get mangled. For complex commands or long text, the safest route is to write them to a file and pass `-commandFile` / `-textFile` / `-valueFile`.
- Value syntax: `-x 100`, `-name=value`, or a bare switch (`-double`). Negative numbers (`-clicks -3`) and string values starting with `-` (`-args '-NoProfile -File x.ps1'`) work too.
- To pass arbitrary parameters, use `-paramsJson '{"x":1}'` or `-paramsFile p.json`.

## Basic workflow

1. **Check and start**: run `$SBX check` first to see the install state. Then run `$SBX start` (boot takes about 60–90 s and returns `info` when done). If it is already running you get `alreadyRunning`.
   - Options: `-noNetwork`, `-memory 8192`, `-vgpu`, `-noClipboard`, `-map "D:\proj"` (mapped onto the sandbox desktop), `-map "D:\in=C:\in;ro|D:\out=C:\out"`.
   - Only one sandbox can run at a time. If another sandbox window is open, start fails; close it or run `$SBX stop -kill`.
2. **Observe, act, re-observe loop**: when driving a GUI, take a `screenshot` → view the returned `hostPath` image with the Read tool → run `click`/`type`/`keys` → take another `screenshot` to confirm the result. Input is only guaranteed to have been *sent*, not to have done what you intended, so do not move on without checking.
3. **Shut down**: run `$SBX stop`. It shuts down from inside the sandbox and force-kills it if that fails. **The sandbox is disposable.** Closing it wipes all state inside, so `pull` out anything you want to keep first.

## Choosing what to use (most reliable first)

| Goal | First choice | Fallback |
|---|---|---|
| Install / configure / file work | `exec` (captures stdout, stderr, exitCode) | `job_start` (long-running work) |
| Click a button or menu | `ui_invoke -title <window> -name <name>` | find coordinates with `screenshot`, then `click -x -y` |
| Fill an input field | `ui_set_value` | `click` → `keys ctrl+a` → `type` |
| Shortcuts | `keys -keys "ctrl+shift+esc"` | `key_down`/`key_up` |
| Launch a GUI app | `launch -path ... -waitWindow`, then `wait_window` | `exec -command "Start-Process ..."` |

Coordinate clicks break easily with resolution, window position and animations. Prefer commands (`exec`) or UI Automation when they can do the job. A UIA element's `center` coordinates can be passed straight to `click`.

## Common commands

```bash
$SBX exec -command 'Get-ComputerInfo | Select OsName,OsVersion' -timeout 60
$SBX exec -shell cmd -command 'ipconfig /all'
$SBX exec -commandFile ./install.ps1 -timeout 900          # long/complex scripts
$SBX job_start -command '& C:\setup.exe /S' ; $SBX job_status -id <jobId>
$SBX push -src ./app.msi -dst 'C:\Users\WDAGUtilityAccount\Desktop\app.msi'
$SBX pull -src 'C:\logs' -dst ./sandbox-logs
$SBX launch -path 'msedge.exe' -args 'https://example.com' -waitWindow
$SBX wait_window -title '*Setup*' -timeout 60
$SBX window -title '*Setup*' -op focus        # focus|minimize|maximize|restore|close|move
$SBX screenshot                                # full screen -> result.hostPath
$SBX screenshot -title '*Setup*' -scale 0.5    # window region only, downscaled
$SBX click -x 640 -y 400 [-button right] [-double] [-modifiers ctrl]
$SBX drag -x1 100 -y1 100 -x2 400 -y2 300
$SBX scroll -x 640 -y 400 -clicks -5           # negative = down
$SBX type -text 'Hello 안녕하세요 こんにちは'      # direct Unicode input (IME-independent)
$SBX keys -keys 'ctrl+a ctrl+c'                 # space = sequential, + = simultaneous
$SBX ui_tree -title '*Setup*' -depth 3
$SBX ui_invoke -title '*Setup*' -name 'Next*'
$SBX clipboard_get ; $SBX clipboard_set -text '...'
$SBX ps -name 'set*' ; $SBX kill -name setup
```

The full list of actions and parameters is in `references/actions.md`. Read it when using an action for the first time or when unsure about a parameter.

## Coordinates and screenshots

- Coordinates are physical pixels on the sandbox screen with origin (0,0). Get the screen size from `screen` or from `info.screen` in the `start` result. By default it follows the host window size (e.g. 1536×832).
- If you downscaled with `screenshot -scale s` or captured only a region with `-title`/`-x -y -width -height`, image pixel (px,py) maps to screen coordinate `(region.x + px/s, region.y + py/s)`. Use the `region` and `scale` values in the result.
- Screenshots mark the current cursor position with a red crosshair (turn it off with `-cursor false`).
- If the sandbox window is minimized, rendering and input may stall. If the screen is black or input has no effect, ask the user to restore the sandbox window.

## Limitations to know

- **No Store apps.** Inside the sandbox, Store apps such as Notepad, Calculator, Paint and Terminal exit right after launch. Use built-in apps such as Edge, cmd, PowerShell, Explorer and Registry Editor, or software you install yourself.
- SendInput cannot reach the UAC or secure desktop (Ctrl+Alt+Del) screens. Since the agent is already elevated, ordinary installs don't show a UAC prompt.
- Some apps, such as WinForms apps, expose UIA ControlType as `Pane` and leave AutomationId empty. If `-type`/`-id` finds nothing, search by `-name` alone, and check the real structure with `ui_tree` first.
- `exec` is processed sequentially. Other requests wait while it runs, so run anything that takes more than a few minutes with `job_start` and observe the screen in the meantime.
- The bridge folder is `%USERPROFILE%\WinSandboxBridge` and can be changed with the `SBX_BRIDGE` environment variable. **Do not put it under AppData.** In MSIX-packaged apps such as Claude Desktop, AppData writes are redirected to the package folder, and the sandbox fails with `0x80070003 The system cannot find the path specified`.

## Troubleshooting

- If `check` returns `installed:false` or `rebootPending:true`: tell the user to enable Windows Sandbox in "Turn Windows features on or off" and then use **Start → Power → Restart**. "Shut down" followed by powering back on does not count as a reboot because of Fast Startup. VT-x/AMD-V must also be enabled in BIOS. The user has to change these settings themselves.
- If the agent doesn't respond, check `$SBX status` (heartbeat age) and `$SBX logs`. If the agent dies, the launcher restarts it after 1 s.
- After changing the agent code, run `$SBX update-agent` to apply it without rebooting.
- A test form for verifying behavior is in `assets/testform.ps1`. `push` it in and start it with `launch`; click, key, wheel and drag events are logged to `C:\Bridge\files\events.txt`.
