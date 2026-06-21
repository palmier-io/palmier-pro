> تمت ترجمة هذا الملف بواسطة AI. إذا لاحظت خطأ، افتح PR.

<div align="center">

# Palmier Pro

**محرر فيديو مصمم لـ AI.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="تنزيل Palmier Pro لنظام macOS" width="180" />
</a>

<sub><i>يتطلب macOS 26 (Tahoe) على Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="تابع على X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="انضم إلى Discord" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <a href="README.hi.md">हिन्दी</a> ·
  <a href="README.bn.md">বাংলা</a> ·
  <strong>العربية</strong> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="واجهة Palmier Pro" width="900" />

---

Palmier Pro هو محرر فيديو open source لنظام Mac. يمكنك أنت والـ agent الخاص بك إنشاء الفيديوهات وتحريرها معًا داخل timeline.

### محرر فيديو Swift-native

بنينا Palmier Pro من الصفر باستخدام Swift. المرجع الأساسي هو Premiere Pro، مع طريقتنا الخاصة في دمج AI داخل workflow.

### Generative AI مدمج

أنشئ فيديوهات وصورًا باستخدام نماذج SOTA مثل Seedance وKling وNano Banana Pro داخل محرر timeline.

### يتكامل مع agents الخاصة بك

صل Claude أو Codex أو Cursor عبر MCP، أو استخدم الـ agent داخل التطبيق للعمل معًا على المشروع نفسه.

## MCP server

عندما يكون التطبيق مفتوحًا، فإنه يوفّر MCP server على `http://127.0.0.1:19789/mcp` عبر HTTP. للاتصال:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

أسهل طريقة هي فتح `Help` -> `MCP Instructions` -> `Install in Cursor` داخل التطبيق، أو التثبيت يدويًا بإضافة هذا إلى `~/.cursor/mcp.json`:

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

نضمّن [mcpb](https://github.com/modelcontextprotocol/mcpb) مع التطبيق، ما يسمح بتثبيت Desktop Extension على Claude Desktop بنقرة واحدة. افتح `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**هل Palmier Pro بالكامل open source؟**

محرر الفيديو، بدون ميزات generative AI، مفتوح المصدر بالكامل. MCP server وagent chat مفتوحا المصدر أيضًا. الجزء الوحيد closed source هو معالجة generative AI.

**هل هو مجاني؟**

المحرر مجاني. يمكنك تنزيله دون تسجيل دخول واستخدامه كمحرر فيديو مثل CapCut أو Adobe Premiere. يمكنك أيضًا استخدام MCP server مجانًا والبدء بالتجربة مع Claude Code أو Claude Desktop أو Cursor للتفاعل مع محرر timeline.

ميزات generative AI تتطلب تسجيل الدخول والاشتراك.

**ما المنصات المدعومة؟**

macOS 26 (Tahoe) على Apple Silicon فقط.

راجع [FAQ.md](../../FAQ.md) للمزيد.

## Development

راجع [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Community والدعم

- **Discord:** انضم إلى المجتمع على **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** تابع **[@Palmier_io](https://x.com/Palmier_io)** للحصول على التحديثات والإعلانات.
- **Instagram:** تابع [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback والدعم:** افتح [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) أو راسلنا على founders@palmier.io.

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="مخطط Star History" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## License

Copyright (C) 2026 Palmier, Inc.

Palmier Pro مفتوح المصدر بموجب [GPLv3](../../LICENSE).
