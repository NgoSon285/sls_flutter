## 0.1.0

Bản đầu tiên của SDK Dart thuần.

- Không cần toolchain native: `flutter pub get` là chạy được. Hỗ trợ cả Web.
- Storage: JSONL (development) / BLF + AES-256-GCM (staging, production),
  rotate theo ngày + 64MB, checkpoint `{file, offset}`, retention 7 ngày,
  FIFO 512MB, crash recovery cắt record ghi dở.
- Sync: batch 100 event, backoff 5→10→20→40→60s, cô lập event bị server từ
  chối vĩnh viễn (400/413/422), giữ log khi lỗi auth.
- Upload: plain hoặc hybrid encryption (AES-256-GCM + RSA-OAEP-SHA256).
- 24 test: unit + e2e chạy HTTP thật qua loopback.
