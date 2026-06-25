> 此翻譯由 AI 生成。如有錯誤，歡迎提交 PR。

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <a href="es.md">Español</a> ·
  <a href="zh-CN.md">简体中文</a> ·
  <strong>繁體中文</strong> ·
  <a href="ja.md">日本語</a> ·
  <a href="ko.md">한국어</a> ·
  <a href="vi.md">Tiếng Việt</a> ·
  <a href="hi.md">हिन्दी</a> ·
  <a href="bn.md">বাংলা</a> ·
  <a href="ar.md">العربية</a> ·
  <a href="it.md">Italiano</a> ·
  <a href="pt-BR.md">Português (Brasil)</a> ·
  <a href="fr.md">Français</a> ·
  <a href="ru.md">Русский</a>
</p>

# 移除靜音

自動偵測並移除片段中的靜音區段。偵測完全在裝置本機執行，直接分析片段的音訊波形——無需網路連線或逐字稿。

## 桌面版

### 1. 選取片段
在時間軸上點選任意**影片或音訊片段**。移除靜音按鈕僅在選取單一片段（或已連結的音訊／影片組合）時才會啟用。

### 2. 開啟面板
點選工具列中的**波形減號圖示**（`waveform.badge.minus`），或選擇 **Edit → Remove Silence**。面板開啟後，會立即以目前的設定開始偵測靜音。

### 3. 調整參數

| 參數 | 預設值 | 說明 |
|-----------|---------|-------------|
| **Threshold** | −35 dB | 音量下限，低於此值的音訊將被視為靜音。往 0 dB 方向調高（例如 −25 dB）可捕捉較輕的停頓；調低（例如 −45 dB）則僅移除幾乎完全無聲的部分。 |
| **Min duration** | 0.5 s | 將被移除的最短靜音長度。調高此值可保留自然的呼吸聲和短暫停頓；調低則可剪除極短的空白。 |
| **Edge padding** | 0.05 s | 在偵測到的靜音兩側各保留的音訊長度，避免語音和音符遭到截斷。若出現字句被切斷的情況，請增加此值。 |

更改任何參數後，點選 **Detect** 以重新執行偵測。面板會顯示找到的靜音數量。

### 4. 套用
點選 **Remove Silences**。靜音區段將以波紋刪除的方式移除——片段會自動靠攏，後方的內容向左移動填補空隙。此操作為單一可復原動作：按下 **⌘Z** 即可還原至原始狀態。

## 連結的音訊／影片片段
當影片片段與其音訊已連結（兩條軌道上的鏈條圖示均為閉合狀態）時，選取任一片段即會同時選取整個組合。移除靜音功能會讀取音訊波形進行偵測，並在**兩條軌道**上於完全相同的影格位置執行剪切，確保音訊與影像保持同步。

## AI 代理程式（MCP）
Palmier Pro 執行時，會在 `http://127.0.0.1:19789/mcp` 公開一個 MCP 伺服器。任何已連線的代理程式（Claude、Codex、Cursor 等）均可使用 `remove_silence` 工具來移除靜音。

### 自然語言
```
Remove the silences from the first clip
Cut all the dead air
Tighten the pauses — use a threshold of -30 dB
Remove silence, minimum gap 1 second
```

### 工具：`remove_silence`
```json
{
  "name": "remove_silence",
  "arguments": {
    "clipId": "<id from get_timeline>",
    "thresholdDb": -35,
    "minSilenceDuration": 0.5,
    "edgePadding": 0.05
  }
}
```

#### 參數
| 參數 | 類型 | 預設值 | 說明 |
|-----------|------|---------|-------------|
| `clipId` | string | **必填** | 來自 `get_timeline` 的片段 ID。必須為音訊片段或含有音訊的影片片段。 |
| `thresholdDb` | number | `−35` | 音量下限，單位為 dBFS（必須 ≤ 0）。靜音低於此值的音訊將被視為靜音。 |
| `minSilenceDuration` | number | `0.5` | 將被移除的最短靜音長度，單位為秒。 |
| `edgePadding` | number | `0.05` | 在偵測到的靜音兩側各保留的音訊秒數。 |

#### 回應
```json
{
  "removedSilences": 12,
  "removedFrames": 1440,
  "thresholdDb": -35,
  "note": "Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit."
}
```

#### 工作流程範例
```
1. get_timeline          → 取得片段 ID
2. remove_silence        → 偵測並移除靜音
3. get_transcript        → 驗證結果（選用）
4. undo                  → 若結果不符預期則復原
```

## 使用技巧
- **沒有移除任何內容？** 調低閾值（例如 −30 dB）或縮短 **Min duration**。
- **語音被截斷？** 增加 **Edge padding**（例如 0.1 s）以在每個剪切點周圍保留更多音訊。
- **剪切次數過多？** 調高 **Min duration**（例如 1.0 s）以略過短暫停頓。
- **解除連結後片段音畫不同步？** 請務必在片段連結狀態下執行移除靜音，確保兩條軌道接收到完全相同的剪切。
