# sbx.ps1 액션 레퍼런스

[English](../references/actions.md) | **한국어** | [日本語](actions.ja.md) | [简体中文](actions.zh-CN.md)

모든 응답: `{"ok":bool, "action":..., "result":{...}, "error":"...", "ms":처리시간}`.
파라미터는 `-name value`, `-name=value`, `-flag`, `-paramsJson '{...}'`, `-paramsFile f.json`로 넘긴다.
`-textFile/-commandFile/-valueFile <호스트파일>`은 파일 내용을 `text/command/value`로 넣는다.
호스트 전용 옵션: `-wait <초>`(응답 대기 시간, 기본 max(60, timeout+30)), `-force`(하트비트 검사 생략).

## 호스트 액션

| 액션 | 파라미터 | 설명 |
|---|---|---|
| `check` | | 설치/하이퍼바이저/재부팅 대기/브리지 경로 진단, `hints` |
| `start` | `-noNetwork` `-memory MB(4096)` `-vgpu` `-noClipboard` `-map "host[=sandbox][;ro]\|..."` `-timeout 240` | .wsb 생성 후 실행, 에이전트 하트비트까지 대기, `info` 반환 |
| `stop` | `-kill` | 게스트 shutdown → 남은 프로세스 강제 종료 |
| `status` | | 하트비트(`ageSeconds`), 샌드박스 프로세스 |
| `logs` | `-lines 40` | agent.log / launcher.log 꼬리 |
| `update-agent` | | `scripts/agent/*`를 브리지로 복사하고 에이전트 재시작 |
| `run` | `-path 호스트파일\|폴더\|URL` 또는 `-sandboxPath`, `-args`, `-wait`, `-timeout 600`, `-silent`(msi), `-withFolder`, `-entry`(zip/iso 안의 파일), `-dst 샌드박스폴더(바탕화면)`, `-as 형식`, `-waitWindow`, `-screenshot`, `-settle 3`, `-noStart`, `-bootTimeout 240` + `start` 옵션 | 필요하면 부팅 → 복사 → 형식별 실행. 결과: `kind, mode(wait\|launch), sandboxPath, command, exec{exitCode,stdout,stderr}` 또는 `launch{pid}`, `extractedTo/mountedAt`, `screenshot`, `boot`. 형식 표는 SKILL.md 참고 |
| `push` | `-src 호스트경로 -dst 샌드박스경로` | 파일/폴더를 샌드박스로 복사 |
| `pull` | `-src 샌드박스경로 -dst 호스트경로` | 파일/폴더를 호스트로 복사 |
| `call` | `call <action> -paramsJson ...` | 임의 에이전트 액션 호출 |
| `secure-shot` | `-name` | **현재 입력 데스크톱**(UAC/잠금/Ctrl+Alt+Del 포함) 전체 화면 캡처. `file, hostPath, desktop` |
| `secure-click` | `-x* -y*`, `-button`, `-count` | 현재 입력 데스크톱에 클릭 |
| `secure-type` | `-text*` | 현재 입력 데스크톱에 유니코드 입력 |
| `secure-keys` | `-keys*`, `-repeat`, `-delay` | 현재 입력 데스크톱에 키 입력(`ctrl+alt+del` 형식) |
| `secure-move` | `-x* -y*` | 현재 입력 데스크톱에서 커서 이동 |
| `secure-desktop` | | 현재 입력 데스크톱 이름(`Default`, `Winlogon` 등) |
| `secure-sas` | `-asUser` | 보안 주의 시퀀스 전송(Ctrl+Alt+Del 화면 열기) |

`secure-*` 호스트 액션은 에이전트를 거치지 않고 SYSTEM 도우미와 **직접** 통신한다. UAC 창이 떠 있을 때는 에이전트가 블로킹되므로(그 `launch`/`exec`가 응답을 기다림) 이 직접 경로를 쓴다.

## 에이전트 액션 (샌드박스 내부)

