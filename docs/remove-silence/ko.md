> 이 번역은 AI에 의해 생성되었습니다. 오류가 있으면 PR을 열어주세요.

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <a href="es.md">Español</a> ·
  <a href="zh-CN.md">简体中文</a> ·
  <a href="zh-TW.md">繁體中文</a> ·
  <a href="ja.md">日本語</a> ·
  <strong>한국어</strong> ·
  <a href="vi.md">Tiếng Việt</a> ·
  <a href="hi.md">हिन्दी</a> ·
  <a href="bn.md">বাংলা</a> ·
  <a href="ar.md">العربية</a> ·
  <a href="it.md">Italiano</a> ·
  <a href="pt-BR.md">Português (Brasil)</a> ·
  <a href="fr.md">Français</a> ·
  <a href="ru.md">Русский</a>
</p>

# 무음 제거

클립에서 무음 구간을 자동으로 감지하고 제거합니다. 감지는 클립의 오디오 파형을 기반으로 기기 내에서 완전히 실행되며 — 인터넷 연결이나 트랜스크립트가 필요하지 않습니다.

## 데스크탑

### 1. 클립 선택
타임라인에서 **비디오 또는 오디오 클립**을 클릭합니다. 무음 제거 버튼은 단일 클립(또는 연결된 오디오/비디오 쌍)이 선택된 경우에만 활성화됩니다.

### 2. 시트 열기
툴바에서 **파형 마이너스 아이콘**(`waveform.badge.minus`)을 클릭하거나 **편집 → 무음 제거**를 선택합니다. 시트가 열리고 현재 설정을 사용하여 즉시 무음 감지를 시작합니다.

### 3. 파라미터 조정

| 파라미터 | 기본값 | 설명 |
|-----------|---------|-------------|
| **Threshold** | −35 dB | 오디오를 무음으로 간주하는 최소 음량 기준입니다. 0 dB 방향으로 올리면(예: −25 dB) 더 조용한 멈춤도 감지하고, 낮추면(예: −45 dB) 거의 완전한 무음만 제거합니다. |
| **Min duration** | 0.5 s | 제거할 최소 무음 길이입니다. 높이면 자연스러운 호흡과 짧은 멈춤을 유지하고, 낮추면 짧은 공백도 제거합니다. |
| **Edge padding** | 0.05 s | 감지된 무음의 양쪽에 유지할 오디오 길이로, 발화와 음표가 잘리지 않도록 합니다. 단어가 잘리는 경우 늘려주세요. |

파라미터를 변경한 후 **감지**를 클릭하면 새 값으로 감지를 다시 실행합니다. 시트에는 감지된 무음의 수가 표시됩니다.

### 4. 적용
**무음 제거**를 클릭합니다. 무음 구간이 리플 삭제됩니다 — 클립이 연결되고 이후의 모든 항목이 왼쪽으로 이동하여 간격을 채웁니다. 편집은 단일 실행 취소 가능한 동작입니다: **⌘Z**를 눌러 원래 상태로 복원합니다.

## 연결된 오디오/비디오 클립
비디오 클립과 오디오가 연결되어 있을 때(두 트랙 모두에서 체인 아이콘이 닫혀 있음), 어느 클립을 선택해도 쌍이 선택됩니다. 무음 제거는 감지를 위해 오디오 파형을 읽고 정확히 같은 프레임에서 **두 트랙 모두**를 잘라내어 오디오와 비디오의 동기화를 유지합니다.

## AI 에이전트 (MCP)
Palmier Pro가 실행 중이면 `http://127.0.0.1:19789/mcp`에 MCP 서버를 노출합니다. 연결된 에이전트(Claude, Codex, Cursor 등)는 `remove_silence` 도구를 사용하여 무음을 제거할 수 있습니다.

### 자연어
```
Remove the silences from the first clip
Cut all the dead air
Tighten the pauses — use a threshold of -30 dB
Remove silence, minimum gap 1 second
```

### 도구: `remove_silence`
```json
{"name":"remove_silence","arguments":{"clipId":"<id from get_timeline>","thresholdDb":-35,"minSilenceDuration":0.5,"edgePadding":0.05}}
```

#### 파라미터
| 파라미터 | 타입 | 기본값 | 설명 |
|-----------|------|---------|-------------|
| `clipId` | string | **필수** | `get_timeline`에서 가져온 클립 ID입니다. 오디오 클립이거나 오디오가 있는 비디오 클립이어야 합니다. |
| `thresholdDb` | number | `−35` | dBFS 단위의 최소 음량 기준입니다(≤ 0이어야 함). 이보다 조용한 오디오는 무음으로 처리됩니다. |
| `minSilenceDuration` | number | `0.5` | 제거할 최소 무음 길이(초)입니다. |
| `edgePadding` | number | `0.05` | 감지된 무음의 양쪽에 보존할 오디오 시간(초)입니다. |

#### 응답
```json
{"removedSilences":12,"removedFrames":1440,"thresholdDb":-35,"note":"Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit."}
```

#### 워크플로 예시
```
1. get_timeline          → 클립 ID 찾기
2. remove_silence        → 무음 감지 및 제거
3. get_transcript        → 결과 확인 (선택 사항)
4. undo                  → 결과가 올바르지 않으면 되돌리기
```

## 팁
- **아무것도 제거되지 않았나요?** Threshold를 낮추거나(예: −30 dB) **Min duration**을 줄이세요.
- **발화가 잘리나요?** **Edge padding**을 늘려(예: 0.1 s) 각 컷 주변에 더 많은 오디오를 유지하세요.
- **컷이 너무 많나요?** **Min duration**을 높여(예: 1.0 s) 짧은 멈춤을 건너뛰세요.
- **연결 해제 후 연결된 클립이 동기화되지 않나요?** 두 트랙이 동일한 컷을 받을 수 있도록 항상 클립이 연결된 상태에서 무음 제거를 실행하세요.
