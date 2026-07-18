# sls_example

App demo cho `sls_flutter`: ghi log, sync, xem file local, xem remote config.

Auto sync bật sẵn 30 giây — SDK cũng tự sync khi app vào background và tự lấy
`GET /config` lúc khởi động.

```bash
flutter run -d macos    # hoặc thiết bị bất kỳ
```

Mặc định trỏ về backend production `https://sls-upload-api.onrender.com` với
project seed sẵn `dev` / `dev-key`. Đổi 3 hằng số đầu
[lib/main.dart](lib/main.dart) để trỏ sang backend của bạn.

## Các nút

| Nút | Làm gì |
|---|---|
| **Log trade** | `SlsLogger.logTrade` — priority `high` |
| **Log event** | Ghi `'Screen Open'` (chữ hoa + khoảng trắng) để thấy SDK tự chuẩn hoá thành `event/app/screen_open`. Không chuẩn hoá thì server từ chối **cả batch** |
| **Log crash** | `SlsLogger.logCrash` — priority `critical` |
| **Sync now** | `syncAll()`, in số event server nhận và thời gian |
| **Xem file** | Liệt kê `logs/*` và nội dung `metadata/checkpoint.meta` |
| **Config** | Gọi `GET /config` và in cấu hình server trả về (batch size, chu kỳ sync, `enabled`, `key_version`) |

## Thử nghiệm đáng làm

**Offline-first**: tắt Wi-Fi → bấm Log trade vài lần → Sync now (báo lỗi) →
bật lại Wi-Fi → Sync now. Toàn bộ log ghi lúc offline vẫn lên đủ, không mất cái
nào.

**Checkpoint**: bấm Xem file sau mỗi lần sync — `offset` chỉ tiến sau khi server
xác nhận.

**Mã hoá**: đổi `_environment` sang `'production'` → file local thành `.blf`,
mở bằng editor không đọc được nội dung. Muốn upload ở chế độ này thì truyền
thêm `serverPublicKey` (README chính, mục 6).

**Remote config**: bấm Config để xem server đang chỉ định gì. Đổi bằng admin API
rồi bấm lại — có hiệu lực ngay, không cần build lại app:

```bash
curl -sX PATCH $SLS_URL/projects/dev/config \
  -H "x-admin-token: $ADMIN" -H 'content-type: application/json' \
  -d '{"batch_size":10,"sync_interval_seconds":60}'
```

**Van khoá từ xa**: đặt `{"enabled":false}` → app ngừng upload nhưng **vẫn ghi
log xuống đĩa**. Bật lại thì log tích trong lúc khoá gửi tiếp từ đúng
checkpoint, không mất cái nào.

**Cold start**: backend chạy Render free plan, ngủ sau 15 phút không request —
lần sync đầu có thể mất 30–50s. Giới hạn của hosting, không phải của SDK.

## macOS

`macos/Runner/{DebugProfile,Release}.entitlements` đã bật
`com.apple.security.network.client`. Thiếu quyền này thì sandbox chặn kết nối mà
**không báo lỗi gì** — log vẫn ghi local nên rất dễ tưởng SDK hỏng.
