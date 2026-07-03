> 此翻译由 AI 生成。如有错误，欢迎提交 PR。

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <a href="es.md">Español</a> ·
  <strong>简体中文</strong> ·
  <a href="zh-TW.md">繁體中文</a> ·
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

# 移除静音

自动检测并移除片段中的静音区域。检测完全在本地设备上运行，基于片段的音频波形——无需网络连接或字幕文件。

---

## 桌面端

### 1. 选择片段

在时间线上点击任意**视频或音频片段**。仅当选中单个片段（或已关联的音视频对）时，"移除静音"按钮才会激活。

### 2. 打开面板

点击工具栏中的**波形减号图标**（`waveform.badge.minus`），或选择 **编辑 → 移除静音**。

面板打开后，将立即使用当前设置开始检测静音。

### 3. 调整参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| **Threshold** | −35 dB | 音量下限，低于此值的音频将被视为静音。向 0 dB 方向调高（如 −25 dB）可捕捉更安静的停顿；向下调低（如 −45 dB）则仅移除近乎完全无声的部分。 |
| **Min duration** | 0.5 s | 将被移除的最短静音时长。调高此值可保留自然的呼吸声和短暂停顿；调低则连短暂的间隙也会被剪切。 |
| **Edge padding** | 0.05 s | 在检测到的静音两侧各保留的音频时长，防止语音和音符被切断。若出现词语被截断的情况，请适当增大此值。 |

修改任意参数后，点击 **Detect** 以使用新参数重新运行检测。面板将显示检测到的静音数量。

### 4. 应用

点击 **Remove Silences**。静音区域将以波纹删除方式处理——片段自动合拢，后续内容左移填补间隙。此编辑为单步可撤销操作：按 **⌘Z** 可恢复原始状态。

---

## 关联的音视频片段

当视频片段与其音频已关联（两条轨道上的链条图标均处于闭合状态）时，选中任意一个片段即同时选中该组合。移除静音功能读取音频波形进行检测，并在**完全相同的帧位置**对两条轨道同时执行剪切，确保音视频保持同步。

---

## AI 代理（MCP）

Palmier Pro 运行时，会在 `http://127.0.0.1:19789/mcp` 暴露一个 MCP 服务器。任何已连接的代理（Claude、Codex、Cursor 等）均可使用 `remove_silence` 工具移除静音。

### 自然语言示例

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

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `clipId` | string | **必填** | 来自 `get_timeline` 的片段 ID。必须是音频片段或包含音频的视频片段。 |
| `thresholdDb` | number | `−35` | 以 dBFS 为单位的音量下限（必须 ≤ 0）。低于此值的音频将被视为静音。 |
| `minSilenceDuration` | number | `0.5` | 将被移除的最短静音时长（秒）。 |
| `edgePadding` | number | `0.05` | 在检测到的静音两侧各保留的音频时长（秒）。 |

#### 响应

```json
{
  "removedSilences": 12,
  "removedFrames": 1440,
  "thresholdDb": -35,
  "note": "Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit."
}
```

#### 工作流程示例

```
1. get_timeline          → 获取片段 ID
2. remove_silence        → 检测并移除静音
3. get_transcript        → 验证结果（可选）
4. undo                  → 如结果不符合预期则撤销
```

---

## 使用技巧

- **没有内容被移除？** 调低阈值（如 −30 dB）或减小 **Min duration**。
- **语音被截断？** 增大 **Edge padding**（如 0.1 s），在每个剪切点两侧保留更多音频。
- **剪切过多？** 调高 **Min duration**（如 1.0 s），跳过短暂停顿。
- **取消关联后音视频不同步？** 请始终在片段关联状态下运行移除静音功能，确保两条轨道接受完全相同的剪切。
