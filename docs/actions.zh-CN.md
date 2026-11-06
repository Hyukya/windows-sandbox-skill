# sbx.ps1 操作参考

[English](../references/actions.md) | [한국어](actions.ko.md) | [日本語](actions.ja.md) | **简体中文**

所有响应：`{"ok":bool, "action":..., "result":{...}, "error":"...", "ms":耗时}`。
参数可以用 `-name value`、`-name=value`、`-flag`、`-paramsJson '{...}'`、`-paramsFile f.json` 传入。
`-textFile/-commandFile/-valueFile <主机文件>` 会把文件内容放入 `text/command/value`。
仅主机端选项：`-wait <秒>`（等待响应的时间，默认 max(60, timeout+30)），`-force`（跳过心跳检查）。

## 主机操作

| 操作 | 参数 | 说明 |
|---|---|---|
| `check` | | 诊断安装 / 虚拟机监控程序 / 待重启 / 桥接路径，返回 `hints` |
| `start` | `-noNetwork` `-memory MB(4096)` `-vgpu` `-noClipboard` `-map "host[=sandbox][;ro]\|..."` `-timeout 240` | 生成 .wsb 并启动，等待代理心跳，返回 `info` |
| `stop` | `-kill` | 关闭客户机 → 强制结束剩余进程 |
| `status` | | 心跳（`ageSeconds`）、沙盒进程 |
| `logs` | `-lines 40` | agent.log / launcher.log 的末尾 |
| `update-agent` | | 把 `scripts/agent/*` 复制到桥接文件夹并重启代理 |
| `run` | `-path 主机文件\|文件夹\|URL` 或 `-sandboxPath`、`-args`、`-wait`、`-timeout 600`、`-silent`(msi)、`-withFolder`、`-entry`(zip/iso 内的文件)、`-dst 沙盒文件夹(桌面)`、`-as 类型`、`-waitWindow`、`-screenshot`、`-settle 3`、`-noStart`、`-bootTimeout 240` + `start` 选项 | 必要时启动 → 复制 → 按类型运行。结果: `kind, mode(wait\|launch), sandboxPath, command, exec{exitCode,stdout,stderr}` 或 `launch{pid}`、`extractedTo/mountedAt`、`screenshot`、`boot`。类型表见 SKILL.md |
| `host_screenshot` | `-area display\|window`（display = 仅客户机屏幕）、`-method auto\|print\|screen`、`-x -y -width -height`（裁剪，沙盒坐标）、`-scale 1.0`、`-name`（`.jpg` 则为 JPEG）、`-dst 主机路径`、`-restore`、`-activate`、`-settle 0.7` | **从主机**截取沙盒窗口。无需代理，因此在客户机禁止截屏、代理卡死、启动中也能用（UAC/锁屏请用 `secure-shot`）。`print`（PrintWindow）在窗口被遮挡时也可用；`screen` 复制主机屏幕，窗口须在最前。`auto` = print，图像为空时改用 screen。窗口最小化时须加 `-restore`，否则失败。结果：`hostPath, method, area, blank, region, scale, window, hostRect, warnings`（display 的坐标换算与 `screenshot` 相同）。安全桌面期间以及主机桌面未显示时（锁定/最小化的远程桌面）返回黑屏（`blank: true`） |
| `push` | `-src 主机路径 -dst 沙盒路径` | 把文件/文件夹复制到沙盒 |
| `pull` | `-src 沙盒路径 -dst 主机路径` | 把文件/文件夹复制到主机 |
| `call` | `call <action> -paramsJson ...` | 调用任意代理操作 |
| `secure-shot` | `-name` | **当前输入桌面**（含 UAC/锁屏/Ctrl+Alt+Del）全屏截图。`file, hostPath, desktop` |
| `secure-click` | `-x* -y*`、`-button`、`-count` | 在当前输入桌面点击 |
| `secure-type` | `-text*` | 在当前输入桌面输入 Unicode 文本 |
| `secure-keys` | `-keys*`、`-repeat`、`-delay` | 在当前输入桌面发送按键（`ctrl+alt+del` 形式） |
| `secure-move` | `-x* -y*` | 在当前输入桌面移动光标 |
| `secure-desktop` | | 当前输入桌面名称（`Default`、`Winlogon` 等） |
| `secure-sas` | `-asUser` | 发送安全注意序列（打开 Ctrl+Alt+Del 界面） |

