> [!IMPORTANT]
> Palmier Pro releases through v0.7.6, and source code through [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source), were published under GPLv3. Later binary releases are proprietary, and their corresponding source is not published. This repository preserves the historical source and hosts current binary releases and update metadata.

<div align="center">

# Palmier Pro

**The video editor built for AI.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="./assets/macos-badge.png" alt="Download Palmier Pro for macOS" width="180" />
</a>

<sub><i>Requires macOS 26 (Tahoe) on Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="Follow on X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Join Discord" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <strong>English</strong> ·
  <a href="docs/readme/README.es.md">Español</a> ·
  <a href="docs/readme/README.zh-CN.md">简体中文</a> ·
  <a href="docs/readme/README.zh-TW.md">繁體中文</a> ·
  <a href="docs/readme/README.ja.md">日本語</a> ·
  <a href="docs/readme/README.ko.md">한국어</a> ·
  <a href="docs/readme/README.vi.md">Tiếng Việt</a> ·
  <a href="docs/readme/README.hi.md">हिन्दी</a> ·
  <a href="docs/readme/README.bn.md">বাংলা</a> ·
  <a href="docs/readme/README.ar.md">العربية</a> ·
  <a href="docs/readme/README.it.md">Italiano</a> ·
  <a href="docs/readme/README.pt-BR.md">Português (Brasil)</a> ·
  <a href="docs/readme/README.fr.md">Français</a> ·
  <a href="docs/readme/README.ru.md">Русский</a> ·
  <a href="docs/readme/README.tr.md">Türkçe</a>
</p>

</div>

<img src="./assets/palmier-ui.png" alt="Palmier Pro UI" width="900" />

---

Palmier Pro is a macOS video editor with built-in AI generation and MCP support, allowing agents to create and edit directly on the timeline.

### Swift-native video editor

We built Palmier Pro from scratch with Swift. The north star is Premiere Pro, with our take on integrating AI into the workflow.

### Built-in Generative AI

Generate videos and images with SOTA models like Seedance, Kling, Nano Banana Pro inside the timeline editor.

### Integrates with your agents

Connects your Claude/Codex/Cursor via MCP, or use the in-app agent to work on the same project together.

## MCP server

When the app is open, it exposes an MCP server at `http://127.0.0.1:19789/mcp` via HTTP. To connect:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

The easiest way is go inside the app `Help` -> `MCP Instructions` -> `Install in Cursor`, or install manually by adding this to `~/.cursor/mcp.json`:

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

We bundle a [mcpb](https://github.com/modelcontextprotocol/mcpb) with the app that allows a one click install Desktop Extension on Claude Desktop. Go to `Help` -> `MCP Instructions` -> `Install in Claude Desktop`

## FAQ

**Which versions of Palmier Pro are open source?**

Releases through v0.7.6 and source through `last-gpl-source` remain available under GPLv3. Later releases are proprietary.

**What platforms does it support?**

macOS 26 (Tahoe) or later on Apple Silicon (M series) only.

## Contributing

This repository no longer accepts code contributions. The published source remains available for use, modification, and redistribution under GPLv3.

## Community &amp; Support

- **Discord:** Join the community on **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Follow **[@Palmier_io](https://x.com/Palmier_io)** for updates and announcements.
- **Instagram:** Follow [@palmier.io](https://www.instagram.com/palmier.io) 
- **Feedback &amp; Support:** Email founders@palmier.io.

## License

Copyright (C) 2026 Palmier, Inc.

The source code published in this repository remains available under [GPLv3](LICENSE).

Palmier Pro binary releases after v0.7.6 are proprietary and subject to the [binary license](BINARY_LICENSE.md).
