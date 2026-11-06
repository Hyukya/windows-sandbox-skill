---
name: windows-sandbox
description: Control Windows Sandbox (the disposable Windows VM built into Windows 10/11 Pro) from the host — start/stop it, run PowerShell/cmd commands with captured output and exit codes, take screenshots, drive the mouse and keyboard (click, drag, scroll, type Unicode/Korean text, hotkeys), find/focus/close windows, use UI Automation to inspect and click controls, copy files in and out, use the clipboard, and manage processes and background jobs. Use this skill whenever the user wants to do anything inside Windows Sandbox or a throwaway Windows VM — testing an installer or untrusted exe, reproducing a bug on a clean Windows, GUI automation in isolation, "샌드박스에서 실행해줘", "샌드박스 안에서 클릭/입력", "윈도우 샌드박스 제어", "깨끗한 윈도우에서 테스트" — even if they don't say "skill".
---

# Windows Sandbox 제어

호스트에서 `scripts/sbx.ps1`을 호출하면, 샌드박스 안(로그인된 사용자 세션)에서 도는 에이전트가 요청을 실행하고 결과를 JSON으로 돌려준다.

```
host: sbx.ps1 ──JSON──▶ %USERPROFILE%\WinSandboxBridge\inbox ═(mapped folder)═▶ C:\Bridge\inbox ──▶ agent.ps1 (in sandbox)
host ◀──JSON── outbox ◀════════════════════════════════════════════════════════ (result, screenshots in shots\)
```

- 네트워크가 필요 없다. 모든 통신은 매핑 폴더를 통하며, 왕복 시간은 약 0.6초다.
- 에이전트는 `WDAGUtilityAccount`(관리자 권한) 대화형 세션에서 돌기 때문에 SendInput, 화면 캡처, UI Automation이 실제 데스크톱에 작동한다.

## 호출 방법

```bash
SBX="powershell -NoProfile -ExecutionPolicy Bypass -File $HOME/.claude/skills/windows-sandbox/scripts/sbx.ps1"
$SBX <action> -name value -flag ...
```

- 출력은 항상 JSON 하나다. 성공하면 `{"ok":true,"result":{...}}`, 실패하면 `{"ok":false,"error":"..."}`이고, 실패 시 프로세스 종료 코드는 1이다.
- **Bash 도구에서 호출하는 것을 권장한다.** PowerShell 5.1에서 네이티브 exe를 호출하면 인자 속 큰따옴표가 깨진다. 복잡한 명령이나 긴 텍스트는 파일로 써서 `-commandFile` / `-textFile` / `-valueFile`로 넘기면 가장 안전하다.
- 값 문법: `-x 100`, `-name=value`, 값 없는 스위치(`-double`). 음수(`-clicks -3`)와 `-`로 시작하는 문자열 값(`-args '-NoProfile -File x.ps1'`)도 된다.
- 임의 파라미터를 넘기려면 `-paramsJson '{"x":1}'`이나 `-paramsFile p.json`을 쓴다.

## 기본 워크플로

1. **확인 및 시작**: 먼저 `$SBX check`로 설치 상태를 본다. 그다음 `$SBX start`를 실행한다(부팅에 약 60–90초 걸리고, 끝나면 `info`를 반환한다). 이미 떠 있으면 `alreadyRunning`이 온다.
   - 옵션: `-noNetwork`, `-memory 8192`, `-vgpu`, `-noClipboard`, `-map "D:\proj"`(샌드박스 바탕화면에 매핑), `-map "D:\in=C:\in;ro|D:\out=C:\out"`.
   - 샌드박스는 동시에 하나만 뜬다. 다른 샌드박스 창이 열려 있으면 실패하니 닫거나 `$SBX stop -kill`을 실행한다.
2. **관찰, 행동, 재관찰 루프**: GUI를 조작할 때는 `screenshot`을 찍고 → 반환된 `hostPath` 이미지를 Read 도구로 본 뒤 → `click`/`type`/`keys`를 실행하고 → 다시 `screenshot`을 찍어 결과를 확인한다. 입력은 "보내졌다"는 것만 보장되고 "의도대로 됐다"는 것은 보장되지 않으므로, 확인하지 않고 다음 단계로 넘어가지 않는다.
3. **종료**: `$SBX stop`을 실행한다. 샌드박스 안에서 shutdown하며, 안 되면 강제 종료한다. **샌드박스는 일회용이다.** 닫으면 내부 상태가 모두 사라지므로, 남길 결과물은 먼저 `pull`로 꺼낸다.

## 무엇을 쓸지 고르기 (안정성 순)

| 목적 | 1순위 | 대안 |
|---|---|---|
| 설치/설정/파일 작업 | `exec`(stdout, stderr, exitCode 캡처) | `job_start`(오래 걸리는 작업) |
| 버튼, 메뉴 클릭 | `ui_invoke -title <창> -name <이름>` | `screenshot`으로 좌표를 찾은 뒤 `click -x -y` |
| 입력란 채우기 | `ui_set_value` | `click` → `keys ctrl+a` → `type` |
| 단축키 | `keys -keys "ctrl+shift+esc"` | `key_down`/`key_up` |
| GUI 앱 실행 | `launch -path ... -waitWindow` 후 `wait_window` | `exec -command "Start-Process ..."` |

좌표 클릭은 해상도, 창 위치, 애니메이션에 따라 깨지기 쉽다. 그래서 명령(exec)이나 UI Automation으로 할 수 있으면 그쪽을 먼저 쓴다. UIA 요소의 `center` 좌표는 그대로 `click`에 넣을 수 있다.