`secure-*` 主机操作绕过代理，**直接**与 SYSTEM 助手通信。当 UAC 提示出现时代理会被阻塞（其 `launch`/`exec` 在等待提示被应答），因此使用此直接通道。

## 代理操作（沙盒内部）

### 命令 / 进程
| 操作 | 参数 | 结果 |
|---|---|---|
| `ping` | | `pong, agent, pid` |
| `info` | | 操作系统、用户、elevated、内存、IPv4、屏幕 |
| `exec` | `command`*、`shell powershell\|cmd`、`timeout 120`、`cwd`、`maxChars 200000` | `exitCode, stdout, stderr, timedOut, durationMs, truncated`（UTF-8）。超时时结束进程树 |
| `job_start` | `command`*、`shell`、`cwd` | `jobId, pid, stdoutFile` — 在后台运行 |
| `job_status` | `id`（省略则列出全部）、`maxChars 20000` | `running, exitCode, stdout, stderr`（末尾） |
| `job_stop` | `id`* | 结束进程树 |
| `launch` | `path`*、`args`、`cwd`、`admin`、`waitWindow`、`timeout 20` | `pid, name` — 启动 GUI 应用（分离运行） |
| `ps` | `name '*'`（通配符）、`max 200` | `pid, name, title, memMB, cpu`（按内存降序） |
| `kill` | `pid` 或 `name` | `killed` |
| `sleep` | `ms 1000` | |

### 屏幕 / 鼠标
| 操作 | 参数 | 结果 |
|---|---|---|
| `screen` | | 虚拟屏幕、显示器列表、dpi、光标 |
| `screenshot` | `name`、`scale 1.0`、`x y width height`（区域）或 `title/hwnd/process`（窗口）、`cursor true`、名称以 `.jpg` 结尾则保存为 JPEG | `file, hostPath, region, scale, cursor` |
| `cursor` | | `x, y` |
| `move` | `x* y*`、`steps`、`duration ms` | steps>1 时平滑移动 |
| `click` | `x y`（省略则为当前位置）、`button left\|right\|middle\|x1\|x2`、`double`、`count`、`modifiers "ctrl+shift"` | |
| `mouse_down` / `mouse_up` | `x y`、`button` | 手动拖动 / 长按 |
| `drag` | `x1* y1* x2* y2*`、`button`、`steps 20`、`duration 300` | |
| `scroll` | `x y`、`clicks -3`（负数 = 向下/向左）、`horizontal` | |

### 键盘
| 操作 | 参数 | 说明 |
|---|---|---|
| `type` | `text`*、`delay ms 0` | 通过 KEYEVENTF_UNICODE 直接输入 — 中文/韩文/表情符号均可，与输入法状态无关。`\n`=Enter，`\t`=Tab |
| `keys` | `keys`*、`repeat 1`、`delay 50` | `"ctrl+shift+esc"` 为同时按下，空格分隔为依次按下：`"ctrl+a ctrl+c tab enter"` |
| `key_down` / `key_up` | `keys`* | 按住 / 松开（例如按住 shift 再点击） |

键名：`ctrl alt shift win enter tab esc space backspace delete insert home end pageup pagedown up down left right f1..f24 capslock numlock printscreen pause apps hangul hanja num0..num9 multiply add subtract decimal divide plus minus comma period volumeup volumedown volumemute mediaplay medianext mediaprev browserback browserforward browserrefresh`、单个字母或数字、单个标点符号（`/`、`;` 等），或 `0x41` 这样的虚拟键码。`+` 键本身写作 `plus`。

### 窗口
| 操作 | 参数 | 结果 |
|---|---|---|
| `windows` | `title`（部分匹配/通配符）、`process`、`class`、`all`（包括隐藏窗口） | `hwnd, title, class, pid, process, x, y, width, height, minimized, maximized, foreground` |
| `foreground` | | 当前前台窗口 |
| `window` | `op focus\|minimize\|maximize\|restore\|close\|move`*、目标 `hwnd\|title\|process`，move 时需 `x y width height` | `ok, window` |
| `wait_window` | `title/process/class`、`timeout 30`、`gone`（等待其消失） | `found, window, waitedMs` |

