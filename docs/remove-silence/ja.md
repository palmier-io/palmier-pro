> この翻訳は AI によって生成されました。誤りがあれば PR を送ってください。

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <a href="es.md">Español</a> ·
  <a href="zh-CN.md">简体中文</a> ·
  <a href="zh-TW.md">繁體中文</a> ·
  <strong>日本語</strong> ·
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

# 無音区間の削除

クリップの無音区間を自動的に検出して削除します。検出はクリップの音声波形を使ってすべてデバイス上で実行されます。インターネット接続やトランスクリプトは不要です。

## デスクトップ

### 1. クリップを選択する
タイムライン上の**映像クリップまたは音声クリップ**をクリックします。Remove Silence ボタンは、単一のクリップ（またはリンクされた音声/映像ペア）が選択されているときのみ有効になります。

### 2. シートを開く
ツールバーの**波形マイナスアイコン**（`waveform.badge.minus`）をクリックするか、**Edit → Remove Silence** を選択します。シートが開き、現在の設定を使って無音検出がすぐに開始されます。

### 3. パラメータを調整する

| パラメータ | デフォルト | 説明 |
|-----------|---------|-------------|
| **Threshold** | −35 dB | 無音と見なす音量の下限。−25 dB など 0 dB 側に上げると静かな間合いも検出できます。−45 dB など下げると、ほぼ完全な無音のみを削除します。 |
| **Min duration** | 0.5 s | 削除する無音の最短時間。自然な息継ぎや短い間合いを残すには値を上げ、短いギャップも切り取るには下げます。 |
| **Edge padding** | 0.05 s | 検出された無音の両端に残す音声の長さ。発話や音符が切り取られないようにします。言葉が切れる場合は増やしてください。 |

パラメータを変更した後、**Detect** をクリックして新しい値で再検出を実行します。シートに検出された無音の件数が表示されます。

### 4. 適用する
**Remove Silences** をクリックします。無音区間がリップル削除され、クリップが詰められてギャップを埋めるように後続コンテンツが左に移動します。この編集は単一の取り消し可能なアクションです。**⌘Z** を押すと元の状態に戻せます。

## リンクされた音声/映像クリップ
映像クリップとその音声がリンクされている場合（両トラックのチェーンアイコンが閉じている状態）、どちらかのクリップを選択するとペアが選択されます。Remove Silence は音声波形を読み込んで検出を行い、**両トラック**をまったく同じフレームでカットすることで音声と映像の同期を保ちます。

## AI エージェント（MCP）
Palmier Pro が起動中の場合、`http://127.0.0.1:19789/mcp` に MCP サーバーを公開します。接続されたエージェント（Claude、Codex、Cursor など）は `remove_silence` ツールを使って無音を削除できます。

### 自然言語
```
Remove the silences from the first clip
Cut all the dead air
Tighten the pauses — use a threshold of -30 dB
Remove silence, minimum gap 1 second
```

### ツール: `remove_silence`
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

#### パラメータ
| パラメータ | 型 | デフォルト | 説明 |
|-----------|------|---------|-------------|
| `clipId` | string | **必須** | `get_timeline` から取得したクリップ ID。音声クリップ、または音声付き映像クリップである必要があります。 |
| `thresholdDb` | number | `−35` | dBFS 単位の音量下限（0 以下）。これより小さい音量は無音として扱われます。 |
| `minSilenceDuration` | number | `0.5` | 削除する無音の最短時間（秒）。 |
| `edgePadding` | number | `0.05` | 検出された無音の両端に保持する音声の秒数。 |

#### レスポンス
```json
{
  "removedSilences": 12,
  "removedFrames": 1440,
  "thresholdDb": -35,
  "note": "Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit."
}
```

#### ワークフロー例
```
1. get_timeline          → クリップ ID を取得する
2. remove_silence        → 無音を検出して削除する
3. get_transcript        → 結果を確認する（任意）
4. undo                  → 結果が意図と異なる場合に元に戻す
```

## ヒント
- **何も削除されない?** Threshold を下げる（例: −30 dB）か、**Min duration** を小さくしてください。
- **発話が切れる?** **Edge padding** を増やして（例: 0.1 s）、各カット周辺の音声を多く残してください。
- **カットが多すぎる?** **Min duration** を上げて（例: 1.0 s）、短い間合いをスキップしてください。
- **リンク解除後にクリップがずれる?** 両トラックに同一のカットが適用されるよう、クリップがリンクされた状態で必ず Remove Silence を実行してください。
