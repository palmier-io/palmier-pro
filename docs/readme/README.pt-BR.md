> Esta tradução foi gerada por IA. Se encontrar um erro, abra um PR.

<div align="center">

# Palmier Pro

**O editor de vídeo criado para IA.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Baixar Palmier Pro para macOS" width="180" />
</a>

<sub><i>Requer macOS 26 (Tahoe) em Macs com Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="Seguir no X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Entrar no Discord" /></a>
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
  <strong>Português (Brasil)</strong> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Interface do Palmier Pro" width="900" />

---

Palmier Pro é um editor de vídeo open source para Mac. Você e seu agente podem gerar e editar vídeos juntos dentro da linha do tempo.

### Editor de vídeo nativo em Swift

Construímos o Palmier Pro do zero com Swift. Inspirado no Premiere Pro, mas com a nossa própria forma de integrar IA ao fluxo de trabalho.

### IA generativa integrada

Gere vídeos e imagens com modelos de ponta como Seedance, Kling e Nano Banana Pro dentro do editor de linha do tempo.

### Integração com seus agentes

Conecte Claude, Codex ou Cursor via MCP, ou use o agente integrado ao app para trabalhar com você no mesmo projeto.

## Servidor MCP

Quando o app está aberto, ele expõe um servidor MCP em `http://127.0.0.1:19789/mcp` via HTTP. Para conectar:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

A forma mais fácil é abrir, no app, `Help` -> `MCP Instructions` -> `Install in Cursor`, ou instalar manualmente adicionando isto a `~/.cursor/mcp.json`:

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

Incluímos um pacote [mcpb](https://github.com/modelcontextprotocol/mcpb) no app que permite instalar a Desktop Extension no Claude Desktop com um clique. Abra `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**O Palmier Pro é totalmente open source?**

O editor de vídeo, sem os recursos de IA generativa, é totalmente open source. O servidor MCP e o chat do agente também são open source. A única parte proprietária é o processamento de IA generativa.

**É gratuito?**

O editor é gratuito. Você pode baixá-lo sem login e usá-lo como editor de vídeo, como CapCut ou Adobe Premiere. Você também pode usar o servidor MCP gratuitamente e começar a experimentar com Claude Code, Claude Desktop ou Cursor para interagir com a linha do tempo do seu editor.

Os recursos de IA generativa exigem login e assinatura.

**Quais plataformas são compatíveis?**

Requer macOS 26 (Tahoe) em Macs com Apple Silicon

Veja [FAQ.md](../../FAQ.md) para mais detalhes.

## Desenvolvimento

Veja [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Comunidade e suporte

- **Discord:** Entre na comunidade no **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Siga **[@Palmier_io](https://x.com/Palmier_io)** para atualizações e anúncios.
- **Instagram:** Siga [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback e suporte:** Crie uma [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) ou envie um email para founders@palmier.io.

## Star History

<a href="https://www.star-history.com/?repos=palmier-io%2Fpalmier-pro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <img alt="Gráfico Star History" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
 </picture>
</a>

## Licença

Copyright (C) 2026 Palmier, Inc.

Palmier Pro é open source sob a licença [GPLv3](../../LICENSE).