### 명령/프로세스
| 액션 | 파라미터 | 결과 |
|---|---|---|
| `ping` | | `pong, agent, pid` |
| `info` | | OS, 사용자, elevated, 메모리, IPv4, 화면 |
| `exec` | `command`*, `shell powershell\|cmd`, `timeout 120`, `cwd`, `maxChars 200000` | `exitCode, stdout, stderr, timedOut, durationMs, truncated` (UTF-8). 타임아웃 시 프로세스 트리 종료 |
| `job_start` | `command`*, `shell`, `cwd` | `jobId, pid, stdoutFile` — 백그라운드 실행 |
| `job_status` | `id`(없으면 전체 목록), `maxChars 20000` | `running, exitCode, stdout, stderr`(꼬리) |
| `job_stop` | `id`* | 프로세스 트리 종료 |
| `launch` | `path`*, `args`, `cwd`, `admin`, `waitWindow`, `timeout 20` | `pid, name` — GUI 앱 실행(분리) |
| `ps` | `name '*'`(와일드카드), `max 200` | `pid, name, title, memMB, cpu` (메모리 내림차순) |
| `kill` | `pid` 또는 `name` | `killed` |
| `sleep` | `ms 1000` | |

### 화면/마우스
| 액션 | 파라미터 | 결과 |
|---|---|---|
| `screen` | | 가상 화면, 모니터 목록, dpi, 커서 |
| `screenshot` | `name`, `scale 1.0`, `x y width height`(영역) 또는 `title/hwnd/process`(창), `cursor true`, `.jpg` 이름이면 JPEG | `file, hostPath, region, scale, cursor` |
| `cursor` | | `x, y` |
| `move` | `x* y*`, `steps`, `duration ms` | 부드러운 이동은 steps>1 |
| `click` | `x y`(생략 시 현재 위치), `button left\|right\|middle\|x1\|x2`, `double`, `count`, `modifiers "ctrl+shift"` | |
| `mouse_down` / `mouse_up` | `x y`, `button` | 수동 드래그/길게 누르기 |
| `drag` | `x1* y1* x2* y2*`, `button`, `steps 20`, `duration 300` | |
| `scroll` | `x y`, `clicks -3`(음수=아래/왼쪽), `horizontal` | |

### 키보드
| 액션 | 파라미터 | 설명 |
|---|---|---|
| `type` | `text`*, `delay ms 0` | KEYEVENTF_UNICODE로 직접 입력 — 한글/이모지 OK, IME 상태 무관. `\n`=Enter, `\t`=Tab |
| `keys` | `keys`*, `repeat 1`, `delay 50` | `"ctrl+shift+esc"` 동시, 공백 구분은 순차: `"ctrl+a ctrl+c tab enter"` |
| `key_down` / `key_up` | `keys`* | 누른 채 유지/해제 (예: shift 누르고 클릭) |

키 이름: `ctrl alt shift win enter tab esc space backspace delete insert home end pageup pagedown up down left right f1..f24 capslock numlock printscreen pause apps hangul hanja num0..num9 multiply add subtract decimal divide plus minus comma period volumeup volumedown volumemute mediaplay medianext mediaprev browserback browserforward browserrefresh`, 영숫자 한 글자, 구두점 한 글자(`/`, `;` 등), `0x41` 같은 가상키 코드. `+` 키 자체는 `plus`.

### 창
| 액션 | 파라미터 | 결과 |
|---|---|---|
| `windows` | `title`(부분일치/와일드카드), `process`, `class`, `all`(숨김 포함) | `hwnd, title, class, pid, process, x, y, width, height, minimized, maximized, foreground` |
| `foreground` | | 현재 포그라운드 창 |
| `window` | `op focus\|minimize\|maximize\|restore\|close\|move`*, 대상 `hwnd\|title\|process`, move면 `x y width height` | `ok, window` |
| `wait_window` | `title/process/class`, `timeout 30`, `gone`(사라질 때까지) | `found, window, waitedMs` |

### UI Automation
대상 창: `hwnd|title|process` (생략 시 포그라운드 창). 요소 검색: `name`, `id`(AutomationId), `type`(Button, Edit, MenuItem, ... — 모두 `-like` 와일드카드), `index 0`.

| 액션 | 파라미터 | 결과 |
|---|---|---|
| `ui_tree` | `depth 3`, `max 400` | 트리: `name, type, id, class, enabled, rect, center, value` |
| `ui_find` | `name/id/type`, `max 50` | 일치 요소 목록 |
| `ui_invoke` | `name/id/type`*, `index` | Invoke → Toggle → SelectionItem → ExpandCollapse 패턴 순 시도, 없으면 중앙 클릭. `method` 반환 |
| `ui_set_value` | `name/id/type`*, `value`* | ValuePattern.SetValue, 없으면 포커스 → Ctrl+A → 타이핑 |

