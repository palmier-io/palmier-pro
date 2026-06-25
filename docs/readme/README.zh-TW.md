> 此翻譯由 AI 生成。如發現錯誤，歡迎提交 PR。

<div align="center">

# Palmier Pro

**專為 AI 打造的影片剪輯器。**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="下載 macOS 版 Palmier Pro" width="180" />
</a>

<sub><i>需要搭載 Apple Silicon 的 macOS 26 (Tahoe)</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="在 X 上追蹤" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="加入 Discord" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <strong>繁體中文</strong> ·
  <a href="README.ja.md">日本語</a> ·
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

<img src="../../assets/palmier-ui.png" alt="Palmier Pro 介面" width="900" />

---

Palmier Pro 是 Mac 的開源影片剪輯器。你和你的 agent 可以在時間軸中一起生成和剪輯影片。

### Swift 原生影片剪輯器

我們用 Swift 從零打造 Palmier Pro。參考目標是 Premiere Pro，並以我們自己的方式把 AI 融入工作流程。

### 內建生成式 AI

在時間軸編輯器內使用 Seedance、Kling、Nano Banana Pro 等前沿模型生成影片和影像。

### 與你的 agent 整合

透過 MCP 連接 Claude、Codex 或 Cursor，或使用 app 內建 agent 在同一個專案中協作。

## MCP 伺服器

app 開啟時，會透過 HTTP 在 `http://127.0.0.1:19789/mcp` 暴露 MCP 伺服器。連接方式：

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

最簡單的方法是在 app 內開啟 `Help` -> `MCP Instructions` -> `Install in Cursor`，也可以手動把以下內容加入 `~/.cursor/mcp.json`：

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

app 內建一個 [mcpb](https://github.com/modelcontextprotocol/mcpb)，可在 Claude Desktop 中一鍵安裝桌面擴充功能。開啟 `Help` -> `MCP Instructions` -> `Install in Claude Desktop`。

## FAQ

**Palmier Pro 是否完全開源？**

影片剪輯器本身完全開源，不包含生成式 AI 功能。MCP 伺服器和 agent 聊天也開源。唯一閉源的是生成式 AI 處理部分。

**是否免費？**

編輯器免費。你可以無需登入直接下載，並像使用 CapCut 或 Adobe Premiere 一樣把它當作影片剪輯器使用。你也可以免費使用 MCP 伺服器，並透過 Claude Code、Claude Desktop 或 Cursor 與時間軸編輯器互動。

生成式 AI 功能需要登入和訂閱。

**支援哪些平台？**

僅支援搭載 Apple Silicon 的 macOS 26 (Tahoe)。

更多內容請查看 [FAQ.md](../../FAQ.md)。

## 開發

查看 [CONTRIBUTING.md](../../CONTRIBUTING.md)。

## 社群與支援

- **Discord:** 在 **[Discord](https://discord.com/invite/SMVW6pKYmg)** 加入社群。
- **Twitter / X:** 追蹤 **[@Palmier_io](https://x.com/Palmier_io)** 取得更新和公告。
- **Instagram:** 追蹤 [@palmier.io](https://www.instagram.com/palmier.io)。
- **回饋與支援:** 建立 [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) 或寄信到 founders@palmier.io。

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="Star History 圖表" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## 授權

Copyright (C) 2026 Palmier, Inc.

Palmier Pro 基於 [GPLv3](../../LICENSE) 開源。
