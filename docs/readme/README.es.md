> Esta traducción fue generada por IA. Si encuentras un error, abre un PR.

<div align="center">

# Palmier Pro

**El editor de video creado para IA.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Descargar Palmier Pro para macOS" width="180" />
</a>

<sub><i>Requiere macOS 26 (Tahoe) en Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="Seguir en X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Unirse a Discord" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">English</a> ·
  <strong>Español</strong> ·
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
  <a href="README.ru.md">Русский</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Interfaz de Palmier Pro" width="900" />

---

Palmier Pro es un editor de video de código abierto para Mac. Tú y tu agente pueden generar y editar videos juntos dentro de la línea de tiempo.

### Editor de video nativo en Swift

Construimos Palmier Pro desde cero con Swift. La referencia es Premiere Pro, con nuestra forma de integrar IA en el flujo de trabajo.

### IA generativa integrada

Genera videos e imágenes con modelos de vanguardia como Seedance, Kling y Nano Banana Pro dentro del editor de línea de tiempo.

### Integración con tus agentes

Conecta Claude, Codex o Cursor mediante MCP, o usa el agente integrado en la app para trabajar juntos en el mismo proyecto.

## Servidor MCP

Cuando la app está abierta, expone un servidor MCP en `http://127.0.0.1:19789/mcp` mediante HTTP. Para conectarlo:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

La forma más fácil es abrir `Help` -> `MCP Instructions` -> `Install in Cursor` dentro de la app, o instalarlo manualmente agregando esto a `~/.cursor/mcp.json`:

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

Incluimos un [mcpb](https://github.com/modelcontextprotocol/mcpb) con la app que permite instalar la extensión de escritorio en Claude Desktop con un clic. Abre `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**¿Palmier Pro es completamente de código abierto?**

El editor de video, sin las funciones de IA generativa, es completamente de código abierto. El servidor MCP y el chat del agente también son de código abierto. Lo único cerrado es el procesamiento de IA generativa.

**¿Es gratis?**

El editor es gratis. Puedes descargarlo sin iniciar sesión y usarlo como editor de video, como CapCut o Adobe Premiere. También puedes usar el servidor MCP gratis y empezar a experimentar con Claude Code, Claude Desktop o Cursor para interactuar con tu editor de línea de tiempo.

Las funciones de IA generativa requieren inicio de sesión y suscripción.

**¿Qué plataformas admite?**

Solo macOS 26 (Tahoe) en Apple Silicon.

Consulta [FAQ.md](../../FAQ.md) para más información.

## Desarrollo

Consulta [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Comunidad y soporte

- **Discord:** Únete a la comunidad en **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Sigue a **[@Palmier_io](https://x.com/Palmier_io)** para novedades y anuncios.
- **Instagram:** Sigue a [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback y soporte:** Crea un [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) o escríbenos a founders@palmier.io.

## Historial de estrellas

<a href="https://www.star-history.com/?repos=palmier-io%2Fpalmier-pro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
   <img alt="Gráfico del historial de estrellas" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left&sealed_token=noeYrwWrpHCjd3KdAoj1jK1SLWKED61qQxKmx0oIh1oFzShl6A_eSw-ABZEgU2tm7WymnOSjnRltpeY01CPYhh6TN2aBTS9gH9Op0wMbGe1YW2J10xzGfjOtSir7GL-Nm80Wt1TCZ3bqjICSdSPQCQosZOTax4zLC_wNXYWunWmKvtcclfTbvWTd08AF" />
 </picture>
</a>

## Licencia

Copyright (C) 2026 Palmier, Inc.

Palmier Pro es de código abierto bajo [GPLv3](../../LICENSE).