### 파일/클립보드
| 액션 | 파라미터 | 설명 |
|---|---|---|
| `ls` | `path`, `max 500` | 이름, dir, size, modified |
| `read_text` | `path`*, `maxChars` | 텍스트 읽기 |
| `write_text` | `path`*, `text`, `append` | UTF-8(BOM 없음) 쓰기, 상위 폴더 자동 생성 |
| `copy` | `src*`, `dst*` — `bridge:files/x`는 `C:\Bridge\files\x` | 샌드박스 내부 복사(재귀) |
| `delete` | `path`* | 재귀 삭제 |
| `clipboard_get` / `clipboard_set` | `text` | 샌드박스 클립보드 |

### 보안 데스크톱 (UAC / 잠금 화면 / Ctrl+Alt+Del)
SYSTEM 도우미(예약 작업 `SbxSecure`, **관리자 상태**의 샌드박스 시작 시 자동 상주, AtStartup 트리거로 재부팅에도 유지)가 대화형 세션에서 돌며, 현재 활성 데스크톱이 무엇이든 캡처/클릭/입력한다 — 에이전트 자신은 닿지 못하는 보안 데스크톱까지. 위의 호스트 직접 `secure-*` 액션으로 구동하거나(프롬프트가 에이전트를 막을 때 권장), 에이전트 자동 라우팅에 맡긴다(입력 데스크톱이 `Default`가 아니면 `screenshot`/`click`/`type`/`keys`가 도우미로 자동 전달; `-secure`로 강제, `-direct`로 직접 경로 유지).

| 액션 | 파라미터 | 설명 |
|---|---|---|
| `uac` | `mode off\|prompt\|desktop\|allow`(기본 `prompt`), `reboot true` | UAC 정책 설정 후 `EnableLUA`가 바뀌면 재부팅(도우미는 AtStartup으로 재상주). `off`=샌드박스 기본(완전 상승, 프롬프트 없음), `prompt`=보안 데스크톱의 실제 UAC, `desktop`=일반 데스크톱의 UAC(에이전트가 직접 클릭), `allow`=프롬프트 없이 상승. **관리자 에이전트 필요**(새 부팅), UAC를 올리기 전에 실행. `rebootRequired/rebooting` 반환 |
| `secure_status` | | `armed, task, inputDesktop, elevated, helper{pid,desktop,...}` |
| `secure_arm` | | 도우미 재등록/재시작(멱등, 등록엔 관리자 권한 필요) |
| `secure_sas` | `asUser` | SYSTEM에서 보안 주의 시퀀스 전송(Ctrl+Alt+Del 화면) |

실제 UAC 창을 누르는 전형적 흐름: `uac -mode prompt`(재부팅) → 상승하는 설치 프로그램/앱 실행 → `secure-shot`으로 창 확인 → **예/Yes**에 `secure-click -x -y`. 기본 샌드박스는 `EnableLUA=0`이라 설치가 조용히 자동 상승하므로, `prompt`/`desktop` 모드로 바꾸지 않으면 창이 뜨지 않는다.

### 에이전트 수명
| 액션 | 설명 |
|---|---|
| `restart_agent` | 종료 코드 0 → 런처가 재시작 (코드 재로드) |
| `stop_agent` | 종료 코드 99 → 런처도 종료 (샌드박스는 유지) |
| `shutdown` | 응답 후 게스트 OS 종료 → 샌드박스 창 닫힘 (`stop`이 사용) |

## 브리지 폴더 구조 (호스트 `%USERPROFILE%\WinSandboxBridge` = 샌드박스 `C:\Bridge`)
`agent\`(코드) `inbox\` `outbox\` `shots\`(스크린샷) `files\`(전송 스테이징, 자유 사용) `jobs\`(작업 출력) `logs\` `secure\`(보안 도우미: `inbox\` `outbox\` `shots\` `secure.status.json` 하트비트) `status.json`(2초마다 하트비트) `sandbox.wsb`(마지막 실행 설정).
