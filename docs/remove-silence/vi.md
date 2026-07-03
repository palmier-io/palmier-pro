> Bản dịch này được tạo bởi AI. Nếu bạn thấy lỗi, hãy mở PR.

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <a href="es.md">Español</a> ·
  <a href="zh-CN.md">简体中文</a> ·
  <a href="zh-TW.md">繁體中文</a> ·
  <a href="ja.md">日本語</a> ·
  <a href="ko.md">한국어</a> ·
  <strong>Tiếng Việt</strong> ·
  <a href="hi.md">हिन्दी</a> ·
  <a href="bn.md">বাংলা</a> ·
  <a href="ar.md">العربية</a> ·
  <a href="it.md">Italiano</a> ·
  <a href="pt-BR.md">Português (Brasil)</a> ·
  <a href="fr.md">Français</a> ·
  <a href="ru.md">Русский</a>
</p>

# Xóa Khoảng Lặng

Tự động phát hiện và xóa các vùng lặng trong một clip. Quá trình phát hiện chạy hoàn toàn trên thiết bị từ dạng sóng âm thanh của clip — không cần kết nối internet hoặc bản ghi.

## Máy tính để bàn

### 1. Chọn một clip
Nhấp vào bất kỳ **clip video hoặc âm thanh** nào trên timeline. Nút Xóa Khoảng Lặng chỉ hoạt động khi một clip đơn (hoặc một cặp âm thanh/video được liên kết) được chọn.

### 2. Mở bảng điều khiển
Nhấp vào **biểu tượng sóng âm dấu trừ** (`waveform.badge.minus`) trên thanh công cụ, hoặc chọn **Edit → Remove Silence**. Bảng điều khiển mở ra và ngay lập tức bắt đầu phát hiện các khoảng lặng bằng cài đặt hiện tại.

### 3. Điều chỉnh các tham số

| Tham số | Mặc định | Mô tả |
|---------|----------|--------|
| **Threshold** | −35 dB | Ngưỡng âm lượng tối thiểu mà âm thanh dưới mức này được coi là lặng. Tăng về phía 0 dB (ví dụ: −25 dB) để bắt các khoảng dừng nhỏ hơn; giảm (ví dụ: −45 dB) để chỉ xóa các khoảng gần hoàn toàn im lặng. |
| **Min duration** | 0.5 s | Khoảng lặng ngắn nhất sẽ bị xóa. Tăng giá trị này để giữ lại hơi thở tự nhiên và khoảng dừng ngắn; giảm để cắt cả những khoảng ngắn. |
| **Edge padding** | 0.05 s | Lượng âm thanh được giữ lại ở mỗi bên của khoảng lặng được phát hiện, để lời nói và ghi chú không bị cắt. Tăng nếu các từ đang bị cắt đứt. |

Sau khi thay đổi bất kỳ tham số nào, nhấp **Detect** để chạy lại phát hiện với các giá trị mới. Bảng điều khiển hiển thị số lượng khoảng lặng được tìm thấy.

### 4. Áp dụng
Nhấp **Remove Silences**. Các vùng lặng được xóa theo kiểu ripple — các clip khép lại và mọi thứ phía sau dịch sang trái để lấp đầy khoảng trống. Chỉnh sửa là một hành động có thể hoàn tác duy nhất: nhấn **⌘Z** để khôi phục bản gốc.

## Clip âm thanh/video được liên kết
Khi một clip video và âm thanh của nó được liên kết (biểu tượng chuỗi đóng trên cả hai track), việc chọn một trong hai clip sẽ chọn cả cặp. Xóa Khoảng Lặng đọc dạng sóng âm thanh để phát hiện và cắt **cả hai track** tại chính xác các frame giống nhau, giữ âm thanh và video đồng bộ.

## Tác nhân AI (MCP)
Khi Palmier Pro đang chạy, nó hiển thị một máy chủ MCP tại `http://127.0.0.1:19789/mcp`. Bất kỳ tác nhân được kết nối nào (Claude, Codex, Cursor, v.v.) đều có thể xóa khoảng lặng bằng công cụ `remove_silence`.

### Ngôn ngữ tự nhiên
```
Remove the silences from the first clip
Cut all the dead air
Tighten the pauses — use a threshold of -30 dB
Remove silence, minimum gap 1 second
```

### Công cụ: `remove_silence`
```json
{"name":"remove_silence","arguments":{"clipId":"<id from get_timeline>","thresholdDb":-35,"minSilenceDuration":0.5,"edgePadding":0.05}}
```

#### Tham số
| Tham số | Kiểu | Mặc định | Mô tả |
|---------|------|----------|--------|
| `clipId` | string | **bắt buộc** | ID clip từ `get_timeline`. Phải là clip âm thanh hoặc clip video có âm thanh. |
| `thresholdDb` | number | `−35` | Ngưỡng âm lượng tính bằng dBFS (phải ≤ 0). Âm thanh nhỏ hơn mức này được coi là lặng. |
| `minSilenceDuration` | number | `0.5` | Độ dài khoảng lặng tối thiểu tính bằng giây để xóa. |
| `edgePadding` | number | `0.05` | Số giây âm thanh được giữ lại ở mỗi bên của khoảng lặng được phát hiện. |

#### Phản hồi
```json
{"removedSilences":12,"removedFrames":1440,"thresholdDb":-35,"note":"Removed silent regions and closed the gaps."}
```

#### Quy trình làm việc
```
1. get_timeline → find clip ID
2. remove_silence → detect and remove
3. get_transcript → verify (optional)
4. undo → revert if needed
```

## Mẹo
- **Không có gì bị xóa?** Giảm ngưỡng (ví dụ: −30 dB) hoặc giảm Min duration.
- **Lời nói bị cắt?** Tăng Edge padding (ví dụ: 0.1 s).
- **Quá nhiều điểm cắt?** Tăng Min duration (ví dụ: 1.0 s).
- **Clip được liên kết mất đồng bộ sau khi hủy liên kết?** Luôn chạy Xóa Khoảng Lặng khi các clip đang được liên kết.