## 자주 쓰는 명령

```bash
$SBX exec -command 'Get-ComputerInfo | Select OsName,OsVersion' -timeout 60
$SBX exec -shell cmd -command 'ipconfig /all'
$SBX exec -commandFile ./install.ps1 -timeout 900          # 긴/복잡한 스크립트
$SBX job_start -command '& C:\setup.exe /S' ; $SBX job_status -id <jobId>
$SBX push -src ./app.msi -dst 'C:\Users\WDAGUtilityAccount\Desktop\app.msi'
$SBX pull -src 'C:\logs' -dst ./sandbox-logs
$SBX launch -path 'msedge.exe' -args 'https://example.com' -waitWindow
$SBX wait_window -title '*Setup*' -timeout 60
$SBX window -title '*Setup*' -op focus        # focus|minimize|maximize|restore|close|move
$SBX screenshot                                # 전체 화면 -> result.hostPath
$SBX screenshot -title '*Setup*' -scale 0.5    # 창 영역만 축소 캡처
$SBX click -x 640 -y 400 [-button right] [-double] [-modifiers ctrl]
$SBX drag -x1 100 -y1 100 -x2 400 -y2 300
$SBX scroll -x 640 -y 400 -clicks -5           # 음수 = 아래로
$SBX type -text '안녕하세요 Hello'               # 유니코드 직접 입력 (IME 무관)
$SBX keys -keys 'ctrl+a ctrl+c'                 # 공백 = 순차, + = 동시
$SBX ui_tree -title '*Setup*' -depth 3
$SBX ui_invoke -title '*Setup*' -name 'Next*'
$SBX clipboard_get ; $SBX clipboard_set -text '...'
$SBX ps -name 'set*' ; $SBX kill -name setup
```

전체 액션과 파라미터 목록은 `references/actions.md`에 있다. 처음 보는 액션을 쓰거나 파라미터가 헷갈릴 때 읽는다.

## 좌표와 스크린샷

- 좌표는 샌드박스 화면의 물리 픽셀 기준이며 원점은 (0,0)이다. 화면 크기는 `screen` 또는 `start` 결과의 `info.screen`에서 확인한다. 기본값은 호스트 창 크기를 따른다(예: 1536×832).
- `screenshot -scale s`로 축소했거나 `-title`/`-x -y -width -height`로 영역만 캡처했다면, 이미지 픽셀 (px,py)는 화면 좌표 `(region.x + px/s, region.y + py/s)`에 해당한다. 결과의 `region`과 `scale` 값을 사용한다.
- 스크린샷에는 현재 커서 위치가 빨간 십자로 표시된다(`-cursor false`로 끌 수 있다).
- 샌드박스 창이 최소화돼 있으면 화면 렌더링과 입력이 멈출 수 있다. 화면이 검거나 입력이 먹지 않으면 사용자에게 샌드박스 창을 복원해 달라고 요청한다.

## 알아둘 제약

- **Store 앱이 없다.** 샌드박스 안에서는 메모장, 계산기, 그림판, 터미널 같은 Store 앱이 실행 직후 종료된다. Edge, cmd, PowerShell, 탐색기, 레지스트리 편집기 같은 기본 앱이나 직접 설치한 프로그램을 사용한다.
- UAC나 보안 데스크톱(Ctrl+Alt+Del) 화면에는 SendInput이 닿지 않는다. 다만 에이전트가 이미 관리자 권한이라 일반적인 설치에서는 UAC 창이 뜨지 않는다.
- WinForms처럼 일부 앱은 UIA ControlType을 `Pane`으로 노출하고 AutomationId를 비워 둔다. `-type`/`-id`로 못 찾으면 `-name`만으로 찾고, `ui_tree`로 실제 구조를 먼저 확인한다.
- `exec`는 순차 처리된다. 도는 동안 다른 요청은 대기하므로, 수 분 이상 걸리는 작업은 `job_start`로 돌리고 그 사이에 화면을 관찰한다.
- 브리지 폴더는 `%USERPROFILE%\WinSandboxBridge`이며 `SBX_BRIDGE` 환경변수로 바꿀 수 있다. **AppData 아래에 두면 안 된다.** Claude 데스크톱 같은 MSIX 앱에서는 AppData 쓰기가 패키지 폴더로 리디렉션되어, 샌드박스가 `0x80070003 지정된 경로를 찾을 수 없습니다`로 실패한다.

## 문제 해결

- `check`가 `installed:false` 또는 `rebootPending:true`를 반환하면: "Windows 기능 켜기/끄기"에서 Windows Sandbox를 켠 뒤 **시작 → 전원 → 다시 시작**을 하도록 안내한다. "시스템 종료" 후 다시 켜는 것은 빠른 시작 때문에 재부팅으로 처리되지 않는다. BIOS에서 VT-x/AMD-V도 켜져 있어야 한다. 이 설정들은 사용자가 직접 바꿔야 한다.
- 에이전트가 응답하지 않으면 `$SBX status`(하트비트 나이)와 `$SBX logs`를 확인한다. 에이전트가 죽으면 런처가 1초 뒤 재시작한다.
- 에이전트 코드를 수정했다면 `$SBX update-agent`로 재부팅 없이 반영한다.
- 동작 검증용 폼은 `assets/testform.ps1`에 있다. `push`로 넣고 `launch`로 띄우면 클릭, 키, 휠, 드래그 이벤트가 `C:\Bridge\files\events.txt`에 기록된다.
