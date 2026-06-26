> Bu çeviri yapay zeka tarafından oluşturulmuştur. Bir hata bulursanız PR açın.

<div align="center">

# Palmier Pro

**Yapay zeka için tasarlanmış video editörü.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Palmier Pro'yu macOS için indir" width="180" />
</a>

<sub><i>Apple Silicon üzerinde macOS 26 (Tahoe) gerektirir</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="X'te takip et" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Discord'a katıl" /></a>
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
  <a href="README.it.md">Italiano</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ru.md">Русский</a> ·
  <strong>Türkçe</strong>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Palmier Pro arayüzü" width="900" />

---

Palmier Pro, Mac için açık kaynaklı bir video editörüdür. Siz ve ajanınız, videoları zaman çizelgesi içinde birlikte üretip düzenleyebilirsiniz.

### Swift ile yazılmış yerel video editörü

Palmier Pro'yu sıfırdan Swift ile geliştirdik. Pusulamız Premiere Pro; yapay zekayı iş akışına entegre etmeye dair kendi yaklaşımımızla.

### Yerleşik üretken yapay zeka

Seedance, Kling ve Nano Banana Pro gibi en gelişmiş modellerle videoları ve görselleri doğrudan zaman çizelgesi editörü içinde üretin.

### Ajanlarınızla entegre olur

Claude, Codex veya Cursor'ı MCP üzerinden bağlayın ya da uygulama içi ajanı kullanarak aynı proje üzerinde birlikte çalışın.

## MCP sunucusu

Uygulama açıkken, HTTP üzerinden `http://127.0.0.1:19789/mcp` adresinde bir MCP sunucusu sunar. Bağlanmak için:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

En kolay yol, uygulama içinde `Help` -> `MCP Instructions` -> `Install in Cursor` adımlarını izlemektir; ya da `~/.cursor/mcp.json` dosyasına şunu ekleyerek elle kurabilirsiniz:

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

Uygulamayla birlikte, Claude Desktop üzerinde tek tıkla Desktop Extension kurulumu sağlayan bir [mcpb](https://github.com/modelcontextprotocol/mcpb) paketi sunuyoruz. `Help` -> `MCP Instructions` -> `Install in Claude Desktop` yolunu izleyin.

## SSS

**Palmier Pro tamamen açık kaynaklı mı?**

Video editörü (üretken yapay zeka özellikleri hariç) tamamen açık kaynaklıdır. MCP sunucusu ve ajan sohbeti de açık kaynaklıdır. Kapalı kaynak olan tek şey üretken yapay zeka işlemesidir.

**Ücretsiz mi?**

Editör ücretsizdir. Giriş yapmadan indirebilir ve CapCut ya da Adobe Premiere gibi bir video editörü olarak kullanabilirsiniz. MCP sunucusunu da ücretsiz kullanabilir; zaman çizelgesi editörünüzle etkileşmek için Claude Code/Desktop veya Cursor ile denemeler yapmaya başlayabilirsiniz.

Üretken yapay zeka özellikleri giriş ve abonelik gerektirir.

**Hangi platformları destekliyor?**

Yalnızca Apple Silicon üzerinde macOS 26 (Tahoe).

Daha fazlası için [FAQ.md](../../FAQ.md) dosyasına bakın.

## Geliştirme

[CONTRIBUTING.md](../../CONTRIBUTING.md) dosyasına bakın.

## Topluluk ve Destek

- **Discord:** Topluluğa **[Discord](https://discord.com/invite/SMVW6pKYmg)** üzerinden katılın.
- **Twitter / X:** Güncellemeler ve duyurular için **[@Palmier_io](https://x.com/Palmier_io)** hesabını takip edin.
- **Instagram:** [@palmier.io](https://www.instagram.com/palmier.io) hesabını takip edin.
- **Geri Bildirim ve Destek:** Bir [GitHub Issue](https://github.com/palmier-io/palmier-pro/issues) oluşturun ya da founders@palmier.io adresinden bize e-posta gönderin.

## Star History

<a href="https://www.star-history.com/?type=date&repos=palmier-io%2Fpalmier-pro">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
   <img alt="Star History Grafiği" src="https://api.star-history.com/chart?repos=palmier-io/palmier-pro&type=date&legend=top-left" />
 </picture>
</a>

## Lisans

Copyright (C) 2026 Palmier, Inc.

Palmier Pro, [GPLv3](../../LICENSE) lisansı altında açık kaynaklıdır.
