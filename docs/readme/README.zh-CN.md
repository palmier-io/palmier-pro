> 此翻译由 AI 辅助翻译。如发现错误，欢迎修改并提交 PR。

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
  <a href="README.ru.md">Русский</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Palmier Pro 界面" width="900" />

---

Palmier Pro 是面向 Mac 的开源视频编辑器。你和你的 Agent 可以在时间线中一起生成和编辑视频。

### 基于 Swift 原生开发的剪辑工具

本软件基于 Swift 从零原生开发，对标专业剪辑软件 Premiere Pro。软件独创 AI 深度融合架构，重构视频制作全流程，你可搭配各类 AI 智能代理，直接在时间线内协同生成、剪辑视频。

### 内置前沿生成式 AI 能力

可直接在时间线编辑器内调用多款行业顶尖 AI 模型生成图片、视频素材，包含字节跳动Seedance、可灵 Kling、Nano Banana Pro。

### 可对接各类 Agents 协同工作

通过 MCP 协议对接 Claude、Codex、Cursor 等 AI 工具，也可使用软件内置智能助手，多人 / 多 AI 协同处理同一剪辑工程。

## MCP 服务器

软件启动后，会在本地 `http://127.0.0.1:19789/mcp` 地址开启 HTTP 协议 MCP 服务，各工具连接配置如下：

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**
推荐快捷安装：打开软件顶部菜单栏 `Help` -> `MCP Instructions` -> `Install in Cursor`；
如需手动配置，将下方配置写入 `~/.cursor/mcp.json` 文件：

```json
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

软件内置了一个 [mcpb](https://github.com/modelcontextprotocol/mcpb)工具，支持一键为 Claude Desktop 安装配套桌面扩展。打开 `Help` -> `MCP Instructions` -> `Install in Claude Desktop`。

## FAQ

**Palmier Pro 是否完全开源？**

视频编辑器本身完全开源，不包括生成式 AI 功能。MCP 服务器和 Agent 聊天也开源。唯一闭源的是生成式 AI 处理部分。

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
