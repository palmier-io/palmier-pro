> تمت ترجمة هذا الملف بواسطة AI. إذا لاحظت خطأ، افتح PR.

<div align="center">

# Palmier Pro

**محرر فيديو مصمم لعصر الذكاء الاصطناعي.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="تنزيل Palmier Pro لنظام macOS" width="180" />
</a>

<sub><i>يتطلب macOS 26 (Tahoe) على Apple Silicon لتحميله</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="تابع على X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="انضم إلى Discord" /></a>
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
  <a href="README.bn.md">বাংলা</a> ·
  <strong>العربية</strong> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="واجهة Palmier Pro" width="900" />

---

بالمي برو (Palmier Pro) هو محرر فيديو مفتوح المصدر لنظام macOS. يتيح لك العمل جنبًا إلى جنب مع المساعد الذكي الخاص بك لإنشاء الفيديوهات وتحريرها داخل الخط الزمني (Timeline) نفسه.

### محرر فيديو Swift-native

تم تطوير بالمي برو (Palmier Pro) من الصفر باستخدام Swift. استلهمنا تجربة الاستخدام من Premiere Pro، مع إعادة تصميمها لتناسب أدوات الذكاء الاصطناعي الحديثة وسير العمل المعتمد عليها.

### ذكاء اصطناعي توليدي مدمج (Generative AI)

أنشئ الفيديوهات والصور مباشرة من داخل المحرر باستخدام أحدث النماذج مثل Seedance وKling وNano Banana Pro، دون الحاجة إلى التنقل بين تطبيقات متعددة.

### يتكامل مع أدواتك ومساعديك الذكيين

يمكنك ربط Claude أو Codex أو Cursor عبر MCP، أو استخدام المساعد المدمج داخل التطبيق للعمل معًا على المشروع نفسه.
## خادم الMCP

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

يدعم Palmier Pro حاليًا:
* macOS 26 (Tahoe)
* أجهزة Apple Silicon فقط
  
راجع [FAQ.md](../../FAQ.md) للمزيد.

## Development

راجع [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Community والدعم

- **Discord:** انضم إلى المجتمع على **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** تابع **[@Palmier_io](https://x.com/Palmier_io)** للحصول على التحديثات والإعلانات.
- **Instagram:** تابع [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback والدعم:** افتح [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) أو راسلنا على founders@palmier.io.

## Star History

<a href="https://www.star-history.com/?repos=palmier-io%2Fpalmier-pro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <img alt="مخطط Star History" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
 </picture>
</a>

## License

Copyright (C) 2026 Palmier, Inc.

Palmier Pro مفتوح المصدر بموجب [GPLv3](../../LICENSE).
