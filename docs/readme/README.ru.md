> Этот перевод создан с помощью AI. Если заметите ошибку, откройте PR.

<div align="center">

# Palmier Pro

**Видеоредактор, созданный для AI.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Скачать Palmier Pro для macOS" width="180" />
</a>

<sub><i>Требуется macOS 26 (Tahoe) на Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="Подписаться в X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Присоединиться к Discord" /></a>
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
  <a href="README.ar.md">العربية</a> ·
  <a href="README.it.md">Italiano</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <strong>Русский</strong> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Интерфейс Palmier Pro" width="900" />

---

Palmier Pro — open source видеоредактор для Mac. Вы и ваш agent можете вместе генерировать и редактировать видео прямо на таймлайне.

### Видеоредактор, нативный для Swift

Мы построили Palmier Pro с нуля на Swift. Ориентир — Premiere Pro, но с нашим подходом к интеграции AI в рабочий процесс.

### Встроенный generative AI

Генерируйте видео и изображения с помощью передовых моделей, таких как Seedance, Kling и Nano Banana Pro, прямо в редакторе таймлайна.

### Интеграция с вашими agent

Подключайте Claude, Codex или Cursor через MCP либо используйте встроенного agent в приложении, чтобы работать вместе над одним проектом.

## MCP server

Когда приложение открыто, оно предоставляет MCP server по адресу `http://127.0.0.1:19789/mcp` через HTTP. Для подключения:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

Самый простой способ — открыть в приложении `Help` -> `MCP Instructions` -> `Install in Cursor`. Также можно установить вручную, добавив это в `~/.cursor/mcp.json`:

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

Мы поставляем [mcpb](https://github.com/modelcontextprotocol/mcpb) вместе с приложением, чтобы Desktop Extension для Claude Desktop можно было установить в один клик. Откройте `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**Palmier Pro полностью open source?**

Видеоредактор, без функций generative AI, полностью open source. MCP server и agent chat тоже open source. Закрытой остается только обработка generative AI.

**Это бесплатно?**

Редактор бесплатный. Его можно скачать без входа в аккаунт и использовать как видеоредактор, например CapCut или Adobe Premiere. MCP server тоже можно использовать бесплатно и начать экспериментировать с Claude Code, Claude Desktop или Cursor для взаимодействия с редактором таймлайна.

Функции generative AI требуют входа в аккаунт и подписки.

**Какие платформы поддерживаются?**

Только macOS 26 (Tahoe) на Apple Silicon.

Подробнее см. [FAQ.md](../../FAQ.md).

## Разработка

См. [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Сообщество и поддержка

- **Discord:** Присоединяйтесь к сообществу в **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Подписывайтесь на **[@Palmier_io](https://x.com/Palmier_io)**, чтобы получать обновления и анонсы.
- **Instagram:** Подписывайтесь на [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback и поддержка:** Создайте [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) или напишите нам на founders@palmier.io.

## Star History

<a href="https://www.star-history.com/?repos=palmier-io%2Fpalmier-pro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <img alt="График Star History" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
 </picture>
</a>

## Лицензия

Copyright (C) 2026 Palmier, Inc.

Palmier Pro распространяется как open source по лицензии [GPLv3](../../LICENSE).
