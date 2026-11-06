# windows-sandbox-skill

[English](../README.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | **简体中文**

一个从主机控制 **Windows 沙盒** 的 [Claude Code](https://claude.com/claude-code) 技能。Claude 可以执行命令并获取输出、截取屏幕、操作鼠标和键盘、自动化 UI 控件，并与一次性的 Windows 虚拟机互传文件。

```
host: sbx.ps1 ──JSON──▶ %USERPROFILE%\WinSandboxBridge ═(mapped folder)═▶ C:\Bridge ──▶ agent.ps1 (沙盒内)
```

## 功能

| 类别 | 操作 |
|---|---|
| 生命周期 | `check` `start` `stop` `status` `logs` `update-agent`（无需重启即可更新代理） |
| 命令 | `exec`（PowerShell/cmd，含 stdout、stderr、退出码、超时），`job_start` / `job_status` / `job_stop`，`launch`，`ps`，`kill` |
| 屏幕 | `screenshot`（全屏/区域/窗口，缩放，光标标记），`screen`，`cursor` |
| 鼠标 | `move` `click`（左键/右键/中键/双击/组合键） `drag` `scroll` `mouse_down` `mouse_up` |
| 键盘 | `type`（直接输入 Unicode，中文、韩文、表情符号均可），`keys`（`ctrl+shift+esc`、按键序列），`key_down` `key_up` |
| 窗口 | `windows` `foreground` `window`（focus/minimize/maximize/restore/close/move） `wait_window` |
| UI 自动化 | `ui_tree` `ui_find` `ui_invoke` `ui_set_value` |
| 文件与剪贴板 | `push` `pull` `ls` `read_text` `write_text` `copy` `delete` `clipboard_get` `clipboard_set` |

全部参数请参阅 [操作参考](actions.zh-CN.md)。

## 系统要求

- Windows 10/11 专业版、企业版或教育版
- 在 BIOS 中启用硬件虚拟化（VT-x / AMD-V）
- 启用 **Windows 沙盒** 功能：在“启用或关闭 Windows 功能”中开启，或在管理员 PowerShell 中运行：
  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
  ```
  然后选择 **开始 → 电源 → 重启**。如果开启了快速启动，“关机”后再开机并不是真正的重启，功能将无法完成安装。
- Windows PowerShell 5.1（Windows 自带），无需安装其他软件。

## 安装

```bash
git clone https://github.com/Hyukya/windows-sandbox-skill ~/.claude/skills/windows-sandbox
```

重启 Claude Code 后即可识别该技能。之后只要提出类似“在沙盒里测试这个安装程序”的请求，Claude 就会自动使用它。

## 直接使用

```bash
SBX="powershell -NoProfile -ExecutionPolicy Bypass -File $HOME/.claude/skills/windows-sandbox/scripts/sbx.ps1"
$SBX check                                   # 诊断安装/虚拟化状态
$SBX start                                   # 启动沙盒并等待代理就绪（约 30–90 秒）
$SBX exec -command 'Get-ComputerInfo | Select OsName'
$SBX keys -keys 'win+r'; $SBX type -text 'cmd'; $SBX keys -keys enter
$SBX screenshot                              # PNG 路径位于 result.hostPath
$SBX click -x 640 -y 400
$SBX push -src ./setup.exe -dst 'C:\Users\WDAGUtilityAccount\Desktop\setup.exe'
$SBX stop
```

输出始终是单个 JSON 对象（`{"ok":true,"result":{...}}`）。

## 工作原理

- `start` 生成 `.wsb` 配置，将桥接文件夹映射到沙盒内的 `C:\Bridge`，并通过 `LogonCommand` 启动代理。
- 代理运行在已登录的用户会话中（`WDAGUtilityAccount`，管理员权限），因此 `SendInput`、屏幕截图和 UI 自动化都作用于真实桌面。
- 请求和响应以 JSON 文件的形式通过映射文件夹传递。即使禁用网络（`-noNetwork`）也能工作，一次往返约 0.6 秒。
  - 映射文件夹通过 vSMB 提供。若采用简单轮询，SMB 目录缓存会使新文件延迟 10–20 秒才可见，因此代理使用 FileSystemWatcher 接收变更通知来绕过缓存。
- 如果代理异常退出，启动器会自动重新启动它。

## 已知限制

- 沙盒中没有应用商店应用（新版记事本、计算器、画图、终端）。请使用 Edge、cmd、PowerShell 或自行安装的软件。
- 无法向 UAC 安全桌面或 Ctrl+Alt+Del 界面发送输入。
- 最小化沙盒窗口可能会暂停渲染和输入。
- 同一时间只能运行一个 Windows 沙盒实例。
- 不要将桥接文件夹（`SBX_BRIDGE`）放在 AppData 下。从 MSIX 打包的应用中运行时，对 AppData 的写入会被重定向，沙盒将以 `0x80070003`（找不到路径）失败。

## 免责声明

本项目为非官方社区项目，与 Microsoft 无关联，亦未获得 Microsoft 的认可或赞助。Windows 和 Windows Sandbox 是 Microsoft 集团公司的商标。

## 许可证

[MIT](../LICENSE)
