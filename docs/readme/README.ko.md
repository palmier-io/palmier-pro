> 이 번역은 AI로 생성되었습니다. 오류를 발견하면 PR을 열어 주세요.

<div align="center">

# Palmier Pro

**AI를 위한 비디오 편집기.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="macOS용 Palmier Pro 다운로드" width="180" />
</a>

<sub><i>Apple Silicon 기반 macOS 26 (Tahoe) 필요</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="X에서 팔로우" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Discord 참여" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>
<br />

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <strong>한국어</strong> ·
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

<img src="../../assets/palmier-ui.png" alt="Palmier Pro UI" width="900" />

---

> [!IMPORTANT]
> v0.7.6까지의 Palmier Pro 릴리스는 GPLv3로 공개되었습니다. 마지막 공개 소스 스냅샷은 [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source)입니다. v0.7.6 이후 릴리스는 독점 소프트웨어이며 소스 코드는 이곳에 공개되지 않습니다.

Palmier Pro는 Mac용 비디오 편집기입니다. 사용자와 agent가 타임라인 안에서 함께 비디오를 생성하고 편집할 수 있습니다.

### Swift 네이티브 비디오 편집기

Palmier Pro는 Swift로 처음부터 만들었습니다. Premiere Pro를 모티브로 했으며, AI를 워크플로에 통합하는 Palmier Pro만의 방식을 적용했습니다.

### 내장 생성형 AI

타임라인 편집기 안에서 Seedance, Kling, Nano Banana Pro 같은 최신 모델로 비디오와 이미지를 생성할 수 있습니다.

### agent와 통합

MCP로 Claude, Codex, Cursor를 연결하거나, 앱 안의 agent를 사용해 같은 프로젝트에서 함께 작업할 수 있습니다.

## MCP 서버

앱이 열려 있으면 HTTP를 통해 `http://127.0.0.1:19789/mcp`에서 MCP 서버를 제공합니다. 연결 방법:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

가장 쉬운 방법은 앱 안에서 `Help` -> `MCP Instructions` -> `Install in Cursor`를 선택하는 것입니다. 수동으로 설치하려면 `~/.cursor/mcp.json`에 다음을 추가하세요.

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

앱에는 Claude Desktop에 Desktop Extension을 한 번에 설치할 수 있는 [mcpb](https://github.com/modelcontextprotocol/mcpb)가 포함되어 있습니다. `Help` -> `MCP Instructions` -> `Install in Claude Desktop`을 선택하세요.

## FAQ

**어떤 Palmier Pro 버전이 오픈 소스인가요?**

v0.7.6까지의 릴리스와 [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source)까지의 소스 코드는 GPLv3로 유지되며, 이후 릴리스는 독점 소프트웨어입니다.

**무료인가요?**

편집기는 무료입니다. 로그인 없이 다운로드할 수 있으며 CapCut이나 Adobe Premiere 같은 비디오 편집기로 사용할 수 있습니다. MCP 서버도 무료로 사용할 수 있고, Claude Code, Claude Desktop, Cursor를 타임라인 편집기와 연동할 수 있습니다.

생성형 AI 기능은 로그인과 구독이 필요합니다.

**어떤 플랫폼을 지원하나요?**

Apple Silicon 기반 macOS 26 (Tahoe)만 지원합니다.

## 기여

이 저장소는 더 이상 코드 기여를 받지 않습니다. 공개된 소스 코드는 GPLv3에 따라 계속 사용, 수정 및 재배포할 수 있습니다.

## 커뮤니티 및 지원

- **Discord:** **[Discord](https://discord.com/invite/SMVW6pKYmg)**에서 커뮤니티에 참여하세요.
- **Twitter / X:** 업데이트와 공지는 **[@Palmier_io](https://x.com/Palmier_io)**를 팔로우하세요.
- **Instagram:** [@palmier.io](https://www.instagram.com/palmier.io)를 팔로우하세요.
- **피드백 및 지원:** founders@palmier.io로 이메일을 보내세요.

## 라이선스

Copyright (C) 2026 Palmier, Inc.

이 저장소에 공개된 소스 코드는 [GPLv3](../../LICENSE)에 따라 유지됩니다. v0.7.6 이후의 바이너리 릴리스는 [BINARY_LICENSE.md](../../BINARY_LICENSE.md)에 따른 독점 소프트웨어입니다.