### UI Automation
目标窗口：`hwnd|title|process`（省略则为前台窗口）。元素搜索：`name`、`id`（AutomationId）、`type`（Button、Edit、MenuItem 等 — 均为 `-like` 通配符）、`index 0`。

| 操作 | 参数 | 结果 |
|---|---|---|
| `ui_tree` | `depth 3`、`max 400` | 树：`name, type, id, class, enabled, rect, center, value` |
| `ui_find` | `name/id/type`、`max 50` | 匹配元素列表 |
| `ui_invoke` | `name/id/type`*、`index` | 依次尝试 Invoke → Toggle → SelectionItem → ExpandCollapse 模式，都没有则点击中心。返回 `method` |
| `ui_set_value` | `name/id/type`*、`value`* | ValuePattern.SetValue，没有则聚焦 → Ctrl+A → 输入 |

### 文件 / 剪贴板
| 操作 | 参数 | 说明 |
|---|---|---|
| `ls` | `path`、`max 500` | 名称、dir、大小、修改时间 |
| `read_text` | `path`*、`maxChars` | 读取文本 |
| `write_text` | `path`*、`text`、`append` | 以 UTF-8（无 BOM）写入，自动创建上级文件夹 |
| `copy` | `src*`、`dst*` — `bridge:files/x` 即 `C:\Bridge\files\x` | 在沙盒内复制（递归） |
| `delete` | `path`* | 递归删除 |
| `clipboard_get` / `clipboard_set` | `text` | 沙盒剪贴板 |

### 代理生命周期
| 操作 | 说明 |
|---|---|
| `restart_agent` | 退出码 0 → 启动器重启代理（重新加载代码） |
| `stop_agent` | 退出码 99 → 启动器也退出（沙盒保持运行） |
| `shutdown` | 响应后关闭客户机操作系统 → 沙盒窗口关闭（`stop` 使用） |

### 安全桌面（UAC / 锁屏 / Ctrl+Alt+Del）
SYSTEM 助手（计划任务 `SbxSecure`，在**提权的**沙盒启动时自动驻留，AtStartup 触发器使其在重启后仍存活）运行于交互会话，可对当前活动的任何桌面截图/点击/输入——包括代理自身无法触达的安全桌面。用上面的主机直连 `secure-*` 操作驱动它（当提示阻塞代理时推荐），或交给代理自动路由（输入桌面不是 `Default` 时 `screenshot`/`click`/`type`/`keys` 自动转给助手；`-secure` 强制，`-direct` 保持直接路径）。

| 操作 | 参数 | 说明 |
|---|---|---|
| `uac` | `mode off\|prompt\|desktop\|allow`（默认 `prompt`）、`reboot true` | 设置 UAC 策略，若 `EnableLUA` 改变则重启（助手通过 AtStartup 重新驻留）。`off`=沙盒默认（完全提权、无提示），`prompt`=安全桌面上的真实 UAC，`desktop`=普通桌面上的 UAC（代理直接点击），`allow`=不提示直接提权。**需要提权的代理**（全新启动），在触发 UAC 前运行。返回 `rebootRequired/rebooting` |
| `secure_status` | | `armed, task, inputDesktop, elevated, helper{pid,desktop,...}` |
| `secure_arm` | | 重新注册/重启助手（幂等，注册需提权） |
| `secure_sas` | `asUser` | 从 SYSTEM 发送安全注意序列（Ctrl+Alt+Del 界面） |

点击真实 UAC 提示的典型流程：`uac -mode prompt`（重启）→ 运行会提权的安装程序/应用 → `secure-shot` 查看提示 → 对 **是/Yes** 执行 `secure-click -x -y`。默认沙盒为 `EnableLUA=0`，安装会静默自动提权，除非切换到 `prompt`/`desktop` 模式，否则不会出现提示。

## 桥接文件夹结构（主机 `%USERPROFILE%\WinSandboxBridge` = 沙盒 `C:\Bridge`）
`agent\`（代码） `inbox\` `outbox\` `shots\`（截图） `files\`（传输暂存区，可自由使用） `jobs\`（作业输出） `logs\` `status.json`（每 2 秒一次心跳） `sandbox.wsb`（上次启动的配置）。
