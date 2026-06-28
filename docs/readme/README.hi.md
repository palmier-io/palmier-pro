> यह अनुवाद AI से बनाया गया है। अगर आपको कोई त्रुटि दिखे, तो कृपया PR खोलें।

<div align="center">

# Palmier Pro

**AI के लिए बनाया गया वीडियो एडिटर।**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="macOS के लिए Palmier Pro डाउनलोड करें" width="180" />
</a>

<sub><i>Apple Silicon पर macOS 26 (Tahoe) आवश्यक</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="X पर फॉलो करें" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Discord से जुड़ें" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <strong>हिन्दी</strong> ·
  <a href="README.bn.md">বাংলা</a> ·
  <a href="README.ar.md">العربية</a> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Palmier Pro UI" width="900" />

---

Palmier Pro Mac के लिए एक open source वीडियो एडिटर है। आप और आपका agent timeline के अंदर साथ मिलकर वीडियो generate और edit कर सकते हैं।

### Swift-native वीडियो एडिटर

हमने Palmier Pro को Swift में scratch से बनाया है। हमारा संदर्भ Premiere Pro है, लेकिन AI को workflow में शामिल करने का तरीका हमारा अपना है।

### Built-in Generative AI

Timeline editor के अंदर Seedance, Kling और Nano Banana Pro जैसे उन्नत models से वीडियो और images generate करें।

### आपके agents के साथ integration

Claude, Codex या Cursor को MCP के जरिए connect करें, या उसी project पर साथ काम करने के लिए in-app agent इस्तेमाल करें।

## MCP server

जब app खुली होती है, यह HTTP के जरिए `http://127.0.0.1:19789/mcp` पर MCP server expose करती है। Connect करने के लिए:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

सबसे आसान तरीका है app के अंदर `Help` -> `MCP Instructions` -> `Install in Cursor` खोलना। Manual install के लिए इसे `~/.cursor/mcp.json` में जोड़ें:

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

App के साथ एक [mcpb](https://github.com/modelcontextprotocol/mcpb) शामिल है, जिससे Claude Desktop में Desktop Extension one-click install हो सकता है। `Help` -> `MCP Instructions` -> `Install in Claude Desktop` खोलें।

## FAQ

**क्या Palmier Pro पूरी तरह open source है?**

वीडियो एडिटर, generative AI features को छोड़कर, पूरी तरह open source है। MCP server और agent chat भी open source हैं। सिर्फ generative AI processing closed source है।

**क्या यह free है?**

एडिटर free है। आप इसे बिना login डाउनलोड कर सकते हैं और CapCut या Adobe Premiere जैसे वीडियो एडिटर की तरह इस्तेमाल कर सकते हैं। MCP server भी free है, और आप Claude Code, Claude Desktop या Cursor से अपने timeline editor के साथ experiment शुरू कर सकते हैं।

Generative AI features के लिए login और subscription चाहिए।

**यह किन platforms को support करता है?**

सिर्फ Apple Silicon पर macOS 26 (Tahoe)।

और जानकारी के लिए [FAQ.md](../../FAQ.md) देखें।

## Development

[CONTRIBUTING.md](../../CONTRIBUTING.md) देखें।

## Community और support

- **Discord:** **[Discord](https://discord.com/invite/SMVW6pKYmg)** पर community से जुड़ें।
- **Twitter / X:** Updates और announcements के लिए **[@Palmier_io](https://x.com/Palmier_io)** को follow करें।
- **Instagram:** [@palmier.io](https://www.instagram.com/palmier.io) को follow करें।
- **Feedback और support:** [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) बनाएं या founders@palmier.io पर email करें।

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## License

Copyright (C) 2026 Palmier, Inc.

Palmier Pro [GPLv3](../../LICENSE) के तहत open source है।
