> Questa traduzione è stata generata con l'AI. Se trovi un errore, apri una PR.

<div align="center">

# Palmier Pro

**Il video editor creato per l'AI.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Scarica Palmier Pro per macOS" width="180" />
</a>

<sub><i>Richiede macOS 26 (Tahoe) su Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="Segui su X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Entra su Discord" /></a>
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
  <a href="README.ar.md">العربية</a> ·
  <strong>Italiano</strong> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Interfaccia di Palmier Pro" width="900" />

---

Palmier Pro è un video editor open source per Mac. Tu e il tuo agent potete generare e modificare video insieme dentro la timeline.

### Video editor nativo Swift

Abbiamo costruito Palmier Pro da zero con Swift. Il riferimento è Premiere Pro, con il nostro modo di integrare l'AI nel workflow.

### AI generativa integrata

Genera video e immagini con modelli all'avanguardia come Seedance, Kling e Nano Banana Pro direttamente nell'editor timeline.

### Integrazione con i tuoi agent

Collega Claude, Codex o Cursor tramite MCP, oppure usa l'agent integrato nell'app per lavorare insieme sullo stesso progetto.

## Server MCP

Quando l'app è aperta, espone un server MCP su `http://127.0.0.1:19789/mcp` tramite HTTP. Per connetterti:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

Il modo più semplice è aprire nell'app `Help` -> `MCP Instructions` -> `Install in Cursor`, oppure installarlo manualmente aggiungendo questo a `~/.cursor/mcp.json`:

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

Includiamo un [mcpb](https://github.com/modelcontextprotocol/mcpb) con l'app che consente l'installazione con un clic della Desktop Extension su Claude Desktop. Apri `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**Palmier Pro è completamente open source?**

Il video editor, senza le funzioni di AI generativa, è completamente open source. Anche il server MCP e la chat dell'agent sono open source. L'unica parte closed source è l'elaborazione dell'AI generativa.

**È gratis?**

L'editor è gratuito. Puoi scaricarlo senza login e usarlo come video editor, come CapCut o Adobe Premiere. Puoi anche usare gratis il server MCP e iniziare a sperimentare con Claude Code, Claude Desktop o Cursor per interagire con il tuo editor timeline.

Le funzioni di AI generativa richiedono login e abbonamento.

**Quali piattaforme supporta?**

Solo macOS 26 (Tahoe) su Apple Silicon.

Vedi [FAQ.md](../../FAQ.md) per maggiori dettagli.

## Sviluppo

Vedi [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Community e supporto

- **Discord:** Entra nella community su **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Segui **[@Palmier_io](https://x.com/Palmier_io)** per aggiornamenti e annunci.
- **Instagram:** Segui [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback e supporto:** Crea una [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) o scrivici a founders@palmier.io.

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="Grafico Star History" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## Licenza

Copyright (C) 2026 Palmier, Inc.

Palmier Pro è open source sotto [GPLv3](../../LICENSE).
