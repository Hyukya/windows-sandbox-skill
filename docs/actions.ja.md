# sbx.ps1 アクションリファレンス

[English](../references/actions.md) | [한국어](actions.ko.md) | **日本語** | [简体中文](actions.zh-CN.md)

すべての応答: `{"ok":bool, "action":..., "result":{...}, "error":"...", "ms":処理時間}`。
パラメーターは `-name value`、`-name=value`、`-flag`、`-paramsJson '{...}'`、`-paramsFile f.json` で渡します。
`-textFile/-commandFile/-valueFile <ホストのファイル>` はファイルの内容を `text/command/value` に入れます。
ホスト専用オプション: `-wait <秒>`(応答の待ち時間、既定値は max(60, timeout+30))、`-force`(ハートビート確認を省略)。

## ホストアクション

| アクション | パラメーター | 説明 |
|---|---|---|
| `check` | | インストール / ハイパーバイザー / 再起動待ち / ブリッジパスを診断し、`hints` を返す |
| `start` | `-noNetwork` `-memory MB(4096)` `-vgpu` `-noClipboard` `-map "host[=sandbox][;ro]\|..."` `-timeout 240` | .wsb を作成して起動し、エージェントのハートビートまで待って `info` を返す |
| `stop` | `-kill` | ゲストをシャットダウン → 残ったプロセスを強制終了 |
| `status` | | ハートビート(`ageSeconds`)、サンドボックスのプロセス |
| `logs` | `-lines 40` | agent.log / launcher.log の末尾 |
| `update-agent` | | `scripts/agent/*` をブリッジにコピーしてエージェントを再起動 |
| `run` | `-path ホストのファイル\|フォルダー\|URL` または `-sandboxPath`、`-args`、`-wait`、`-timeout 600`、`-silent`(msi)、`-withFolder`、`-entry`(zip/iso 内のファイル)、`-dst サンドボックスのフォルダー(デスクトップ)`、`-as 種類`、`-waitWindow`、`-screenshot`、`-settle 3`、`-noStart`、`-bootTimeout 240` + `start` のオプション | 必要なら起動 → コピー → 種類に応じて実行。結果: `kind, mode(wait\|launch), sandboxPath, command, exec{exitCode,stdout,stderr}` または `launch{pid}`、`extractedTo/mountedAt`、`screenshot`、`boot`。種類の表は SKILL.md を参照 |
| `push` | `-src ホストのパス -dst サンドボックスのパス` | ファイル/フォルダーをサンドボックスへコピー |
| `pull` | `-src サンドボックスのパス -dst ホストのパス` | ファイル/フォルダーをホストへコピー |
| `call` | `call <action> -paramsJson ...` | 任意のエージェントアクションを呼び出す |

## エージェントアクション(サンドボックス内)

### コマンド / プロセス
| アクション | パラメーター | 結果 |
|---|---|---|
| `ping` | | `pong, agent, pid` |
| `info` | | OS、ユーザー、elevated、メモリ、IPv4、画面 |
| `exec` | `command`*、`shell powershell\|cmd`、`timeout 120`、`cwd`、`maxChars 200000` | `exitCode, stdout, stderr, timedOut, durationMs, truncated`(UTF-8)。タイムアウト時はプロセスツリーを終了 |
| `job_start` | `command`*、`shell`、`cwd` | `jobId, pid, stdoutFile` — バックグラウンドで実行 |
| `job_status` | `id`(省略時は一覧)、`maxChars 20000` | `running, exitCode, stdout, stderr`(末尾) |
| `job_stop` | `id`* | プロセスツリーを終了 |
| `launch` | `path`*、`args`、`cwd`、`admin`、`waitWindow`、`timeout 20` | `pid, name` — GUI アプリを起動(切り離し) |
| `ps` | `name '*'`(ワイルドカード)、`max 200` | `pid, name, title, memMB, cpu`(メモリの降順) |
| `kill` | `pid` または `name` | `killed` |
| `sleep` | `ms 1000` | |

### 画面 / マウス
| アクション | パラメーター | 結果 |
|---|---|---|
| `screen` | | 仮想画面、モニター一覧、dpi、カーソル |
| `screenshot` | `name`、`scale 1.0`、`x y width height`(領域)または `title/hwnd/process`(ウィンドウ)、`cursor true`、名前が `.jpg` なら JPEG | `file, hostPath, region, scale, cursor` |
| `cursor` | | `x, y` |
| `move` | `x* y*`、`steps`、`duration ms` | steps>1 で滑らかに移動 |
| `click` | `x y`(省略時は現在位置)、`button left\|right\|middle\|x1\|x2`、`double`、`count`、`modifiers "ctrl+shift"` | |
| `mouse_down` / `mouse_up` | `x y`、`button` | 手動ドラッグ / 長押し |
| `drag` | `x1* y1* x2* y2*`、`button`、`steps 20`、`duration 300` | |
| `scroll` | `x y`、`clicks -3`(負の値 = 下/左)、`horizontal` | |

