> 此翻译由 AI 生成。如发现错误，欢迎提交 PR。

<div align="center">

# Palmier Pro

**专为 AI 打造的视频编辑器。**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="下载 macOS 版 Palmier Pro" width="180" />
</a>

<sub><i>需要搭载 Apple Silicon 的 macOS 26 (Tahoe)</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="在 X 上关注" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="加入 Discord" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <strong>简体中文</strong> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
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

<img src="../../assets/palmier-ui.png" alt="Palmier Pro 界面" width="900" />

---

Palmier Pro 是面向 Mac 的开源视频编辑器。你和你的 agent 可以在时间线中一起生成和编辑视频。

### Swift 原生视频编辑器

我们用 Swift 从零构建了 Palmier Pro。参考目标是 Premiere Pro，并以我们自己的方式把 AI 融入工作流。

### 内置生成式 AI

在时间线编辑器内使用 Seedance、Kling、Nano Banana Pro 等前沿模型生成视频和图像。

### 与你的 agent 集成

通过 MCP 连接 Claude、Codex 或 Cursor，或使用应用内 agent 在同一个项目中协作。

## MCP 服务器

应用打开时，会通过 HTTP 在 `http://127.0.0.1:19789/mcp` 暴露 MCP 服务器。连接方式：

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

最简单的方法是在应用内打开 `Help` -> `MCP Instructions` -> `Install in Cursor`，也可以手动把以下内容添加到 `~/.cursor/mcp.json`：

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

应用内置了一个 [mcpb](https://github.com/modelcontextprotocol/mcpb)，可在 Claude Desktop 中一键安装桌面扩展。打开 `Help` -> `MCP Instructions` -> `Install in Claude Desktop`。

## FAQ

**Palmier Pro 是否完全开源？**

视频编辑器本身完全开源，不包括生成式 AI 功能。MCP 服务器和 agent 聊天也开源。唯一闭源的是生成式 AI 处理部分。

**是否免费？**

编辑器免费。你可以无需登录直接下载，并像使用 CapCut 或 Adobe Premiere 一样把它用作视频编辑器。你也可以免费使用 MCP 服务器，并通过 Claude Code、Claude Desktop 或 Cursor 与时间线编辑器交互。

生成式 AI 功能需要登录和订阅。

**支持哪些平台？**

仅支持搭载 Apple Silicon 的 macOS 26 (Tahoe)。

更多内容请查看 [FAQ.md](../../FAQ.md)。

## 开发

查看 [CONTRIBUTING.md](../../CONTRIBUTING.md)。

## 社区与支持

- **Discord:** 在 **[Discord](https://discord.com/invite/SMVW6pKYmg)** 加入社区。
- **Twitter / X:** 关注 **[@Palmier_io](https://x.com/Palmier_io)** 获取更新和公告。
- **Instagram:** 关注 [@palmier.io](https://www.instagram.com/palmier.io)。
- **反馈与支持:** 创建 [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) 或发送邮件至 founders@palmier.io。

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="Star History 图表" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## 许可证

Copyright (C) 2026 Palmier, Inc.

Palmier Pro 基于 [GPLv3](../../LICENSE) 开源。
