# windows-sandbox-skill

[English](../README.md) | **한국어** | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

호스트에서 **Windows 샌드박스**를 제어하는 [Claude Code](https://claude.com/claude-code) 스킬입니다. Claude가 명령을 실행해 출력을 받고, 화면을 캡처하고, 마우스와 키보드를 조작하고, UI 컨트롤을 자동화하고, 일회용 Windows VM과 파일을 주고받을 수 있습니다.

```
host: sbx.ps1 ──JSON──▶ %USERPROFILE%\WinSandboxBridge ═(mapped folder)═▶ C:\Bridge ──▶ agent.ps1 (샌드박스 내부)
```

## 기능

| 분류 | 액션 |
|---|---|
| 수명 관리 | `check` `start` `stop` `status` `logs` `update-agent` (재부팅 없이 에이전트 갱신) |
| 호스트 파일 실행 | `run` — 호스트의 파일·폴더·URL을 넣고 형식에 맞게 실행(exe, msi, ps1, bat/cmd, js, reg, zip, iso, 폴더, URL). 샌드박스가 꺼져 있으면 먼저 부팅 |
| 명령 | `exec`(PowerShell/cmd, stdout·stderr·종료 코드·타임아웃), `job_start` / `job_status` / `job_stop`, `launch`, `ps`, `kill` |
| 화면 | `screenshot`(전체/영역/창, 축소, 커서 표시), `screen`, `cursor` |
| 마우스 | `move` `click`(좌/우/중간/더블/수정키) `drag` `scroll` `mouse_down` `mouse_up` |
| 키보드 | `type`(유니코드 직접 입력이라 한글·한자·이모지도 됨), `keys`(`ctrl+shift+esc`, 순차 입력), `key_down` `key_up` |
| 창 | `windows` `foreground` `window`(focus/minimize/maximize/restore/close/move) `wait_window` |
| UI Automation | `ui_tree` `ui_find` `ui_invoke` `ui_set_value` |
| 파일·클립보드 | `push` `pull` `ls` `read_text` `write_text` `copy` `delete` `clipboard_get` `clipboard_set` |

전체 파라미터는 [액션 레퍼런스](actions.ko.md)를 참고하세요.

## 요구 사항

- Windows 10/11 Pro, Enterprise 또는 Education
- BIOS에서 하드웨어 가상화(VT-x / AMD-V) 활성화
- **Windows Sandbox** 기능 활성화: "Windows 기능 켜기/끄기"에서 켜거나, 관리자 PowerShell에서 아래 명령을 실행합니다.
  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
  ```
  그다음 **시작 → 전원 → 다시 시작**을 합니다. 빠른 시작이 켜져 있으면 "시스템 종료" 후 다시 켜는 것은 실제 재부팅이 아니어서 기능 설치가 끝나지 않습니다.
- Windows PowerShell 5.1(Windows 기본 포함). 따로 설치할 것은 없습니다.

## 설치

```bash
git clone https://github.com/Hyukya/windows-sandbox-skill ~/.claude/skills/windows-sandbox
```

Claude Code를 다시 시작하면 스킬이 인식됩니다. 이후 "샌드박스에서 이 설치 파일 테스트해줘"처럼 요청하면 Claude가 알아서 사용합니다.

## 직접 사용하기

```bash
SBX="powershell -NoProfile -ExecutionPolicy Bypass -File $HOME/.claude/skills/windows-sandbox/scripts/sbx.ps1"
$SBX check                                   # 설치/가상화 상태 진단
$SBX start                                   # 샌드박스 부팅 후 에이전트 대기 (약 30–90초)
$SBX exec -command 'Get-ComputerInfo | Select OsName'
$SBX keys -keys 'win+r'; $SBX type -text 'cmd'; $SBX keys -keys enter
$SBX screenshot                              # result.hostPath에 PNG 경로
$SBX click -x 640 -y 400
$SBX push -src ./setup.exe -dst 'C:\Users\WDAGUtilityAccount\Desktop\setup.exe'
$SBX run -path ./setup.msi -silent -wait       # 호스트 파일을 넣고 바로 실행(필요하면 부팅까지)
$SBX stop
```

출력은 항상 JSON 객체 하나(`{"ok":true,"result":{...}}`)입니다.

## 동작 방식

- `start`가 `.wsb` 설정을 만들고, 브리지 폴더를 샌드박스의 `C:\Bridge`에 매핑한 뒤 `LogonCommand`로 에이전트를 띄웁니다.
- 에이전트는 로그인된 사용자 세션(`WDAGUtilityAccount`, 관리자 권한)에서 돌기 때문에 `SendInput`, 화면 캡처, UI Automation이 실제 데스크톱에 작동합니다.
- 요청과 응답은 매핑 폴더의 JSON 파일로 주고받습니다. 네트워크를 꺼도(`-noNetwork`) 동작하며, 왕복 시간은 약 0.6초입니다.
  - 매핑 폴더는 vSMB로 제공됩니다. 단순 폴링으로는 SMB 디렉터리 캐시 때문에 새 파일이 10–20초 늦게 보여서, 에이전트는 FileSystemWatcher로 변경 알림을 받아 캐시를 우회합니다.
- 에이전트가 비정상 종료되면 런처가 자동으로 다시 띄웁니다.

## 알려진 제약

- 샌드박스에는 Store 앱(새 메모장, 계산기, 그림판, 터미널)이 없습니다. Edge, cmd, PowerShell 또는 직접 설치한 프로그램을 사용하세요.
- UAC 보안 데스크톱이나 Ctrl+Alt+Del 화면에는 입력을 보낼 수 없습니다.
- 샌드박스 창을 최소화하면 화면 렌더링과 입력이 멈출 수 있습니다.
- Windows Sandbox는 한 번에 하나만 실행할 수 있습니다.
- 브리지 폴더(`SBX_BRIDGE`)를 AppData 아래에 두지 마세요. MSIX로 패키징된 앱에서 실행하면 AppData 쓰기가 리디렉션되어 샌드박스가 `0x80070003`(경로를 찾을 수 없음)으로 실패합니다.

## 면책 조항

이 프로젝트는 비공식 커뮤니티 프로젝트이며 Microsoft와 제휴하거나 Microsoft의 보증 또는 후원을 받지 않았습니다. Windows 및 Windows Sandbox는 Microsoft 그룹 계열사의 상표입니다.

## 라이선스

[MIT](../LICENSE)