### キーボード
| アクション | パラメーター | 説明 |
|---|---|---|
| `type` | `text`*、`delay ms 0` | KEYEVENTF_UNICODE で直接入力 — 日本語/韓国語/絵文字も可、IME の状態に依存しない。`\n`=Enter、`\t`=Tab |
| `keys` | `keys`*、`repeat 1`、`delay 50` | `"ctrl+shift+esc"` は同時押し、スペース区切りは順次: `"ctrl+a ctrl+c tab enter"` |
| `key_down` / `key_up` | `keys`* | 押したまま保持 / 解放(例: shift を押したままクリック) |

キー名: `ctrl alt shift win enter tab esc space backspace delete insert home end pageup pagedown up down left right f1..f24 capslock numlock printscreen pause apps hangul hanja num0..num9 multiply add subtract decimal divide plus minus comma period volumeup volumedown volumemute mediaplay medianext mediaprev browserback browserforward browserrefresh`、英数字 1 文字、記号 1 文字(`/`、`;` など)、`0x41` のような仮想キーコード。`+` キー自体は `plus`。

### ウィンドウ
| アクション | パラメーター | 結果 |
|---|---|---|
| `windows` | `title`(部分一致/ワイルドカード)、`process`、`class`、`all`(非表示を含む) | `hwnd, title, class, pid, process, x, y, width, height, minimized, maximized, foreground` |
| `foreground` | | 現在のフォアグラウンドウィンドウ |
| `window` | `op focus\|minimize\|maximize\|restore\|close\|move`*、対象 `hwnd\|title\|process`、move の場合は `x y width height` | `ok, window` |
| `wait_window` | `title/process/class`、`timeout 30`、`gone`(消えるまで待つ) | `found, window, waitedMs` |

### UI Automation
対象ウィンドウ: `hwnd|title|process`(省略時はフォアグラウンドウィンドウ)。要素の検索: `name`、`id`(AutomationId)、`type`(Button、Edit、MenuItem など — すべて `-like` ワイルドカード)、`index 0`。

| アクション | パラメーター | 結果 |
|---|---|---|
| `ui_tree` | `depth 3`、`max 400` | ツリー: `name, type, id, class, enabled, rect, center, value` |
| `ui_find` | `name/id/type`、`max 50` | 一致した要素の一覧 |
| `ui_invoke` | `name/id/type`*、`index` | Invoke → Toggle → SelectionItem → ExpandCollapse パターンの順に試し、なければ中央をクリック。`method` を返す |
| `ui_set_value` | `name/id/type`*、`value`* | ValuePattern.SetValue、なければフォーカス → Ctrl+A → 入力 |

### ファイル / クリップボード
| アクション | パラメーター | 説明 |
|---|---|---|
| `ls` | `path`、`max 500` | 名前、dir、サイズ、更新日時 |
| `read_text` | `path`*、`maxChars` | テキストを読む |
| `write_text` | `path`*、`text`、`append` | UTF-8(BOM なし)で書き込み、親フォルダーを自動作成 |
| `copy` | `src*`、`dst*` — `bridge:files/x` は `C:\Bridge\files\x` | サンドボックス内でコピー(再帰) |
| `delete` | `path`* | 再帰的に削除 |
| `clipboard_get` / `clipboard_set` | `text` | サンドボックスのクリップボード |

### エージェントのライフサイクル
| アクション | 説明 |
|---|---|
| `restart_agent` | 終了コード 0 → ランチャーが再起動(コードを再読み込み) |
| `stop_agent` | 終了コード 99 → ランチャーも終了(サンドボックスは維持) |
| `shutdown` | 応答後にゲスト OS をシャットダウン → サンドボックスのウィンドウが閉じる(`stop` が使用) |

## ブリッジフォルダーの構成(ホスト `%USERPROFILE%\WinSandboxBridge` = サンドボックス `C:\Bridge`)
`agent\`(コード) `inbox\` `outbox\` `shots\`(スクリーンショット) `files\`(転送用ステージング、自由に使用可) `jobs\`(ジョブ出力) `logs\` `status.json`(2 秒ごとのハートビート) `sandbox.wsb`(最後の起動設定)。
