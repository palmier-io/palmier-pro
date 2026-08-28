> Bản dịch này được tạo bằng AI. Nếu phát hiện lỗi, hãy mở PR.

<div align="center">

# Palmier Pro

**Trình biên tập video được xây dựng cho AI.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="../../assets/macos-badge.png" alt="Tải Palmier Pro cho macOS" width="180" />
</a>

<sub><i>Yêu cầu macOS 26 (Tahoe) trên Apple Silicon</i></sub>

<a href="https://x.com/Palmier_io"><img src="https://img.shields.io/badge/Follow-%40Palmier__io-000000?style=flat&logo=x&logoColor=white" alt="Theo dõi trên X" /></a>
<a href="https://discord.com/invite/SMVW6pKYmg"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=flat&logo=discord&logoColor=white" alt="Tham gia Discord" /></a>
<a href="https://www.ycombinator.com/companies/palmier"><img src="https://img.shields.io/badge/Y%20Combinator-S24-orange" alt="Y Combinator S24" /></a>
<br />

<p>
  <a href="../../README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <strong>Tiếng Việt</strong> ·
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

<img src="../../assets/palmier-ui.png" alt="Giao diện Palmier Pro" width="900" />

---

> [!IMPORTANT]
> Các bản phát hành Palmier Pro đến hết v0.7.6 được phát hành theo GPLv3. Ảnh chụp mã nguồn công khai cuối cùng là [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source). Các bản phát hành sau v0.7.6 là phần mềm độc quyền và mã nguồn của chúng không được công bố tại đây.

Palmier Pro là trình biên tập video cho Mac. Bạn và agent của bạn có thể cùng tạo và chỉnh sửa video ngay trong timeline.

### Trình biên tập video thuần Swift

Chúng tôi xây dựng Palmier Pro từ đầu bằng Swift. Mốc tham chiếu là Premiere Pro, với cách riêng của chúng tôi để tích hợp AI vào quy trình làm việc.

### AI tạo sinh tích hợp sẵn

Tạo video và hình ảnh bằng các mô hình tiên tiến như Seedance, Kling và Nano Banana Pro ngay trong trình biên tập timeline.

### Tích hợp với agent của bạn

Kết nối Claude, Codex hoặc Cursor qua MCP, hoặc dùng agent trong app để cùng làm việc trên một dự án.

## MCP server

Khi app đang mở, Palmier Pro cung cấp MCP server tại `http://127.0.0.1:19789/mcp` qua HTTP. Cách kết nối:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

Cách dễ nhất là mở `Help` -> `MCP Instructions` -> `Install in Cursor` trong app, hoặc cài thủ công bằng cách thêm phần sau vào `~/.cursor/mcp.json`:

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

Chúng tôi đóng gói một [mcpb](https://github.com/modelcontextprotocol/mcpb) cùng app để cài Desktop Extension trên Claude Desktop bằng một cú nhấp. Mở `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**Những phiên bản Palmier Pro nào là mã nguồn mở?**

Các bản phát hành đến hết v0.7.6 và mã nguồn đến [`last-gpl-source`](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source) vẫn theo GPLv3; các bản phát hành sau đó là phần mềm độc quyền.

**Có miễn phí không?**

Trình biên tập miễn phí. Bạn có thể tải xuống mà không cần đăng nhập và dùng như một trình biên tập video, tương tự CapCut hoặc Adobe Premiere. Bạn cũng có thể dùng MCP server miễn phí và bắt đầu thử nghiệm với Claude Code, Claude Desktop hoặc Cursor để tương tác với trình biên tập timeline.

Các tính năng AI tạo sinh yêu cầu đăng nhập và gói đăng ký.

**Hỗ trợ nền tảng nào?**

Chỉ hỗ trợ macOS 26 (Tahoe) trên Apple Silicon.

## Đóng góp

Kho lưu trữ này không còn nhận các đóng góp mã nguồn. Mã nguồn đã công bố vẫn có thể được sử dụng, sửa đổi và phân phối lại theo GPLv3.

## Cộng đồng và hỗ trợ

- **Discord:** Tham gia cộng đồng trên **[Discord](https://discord.com/invite/SMVW6pKYmg)**.
- **Twitter / X:** Theo dõi **[@Palmier_io](https://x.com/Palmier_io)** để nhận cập nhật và thông báo.
- **Instagram:** Theo dõi [@palmier.io](https://www.instagram.com/palmier.io).
- **Phản hồi và hỗ trợ:** Gửi email tới founders@palmier.io.

## Giấy phép

Copyright (C) 2026 Palmier, Inc.

Mã nguồn được công bố trong kho lưu trữ này vẫn theo [GPLv3](../../LICENSE). Các bản phát hành nhị phân sau v0.7.6 là phần mềm độc quyền theo [BINARY_LICENSE.md](../../BINARY_LICENSE.md).
