# sbx.ps1 action reference

**English** | [한국어](../docs/actions.ko.md) | [日本語](../docs/actions.ja.md) | [简体中文](../docs/actions.zh-CN.md)

Every response: `{"ok":bool, "action":..., "result":{...}, "error":"...", "ms":elapsedMs}`.
Pass parameters as `-name value`, `-name=value`, `-flag`, `-paramsJson '{...}'` or `-paramsFile f.json`.
`-textFile/-commandFile/-valueFile <host file>` puts the file's content into `text/command/value`.
Host-only options: `-wait <seconds>` (how long to wait for a response, default max(60, timeout+30)), `-force` (skip the heartbeat check).

## Host actions

| Action | Parameters | Description |
|---|---|---|
| `check` | | Diagnoses install / hypervisor / pending reboot / bridge path, returns `hints` |
| `start` | `-noNetwork` `-memory MB(4096)` `-vgpu` `-noClipboard` `-map "host[=sandbox][;ro]\|..."` `-timeout 240` | Writes a .wsb and launches it, waits for the agent heartbeat, returns `info` |
| `stop` | `-kill` | Guest shutdown → force-kills leftover processes |
| `status` | | Heartbeat (`ageSeconds`), sandbox processes |
| `logs` | `-lines 40` | Tail of agent.log / launcher.log |
| `update-agent` | | Copies `scripts/agent/*` to the bridge and restarts the agent |
| `push` | `-src hostPath -dst sandboxPath` | Copies a file/folder into the sandbox |
| `pull` | `-src sandboxPath -dst hostPath` | Copies a file/folder to the host |
| `call` | `call <action> -paramsJson ...` | Calls an arbitrary agent action |

## Agent actions (inside the sandbox)

### Commands / processes
| Action | Parameters | Result |
|---|---|---|
| `ping` | | `pong, agent, pid` |
| `info` | | OS, user, elevated, memory, IPv4, screen |
| `exec` | `command`*, `shell powershell\|cmd`, `timeout 120`, `cwd`, `maxChars 200000` | `exitCode, stdout, stderr, timedOut, durationMs, truncated` (UTF-8). Kills the process tree on timeout |
| `job_start` | `command`*, `shell`, `cwd` | `jobId, pid, stdoutFile` — runs in the background |
| `job_status` | `id` (omit for the full list), `maxChars 20000` | `running, exitCode, stdout, stderr` (tail) |
| `job_stop` | `id`* | Kills the process tree |
| `launch` | `path`*, `args`, `cwd`, `admin`, `waitWindow`, `timeout 20` | `pid, name` — launches a GUI app (detached) |
| `ps` | `name '*'` (wildcard), `max 200` | `pid, name, title, memMB, cpu` (by memory, descending) |
| `kill` | `pid` or `name` | `killed` |
| `sleep` | `ms 1000` | |

### Screen / mouse
| Action | Parameters | Result |
|---|---|---|
| `screen` | | Virtual screen, monitor list, dpi, cursor |
| `screenshot` | `name`, `scale 1.0`, `x y width height` (region) or `title/hwnd/process` (window), `cursor true`, JPEG if the name ends in `.jpg` | `file, hostPath, region, scale, cursor` |
| `cursor` | | `x, y` |
| `move` | `x* y*`, `steps`, `duration ms` | Smooth movement when steps>1 |
| `click` | `x y` (current position if omitted), `button left\|right\|middle\|x1\|x2`, `double`, `count`, `modifiers "ctrl+shift"` | |
| `mouse_down` / `mouse_up` | `x y`, `button` | Manual drag / long press |
| `drag` | `x1* y1* x2* y2*`, `button`, `steps 20`, `duration 300` | |
| `scroll` | `x y`, `clicks -3` (negative = down/left), `horizontal` | |

### Keyboard
| Action | Parameters | Description |
|---|---|---|
| `type` | `text`*, `delay ms 0` | Direct input via KEYEVENTF_UNICODE — Korean/CJK/emoji OK, independent of IME state. `\n`=Enter, `\t`=Tab |
| `keys` | `keys`*, `repeat 1`, `delay 50` | `"ctrl+shift+esc"` is simultaneous; space-separated is sequential: `"ctrl+a ctrl+c tab enter"` |
| `key_down` / `key_up` | `keys`* | Hold / release (e.g. hold shift and click) |

Key names: `ctrl alt shift win enter tab esc space backspace delete insert home end pageup pagedown up down left right f1..f24 capslock numlock printscreen pause apps hangul hanja num0..num9 multiply add subtract decimal divide plus minus comma period volumeup volumedown volumemute mediaplay medianext mediaprev browserback browserforward browserrefresh`, a single alphanumeric character, a single punctuation character (`/`, `;`, etc.), or a virtual-key code such as `0x41`. The `+` key itself is `plus`.

### Windows
| Action | Parameters | Result |
|---|---|---|
| `windows` | `title` (substring/wildcard), `process`, `class`, `all` (include hidden) | `hwnd, title, class, pid, process, x, y, width, height, minimized, maximized, foreground` |
| `foreground` | | Current foreground window |
| `window` | `op focus\|minimize\|maximize\|restore\|close\|move`*, target `hwnd\|title\|process`, `x y width height` for move | `ok, window` |
| `wait_window` | `title/process/class`, `timeout 30`, `gone` (wait until it disappears) | `found, window, waitedMs` |

### UI Automation
Target window: `hwnd|title|process` (foreground window if omitted). Element search: `name`, `id` (AutomationId), `type` (Button, Edit, MenuItem, ... — all `-like` wildcards), `index 0`.

| Action | Parameters | Result |
|---|---|---|
| `ui_tree` | `depth 3`, `max 400` | Tree: `name, type, id, class, enabled, rect, center, value` |
| `ui_find` | `name/id/type`, `max 50` | List of matching elements |
| `ui_invoke` | `name/id/type`*, `index` | Tries the Invoke → Toggle → SelectionItem → ExpandCollapse patterns in order, otherwise clicks the center. Returns `method` |
| `ui_set_value` | `name/id/type`*, `value`* | ValuePattern.SetValue, otherwise focus → Ctrl+A → typing |

### Files / clipboard
| Action | Parameters | Description |
|---|---|---|
| `ls` | `path`, `max 500` | name, dir, size, modified |
| `read_text` | `path`*, `maxChars` | Reads text |
| `write_text` | `path`*, `text`, `append` | Writes UTF-8 (no BOM), creates parent folders |
| `copy` | `src*`, `dst*` — `bridge:files/x` means `C:\Bridge\files\x` | Copies inside the sandbox (recursive) |
| `delete` | `path`* | Recursive delete |
| `clipboard_get` / `clipboard_set` | `text` | Sandbox clipboard |

### Agent lifecycle
| Action | Description |
|---|---|
| `restart_agent` | Exit code 0 → the launcher restarts it (reloads code) |
| `stop_agent` | Exit code 99 → the launcher exits too (the sandbox keeps running) |
| `shutdown` | After responding, shuts down the guest OS → the sandbox window closes (used by `stop`) |

## Bridge folder layout (host `%USERPROFILE%\WinSandboxBridge` = sandbox `C:\Bridge`)
`agent\` (code) `inbox\` `outbox\` `shots\` (screenshots) `files\` (transfer staging, free to use) `jobs\` (job output) `logs\` `status.json` (heartbeat every 2 s) `sandbox.wsb` (last launch config).
