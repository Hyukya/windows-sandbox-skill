# windows-sandbox-skill

[English](../README.md) | [한국어](README.ko.md) | **日本語** | [简体中文](README.zh-CN.md)

ホストから **Windows サンドボックス** を操作する [Claude Code](https://claude.com/claude-code) 用スキルです。Claude がコマンドを実行して出力を受け取り、スクリーンショットを撮り、マウスとキーボードを操作し、UI コントロールを自動化し、使い捨ての Windows VM とファイルをやり取りできます。

```
host: sbx.ps1 ──JSON──▶ %USERPROFILE%\WinSandboxBridge ═(mapped folder)═▶ C:\Bridge ──▶ agent.ps1 (サンドボックス内)
```

## 機能

| 分類 | アクション |
|---|---|
| ライフサイクル | `check` `start` `stop` `status` `logs` `update-agent`(再起動なしでエージェントを更新) |
| ホストファイル実行 | `run` — ホストのファイル・フォルダー・URLを入れて種類に応じて実行(exe, msi, ps1, bat/cmd, js, reg, zip, iso, フォルダー, URL)。サンドボックスが停止中なら先に起動 |
| コマンド | `exec`(PowerShell/cmd、stdout・stderr・終了コード・タイムアウト)、`job_start` / `job_status` / `job_stop`、`launch`、`ps`、`kill` |
| 画面 | `screenshot`(全画面/領域/ウィンドウ、縮小、カーソル表示)、`screen`、`cursor` |
| マウス | `move` `click`(左/右/中/ダブル/修飾キー) `drag` `scroll` `mouse_down` `mouse_up` |
| キーボード | `type`(Unicode を直接入力するため日本語・韓国語・絵文字も可)、`keys`(`ctrl+shift+esc`、連続入力)、`key_down` `key_up` |
| ウィンドウ | `windows` `foreground` `window`(focus/minimize/maximize/restore/close/move) `wait_window` |
| UI Automation | `ui_tree` `ui_find` `ui_invoke` `ui_set_value` |
| ファイル・クリップボード | `push` `pull` `ls` `read_text` `write_text` `copy` `delete` `clipboard_get` `clipboard_set` |

すべてのパラメーターは [アクションリファレンス](actions.ja.md)を参照してください。

## 必要条件

- Windows 10/11 Pro、Enterprise、または Education
- BIOS でハードウェア仮想化(VT-x / AMD-V)が有効
- **Windows サンドボックス** 機能の有効化:「Windows の機能の有効化または無効化」から有効にするか、管理者 PowerShell で次を実行します。
  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
  ```
  その後 **スタート → 電源 → 再起動** を選びます。高速スタートアップが有効な場合、「シャットダウン」して電源を入れ直しても実際の再起動にはならず、機能のインストールが完了しません。
- Windows PowerShell 5.1(Windows に標準搭載)。追加のインストールは不要です。

## インストール

```bash
git clone https://github.com/Hyukya/windows-sandbox-skill ~/.claude/skills/windows-sandbox
```

Claude Code を再起動するとスキルが認識されます。その後「このインストーラーをサンドボックスでテストして」のように依頼すると、Claude が自動的に使用します。

## 直接使う

```bash
SBX="powershell -NoProfile -ExecutionPolicy Bypass -File $HOME/.claude/skills/windows-sandbox/scripts/sbx.ps1"
$SBX check                                   # インストール/仮想化の状態を診断
$SBX start                                   # サンドボックスを起動しエージェントを待機(約 30〜90 秒)
$SBX exec -command 'Get-ComputerInfo | Select OsName'
$SBX keys -keys 'win+r'; $SBX type -text 'cmd'; $SBX keys -keys enter
$SBX screenshot                              # result.hostPath に PNG のパス
$SBX click -x 640 -y 400
$SBX push -src ./setup.exe -dst 'C:\Users\WDAGUtilityAccount\Desktop\setup.exe'
$SBX run -path ./setup.msi -silent -wait       # ホストのファイルを入れてすぐ実行(必要なら起動も)
$SBX stop
```

出力は常に 1 つの JSON オブジェクト(`{"ok":true,"result":{...}}`)です。

## 仕組み

- `start` が `.wsb` 設定を作成し、ブリッジフォルダーをサンドボックス内の `C:\Bridge` にマップしてから、`LogonCommand` でエージェントを起動します。
- エージェントはログオン中のユーザーセッション(`WDAGUtilityAccount`、管理者権限)で動作するため、`SendInput`、画面キャプチャ、UI Automation が実際のデスクトップに作用します。
- 要求と応答はマップされたフォルダー内の JSON ファイルでやり取りします。ネットワークを無効にしても(`-noNetwork`)動作し、往復時間は約 0.6 秒です。
  - マップされたフォルダーは vSMB で提供されます。単純なポーリングでは SMB のディレクトリキャッシュにより新しいファイルが 10〜20 秒遅れて見えるため、エージェントは FileSystemWatcher で変更通知を受け取り、キャッシュを回避します。
- エージェントが異常終了すると、ランチャーが自動的に再起動します。

## 既知の制限

- サンドボックスには Store アプリ(新しいメモ帳、電卓、ペイント、ターミナル)がありません。Edge、cmd、PowerShell、または自分でインストールしたソフトウェアを使ってください。
- UAC のセキュリティで保護されたデスクトップや Ctrl+Alt+Del 画面には入力を送れません。
- サンドボックスのウィンドウを最小化すると、描画と入力が止まることがあります。
- Windows サンドボックスは同時に 1 つしか実行できません。
- ブリッジフォルダー(`SBX_BRIDGE`)を AppData 配下に置かないでください。MSIX パッケージ化されたアプリから実行すると AppData への書き込みがリダイレクトされ、サンドボックスが `0x80070003`(パスが見つかりません)で失敗します。

## 免責事項

本プロジェクトは非公式のコミュニティプロジェクトであり、Microsoft とは提携しておらず、Microsoft による承認や支援も受けていません。Windows および Windows Sandbox は Microsoft グループ企業の商標です。

## ライセンス

[MIT](../LICENSE)
