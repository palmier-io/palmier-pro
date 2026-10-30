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
<br />

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

> [!IMPORTANT]
> Las versiones de Palmier Pro hasta la v0.7.6 inclusive se publicaron bajo GPLv3. La última instantánea pública del código fuente es [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source). Las versiones posteriores a la v0.7.6 son propietarias y su código fuente no se publica aquí.

Palmier Pro es un editor de video para Mac. Tú y tu agente pueden generar y editar videos juntos dentro de la línea de tiempo.

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

**¿Qué versiones de Palmier Pro son de código abierto?**

Las versiones hasta la v0.7.6 inclusive y el código fuente hasta [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source) siguen bajo GPLv3; las versiones posteriores son propietarias.

**¿Es gratis?**

El editor es gratis. Puedes descargarlo sin iniciar sesión y usarlo como editor de video, como CapCut o Adobe Premiere. También puedes usar el servidor MCP gratis y empezar a experimentar con Claude Code, Claude Desktop o Cursor para interactuar con tu editor de línea de tiempo.

Las funciones de IA generativa requieren inicio de sesión y suscripción.

**¿Qué plataformas admite?**

Solo macOS 26 (Tahoe) en Apple Silicon.

## Contribuciones

Este repositorio ya no acepta contribuciones de código. El código fuente publicado sigue disponible para su uso, modificación y redistribución bajo GPLv3.

## Comunidad y soporte

- **Discord:** Únete a la comunidad en **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Sigue a **[@Palmier_io](https://x.com/Palmier_io)** para novedades y anuncios.
- **Instagram:** Sigue a [@palmier.io](https://www.instagram.com/palmier.io).
- **Feedback y soporte:** Escríbenos a founders@palmier.io.

## Licencia

Copyright (C) 2026 Palmier, Inc.

El código fuente publicado en este repositorio permanece bajo [GPLv3](../../LICENSE). Las versiones binarias posteriores a la v0.7.6 son propietarias bajo [BINARY_LICENSE.md](../../BINARY_LICENSE.md).
