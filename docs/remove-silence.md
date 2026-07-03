<p align="right">
  <a href="remove-silence/es.md">Español</a> ·
  <a href="remove-silence/zh-CN.md">简体中文</a> ·
  <a href="remove-silence/zh-TW.md">繁體中文</a> ·
  <a href="remove-silence/ja.md">日本語</a> ·
  <a href="remove-silence/ko.md">한국어</a> ·
  <a href="remove-silence/vi.md">Tiếng Việt</a> ·
  <a href="remove-silence/hi.md">हिन्दी</a> ·
  <a href="remove-silence/bn.md">বাংলা</a> ·
  <a href="remove-silence/ar.md">العربية</a> ·
  <a href="remove-silence/it.md">Italiano</a> ·
  <a href="remove-silence/pt-BR.md">Português (Brasil)</a> ·
  <a href="remove-silence/fr.md">Français</a> ·
  <a href="remove-silence/ru.md">Русский</a>
</p>

# Remove Silence

Automatically detect and remove silent regions from a clip. Detection runs entirely on-device from the clip's audio waveform — no internet connection or transcript required.

---

## Desktop

### 1. Select a clip

Click any **video or audio clip** on the timeline. The Remove Silence button activates only when a single clip (or a linked audio/video pair) is selected.

### 2. Open the sheet

Click the **waveform minus icon** (`waveform.badge.minus`) in the toolbar, or choose **Edit → Remove Silence**.

The sheet opens and immediately starts detecting silences using the current settings.

### 3. Adjust the parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| **Threshold** | −35 dB | The loudness floor below which audio is considered silent. Raise toward 0 dB (e.g. −25 dB) to catch quieter pauses; lower (e.g. −45 dB) to only remove near-total silence. |
| **Min duration** | 0.5 s | The shortest silence that will be removed. Raise this to keep natural breaths and short pauses; lower it to cut even brief gaps. |
| **Edge padding** | 0.05 s | How much audio to keep on each side of a detected silence, so speech and notes are not clipped. Increase if words are being cut off. |

After changing any parameter, click **Detect** to re-run detection with the new values. The sheet shows how many silences were found.

### 4. Apply

Click **Remove Silences**. The silent regions are ripple-deleted — clips close up and everything after shifts left to fill the gaps. The edit is a single undoable action: press **⌘Z** to restore the original.

---

## Linked audio/video clips

When a video clip and its audio are linked (the chain icon is closed on both tracks), selecting either clip selects the pair. Remove Silence reads the audio waveform for detection and cuts **both tracks** at exactly the same frames, keeping audio and video in sync.

---

## AI agent (MCP)

When Palmier Pro is running, it exposes an MCP server at `http://127.0.0.1:19789/mcp`. Any connected agent (Claude, Codex, Cursor, etc.) can remove silence using the `remove_silence` tool.

### Natural language

```
Remove the silences from the first clip
Cut all the dead air
Tighten the pauses — use a threshold of -30 dB
Remove silence, minimum gap 1 second
```

### Tool: `remove_silence`

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

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `clipId` | string | **required** | Clip ID from `get_timeline`. Must be an audio clip or a video clip with audio. |
| `thresholdDb` | number | `−35` | Loudness floor in dBFS (must be ≤ 0). Audio quieter than this is treated as silence. |
| `minSilenceDuration` | number | `0.5` | Minimum silence length in seconds to remove. |
| `edgePadding` | number | `0.05` | Seconds of audio preserved on each side of a detected silence. |

#### Response

```json
{
  "removedSilences": 12,
  "removedFrames": 1440,
  "thresholdDb": -35,
  "note": "Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit."
}
```

#### Workflow example

```
1. get_timeline          → find the clip ID
2. remove_silence        → detect and remove silences
3. get_transcript        → verify the result (optional)
4. undo                  → revert if the result is not right
```

---

## Tips

- **Nothing removed?** Lower the threshold (e.g. −30 dB) or reduce **Min duration**.
- **Speech clipped?** Increase **Edge padding** (e.g. 0.1 s) to keep more audio around each cut.
- **Too many cuts?** Raise **Min duration** (e.g. 1.0 s) to skip short pauses.
- **Linked clips out of sync after unlink?** Always run Remove Silence while clips are linked so both tracks receive identical cuts.
