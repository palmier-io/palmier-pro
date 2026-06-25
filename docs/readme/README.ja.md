> この翻訳は AI によって生成されました。誤りを見つけた場合は PR を開いてください。

<div align="center">

# Palmier Pro

**AI のために作られた動画エディタ。**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Palmier Pro for macOS をダウンロード" width="180" />
</a>

<sub><i>Apple Silicon 搭載の macOS 26 (Tahoe) が必要</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="X でフォロー" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Discord に参加" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <strong>日本語</strong> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <a href="README.hi.md">हिन्दी</a> ·
  <a href="README.bn.md">বাংলা</a> ·
  <a href="README.ar.md">العربية</a> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Palmier Pro の UI" width="900" />

---

Palmier Pro は Mac 向けのオープンソース動画エディタです。ユーザーと agent がタイムライン上で一緒に動画を生成、編集できます。

### Swift ネイティブ動画エディタ

Palmier Pro は Swift でゼロから構築しました。目指す基準は Premiere Pro で、AI をワークフローに統合する独自の形をとっています。

### 内蔵の生成 AI

タイムラインエディタ内で Seedance、Kling、Nano Banana Pro などの最先端モデルを使い、動画と画像を生成できます。

### agent との連携

MCP で Claude、Codex、Cursor と接続できます。アプリ内 agent を使って、同じプロジェクトで一緒に作業することもできます。

## MCP サーバー

アプリが開いている間、HTTP 経由で `http://127.0.0.1:19789/mcp` に MCP サーバーを公開します。接続方法：

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

最も簡単な方法は、アプリ内で `Help` -> `MCP Instructions` -> `Install in Cursor` を開くことです。手動で設定する場合は、`~/.cursor/mcp.json` に以下を追加します。

```
{
  "mcpServers": {
    "palmier-pro": {
      "type": "http",
      "url": "http://127.0.0.1:19789/mcp"
    }
  }
}
```

**Claude Desktop**

アプリには [mcpb](https://github.com/modelcontextprotocol/mcpb) が同梱されており、Claude Desktop の Desktop Extension をワンクリックでインストールできます。`Help` -> `MCP Instructions` -> `Install in Claude Desktop` を開いてください。

## FAQ

**Palmier Pro は完全にオープンソースですか？**

動画エディタは、生成 AI 機能を除いて完全にオープンソースです。MCP サーバーと agent チャットもオープンソースです。クローズドソースなのは生成 AI 処理だけです。

**無料ですか？**

エディタは無料です。ログインなしでダウンロードでき、CapCut や Adobe Premiere のような動画エディタとして使えます。MCP サーバーも無料で使え、Claude Code、Claude Desktop、Cursor からタイムラインエディタを操作して試せます。

生成 AI 機能にはログインとサブスクリプションが必要です。

**対応プラットフォームは？**

Apple Silicon 搭載の macOS 26 (Tahoe) のみです。

詳細は [FAQ.md](../../FAQ.md) を参照してください。

## 開発

[CONTRIBUTING.md](../../CONTRIBUTING.md) を参照してください。

## コミュニティとサポート

- **Discord:** **[Discord](https://discord.com/invite/SMVW6pKYmg)** でコミュニティに参加できます。
- **Twitter / X:** 更新と告知は **[@Palmier_io](https://x.com/Palmier_io)** をフォローしてください。
- **Instagram:** [@palmier.io](https://www.instagram.com/palmier.io) をフォローしてください。
- **フィードバックとサポート:** [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) を作成するか、founders@palmier.io にメールしてください。

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## ライセンス

Copyright (C) 2026 Palmier, Inc.

Palmier Pro は [GPLv3](../../LICENSE) のもとでオープンソースとして公開されています。
