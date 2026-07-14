> এই অনুবাদটি AI দিয়ে তৈরি। কোনো ভুল দেখলে অনুগ্রহ করে একটি PR খুলুন।

<div align="center">

# Palmier Pro

**AI-এর জন্য তৈরি ভিডিও এডিটর।**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="macOS-এর জন্য Palmier Pro ডাউনলোড করুন" width="180" />
</a>

<sub><i>Apple Silicon-এ macOS 26 (Tahoe) প্রয়োজন</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="X-এ অনুসরণ করুন" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Discord-এ যোগ দিন" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>
<br />
<a href="https://trendshift.io/repositories/41342?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-41342" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/41342" alt="palmier-io%2Fpalmier-pro | Trendshift" width="250" height="55"/></a>

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <a href="README.hi.md">हिन्दी</a> ·
  <strong>বাংলা</strong> ·
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

Palmier Pro Mac-এর জন্য একটি open source ভিডিও এডিটর। আপনি এবং আপনার agent timeline-এর ভিতরে একসঙ্গে ভিডিও generate ও edit করতে পারেন।

### Swift-native ভিডিও এডিটর

আমরা Swift দিয়ে Palmier Pro একদম শুরু থেকে তৈরি করেছি। আমাদের উত্তর তারা Premiere Pro, তবে workflow-তে AI যুক্ত করার নিজস্ব পদ্ধতি নিয়ে।

### Built-in Generative AI

Timeline editor-এর ভিতর Seedance, Kling, Nano Banana Pro-এর মতো SOTA models দিয়ে ভিডিও এবং ছবি generate করুন।

### আপনার agents-এর সঙ্গে integration

MCP-এর মাধ্যমে Claude, Codex বা Cursor connect করুন, অথবা একই project-এ একসঙ্গে কাজ করতে in-app agent ব্যবহার করুন।

## MCP server

App খোলা থাকলে, এটি HTTP-এর মাধ্যমে `http://127.0.0.1:19789/mcp`-এ একটি MCP server expose করে। Connect করতে:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

সবচেয়ে সহজ উপায় হলো app-এর ভিতরে `Help` -> `MCP Instructions` -> `Install in Cursor`-এ যাওয়া। Manual install করতে `~/.cursor/mcp.json`-এ এটি যোগ করুন:

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

App-এর সঙ্গে আমরা একটি [mcpb](https://github.com/modelcontextprotocol/mcpb) bundle করি, যা Claude Desktop-এ Desktop Extension এক click-এ install করতে দেয়। `Help` -> `MCP Instructions` -> `Install in Claude Desktop` খুলুন।

## FAQ

**Palmier Pro কি পুরোপুরি open source?**

Generative AI features ছাড়া ভিডিও এডিটরটি পুরোপুরি open source। MCP server এবং agent chat-ও open source। শুধু generative AI processing closed source।

**এটি কি free?**

Editor free। Login ছাড়াই আপনি এটি download করতে পারেন এবং CapCut বা Adobe Premiere-এর মতো ভিডিও এডিটর হিসেবে ব্যবহার করতে পারেন। MCP server-ও free, এবং Claude Code, Claude Desktop বা Cursor দিয়ে timeline editor-এর সঙ্গে experiment শুরু করতে পারেন।

Generative AI features-এর জন্য login এবং subscription প্রয়োজন।

**কোন platforms support করে?**

শুধু Apple Silicon-এ macOS 26 (Tahoe)।

আরও জানতে [FAQ.md](../../FAQ.md) দেখুন।

## Development

[CONTRIBUTING.md](../../CONTRIBUTING.md) দেখুন।

## Community এবং support

- **Discord:** **[Discord](https://discord.com/invite/SMVW6pKYmg)**-এ community-তে যোগ দিন।
- **Twitter / X:** Updates এবং announcements-এর জন্য **[@Palmier_io](https://x.com/Palmier_io)** follow করুন।
- **Instagram:** [@palmier.io](https://www.instagram.com/palmier.io) follow করুন।
- **Feedback এবং support:** একটি [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) তৈরি করুন অথবা founders@palmier.io-এ email করুন।

## Star History

<a href="https://www.star-history.com/?repos=palmier-io%2Fpalmier-pro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
 </picture>
</a>

## License

Copyright (C) 2026 Palmier, Inc.

Palmier Pro [GPLv3](../../LICENSE)-এর অধীনে open source।
