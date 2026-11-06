# windows-sandbox-skill

**English** | [한국어](docs/README.ko.md) | [日本語](docs/README.ja.md) | [简体中文](docs/README.zh-CN.md)

A [Claude Code](https://claude.com/claude-code) skill that lets Claude drive **Windows Sandbox** from the host. Claude can run commands and capture their output, take screenshots, control the mouse and keyboard, automate UI controls, and move files in and out of a disposable Windows VM.

```
host: sbx.ps1 ──JSON──▶ %USERPROFILE%\WinSandboxBridge ═(mapped folder)═▶ C:\Bridge ──▶ agent.ps1 (inside sandbox)
```

## Features

| Area | Actions |
|---|---|
| Lifecycle | `check` `start` `stop` `status` `logs` `update-agent` (reload the agent without rebooting) |
| Commands | `exec` (PowerShell/cmd with stdout, stderr, exit code, timeout), `job_start` / `job_status` / `job_stop`, `launch`, `ps`, `kill` |
| Screen | `screenshot` (full screen, region or window; scaling; cursor marker), `screen`, `cursor` |
| Mouse | `move` `click` (left/right/middle/double/with modifiers) `drag` `scroll` `mouse_down` `mouse_up` |
| Keyboard | `type` (direct Unicode input, so Korean, CJK and emoji work), `keys` (`ctrl+shift+esc`, key sequences), `key_down` `key_up` |
| Windows | `windows` `foreground` `window` (focus/minimize/maximize/restore/close/move) `wait_window` |
| UI Automation | `ui_tree` `ui_find` `ui_invoke` `ui_set_value` |
| Files & clipboard | `push` `pull` `ls` `read_text` `write_text` `copy` `delete` `clipboard_get` `clipboard_set` |

See [references/actions.md](references/actions.md) for every parameter.

## Requirements

- Windows 10/11 Pro, Enterprise or Education
- Hardware virtualization (VT-x / AMD-V) enabled in BIOS
- The **Windows Sandbox** feature enabled, either in "Turn Windows features on or off" or from an elevated PowerShell:
  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
  ```
  Then use **Start → Power → Restart**. With Fast Startup on, "Shut down" and powering back on is not a real reboot, so the feature never finishes installing.
- Windows PowerShell 5.1, which ships with Windows. Nothing else to install.

## Installation

```bash
git clone https://github.com/Hyukya/windows-sandbox-skill ~/.claude/skills/windows-sandbox
```

Restart Claude Code and the skill is picked up. After that, ask for things like "test this installer in the sandbox" and Claude uses it on its own.

## Using it directly

```bash
SBX="powershell -NoProfile -ExecutionPolicy Bypass -File $HOME/.claude/skills/windows-sandbox/scripts/sbx.ps1"
$SBX check                                   # diagnose install / virtualization state
$SBX start                                   # boot the sandbox and wait for the agent (~30–90 s)
$SBX exec -command 'Get-ComputerInfo | Select OsName'
$SBX keys -keys 'win+r'; $SBX type -text 'cmd'; $SBX keys -keys enter
$SBX screenshot                              # PNG path in result.hostPath
$SBX click -x 640 -y 400
$SBX push -src ./setup.exe -dst 'C:\Users\WDAGUtilityAccount\Desktop\setup.exe'
$SBX stop
```

Output is always a single JSON object (`{"ok":true,"result":{...}}`).

## How it works

- `start` writes a `.wsb` configuration, maps the bridge folder to `C:\Bridge` inside the sandbox, and launches the agent through `LogonCommand`.
- The agent runs in the logged-in user session (`WDAGUtilityAccount`, elevated), so `SendInput`, screen capture and UI Automation act on the real desktop.
- Requests and responses are JSON files in the mapped folder. This works with networking disabled (`-noNetwork`), and a round trip takes about 0.6 s.
  - The mapped folder is served over vSMB. With plain polling, the SMB directory cache hides new files for 10–20 s, so the agent listens for change notifications with a FileSystemWatcher, which bypasses the cache.
- If the agent crashes, the launcher restarts it automatically.

## Known limitations

- The sandbox has no Store apps (new Notepad, Calculator, Paint, Terminal). Use Edge, cmd, PowerShell or software you install yourself.
- Input cannot reach the UAC secure desktop or the Ctrl+Alt+Del screen.
- Minimizing the sandbox window may pause rendering and input.
- Only one Windows Sandbox instance can run at a time.
- Do not put the bridge folder (`SBX_BRIDGE`) under AppData. When run from an MSIX-packaged app, AppData writes are redirected, and the sandbox fails with `0x80070003` (path not found).

## Disclaimer

This is an unofficial community project. It is not affiliated with, endorsed by, or sponsored by Microsoft. Windows and Windows Sandbox are trademarks of the Microsoft group of companies.

## License

[MIT](LICENSE)
