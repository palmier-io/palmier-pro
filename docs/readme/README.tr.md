> Bu çeviri yapay zeka ile oluşturulmuş ve bir insan tarafından gözden geçirilip düzenlenmiştir. Bir hata tespit ederseniz katkıda bulunmak için lütfen bir PR (Pull Request) açın.

<div align="center">

# Palmier Pro

**Yapay zeka için tasarlanmış video editörü.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Palmier Pro'yu macOS için indir" width="180" />
</a>

<sub><i>Apple Silicon işlemcili cihazlarda macOS 26 (Tahoe) sürümü gerektirir</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Takip Et-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="X'te takip et" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Katıl -Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Discord'a katıl" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>

<p>
  <a href="../../README.md">İngilizce</a> ·
  <a href="README.es.md">İspanyolca</a> ·
  <a href="README.zh-CN.md">Çince (Basitleştirilmiş)</a> ·
  <a href="README.zh-TW.md">Çince (Geleneksel)</a> ·
  <a href="README.ja.md">Japonca</a> ·
  <a href="README.ko.md">Korece</a> ·
  <a href="README.vi.md">Vietnamca</a> ·
  <a href="README.hi.md">Hintçe</a> ·
  <a href="README.bn.md">Bengalca</a> ·
  <a href="README.ar.md">Arapça</a> ·
  <a href="README.it.md">İtalyanca</a> ·
  <a href="README.pt-BR.md">Portekizce (Brezilya)</a> ·
  <a href="README.fr.md">Fransızca</a> ·
  <a href="README.ru.md">Rusça</a> ·
  <strong>Türkçe</strong>
</p>

</div>

<img src="../../assets/palmier-ui.png" alt="Palmier Pro arayüzü" width="900" />

---

Palmier Pro, Mac için açık kaynaklı bir video editörüdür. Siz ve yapay zeka ajanınız, zaman çizelgesi (timeline) üzerinde videoları birlikte üretebilir ve düzenleyebilirsiniz.

### Swift ile yerel (native) geliştirilmiş video editörü

Palmier Pro'yu sıfırdan Swift ile geliştirdik. Kutup yıldızımız (temel hedefimiz) Premiere Pro olsa da, yapay zekayı iş akışına entegre etme konusunda kendimize özgü bir yaklaşım benimsiyoruz.

### Yerleşik Üretken Yapay Zeka

Seedance, Kling ve Nano Banana Pro gibi son teknoloji (SOTA) modellerle videoları ve görselleri doğrudan zaman çizelgesi editörü içinde üretin.

### Yapay Zeka Ajanlarınızla Entegre Olur

Claude, Codex veya Cursor'ınızı MCP üzerinden bağlayın veya aynı proje üzerinde birlikte çalışmak için uygulama içi yapay zeka ajanını kullanın.

## MCP Sunucusu

Uygulama açık olduğunda, HTTP protokolü üzerinden `http://127.0.0.1:19789/mcp` adresinde bir MCP sunucusu yayınlar. Bağlanmak için:

**Claude Code**

```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**

```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

En kolay yol, uygulama içinden `Help` -> `MCP Instructions` -> `Install in Cursor` adımlarını takip etmek veya `~/.cursor/mcp.json` dosyasına aşağıdakileri ekleyerek manuel olarak kurmaktır:

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

Claude Desktop üzerinde tek tıkla Masaüstü Eklentisi (Desktop Extension) kurulumu yapabilmeniz için uygulama ile birlikte bir [mcpb](https://github.com/modelcontextprotocol/mcpb) paketi sunuyoruz. Uygulama içerisinden `Help` -> `MCP Instructions` -> `Install in Claude Desktop` yolunu takip edin.

## Sıkça Sorulan Sorular (SSS)

**Palmier Pro tamamen açık kaynaklı mı?**

Video editörü (üretken yapay zeka özellikleri hariç) tamamen açık kaynaklıdır. MCP sunucusu ve ajan sohbeti de açık kaynaklıdır. Kapalı kaynaklı olan tek kısım, üretken yapay zeka işlemleridir.

**Ücretsiz mi?**

Editör ücretsizdir. Herhangi bir giriş (login) gerektirmeden indirebilir ve CapCut veya Adobe Premiere gibi bir video editörü olarak kullanabilirsiniz. MCP sunucusunu da ücretsiz olarak kullanabilir; Claude Code, Claude Desktop veya Cursor aracılığıyla zaman çizelgesi editörünüzle etkileşime geçmek için denemeler yapmaya başlayabilirsiniz.

Üretken yapay zeka özellikleri giriş yapmayı ve abonelik almayı gerektirir.

**Hangi platformları destekliyor?**

Yalnızca Apple Silicon işlemcili ve macOS 26 (Tahoe) işletim sistemli cihazlarda çalışır.

Daha fazlası için [FAQ.md](../../FAQ.md) dosyasına bakın.

## Geliştirme

[CONTRIBUTING.md](../../CONTRIBUTING.md) dosyasına bakın.

## Topluluk & Destek

- **Discord:** Topluluğa **[Discord](https://discord.com/invite/SMVW6pKYmg)** üzerinden katılın.
- **Twitter / X:** Güncellemeler ve duyurular için **[@Palmier_io](https://x.com/Palmier_io)** hesabını takip edin.
- **Instagram:** [@palmier.io](https://www.instagram.com/palmier.io) adresinden takip edin.
- **Geri Bildirim & Destek:** Bir [GitHub Sorunu (Issue)](https://github.com/palmier-io/palmier-pro/issues) oluşturun veya founders@palmier.io adresine e-posta gönderin.

## Yıldız Geçmişi

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
