# sls_flutter

SDK ghi log **offline-first** cho Flutter. Dart thuần — không cần Rust, không
toolchain native, không bước build riêng cho từng platform.

Mọi event ghi xuống file local trước (append-only, không bao giờ mất — kể cả khi
mất mạng, app crash hay server sập), sau đó đồng bộ lên server theo batch. Upload
idempotent: gửi lại không tạo dữ liệu trùng.

Hỗ trợ: Android, iOS, macOS, Linux, Windows, Web.

---

## 1. Yêu cầu

| Thành phần | Yêu cầu |
|---|---|
| Flutter | >= 3.3 (Dart >= 3.5) |
| Backend | SLS Upload API đang chạy |
| Thông tin cấp cho app | `endpoint`, `projectId`, `apiKey` |

> `projectId` + `apiKey` do bên vận hành SLS cấp. Không có key hợp lệ thì server
> trả 401 — SDK là mã nguồn mở nhưng dữ liệu thì không.

## 2. Cài đặt

```yaml
dependencies:
  sls_flutter:
    git:
      url: https://github.com/NgoSon285/sls-flutter.git
  path_provider: ^2.1.0   # để lấy thư mục lưu log
```

Không có bước cấu hình native nào.

### macOS: bật quyền truy cập mạng

App macOS chạy trong sandbox và **mặc định bị chặn kết nối ra ngoài** — thiếu
quyền này thì `syncAll()` lỗi mạng im lặng (log vẫn ghi local bình thường). Thêm
vào **cả hai** file `macos/Runner/DebugProfile.entitlements` và
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

iOS không cần bước này.

### Android: quyền INTERNET cho bản release

Flutter chỉ thêm `INTERNET` vào manifest **debug/profile**. Bản **release**
thiếu quyền này thì mọi lần sync đều thất bại (log vẫn ghi local, nên rất dễ
lọt tới tay người dùng thật mới phát hiện). Thêm vào
`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

## 3. Khởi tạo

```dart
import 'package:path_provider/path_provider.dart';
import 'package:sls_flutter/sls_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await getApplicationSupportDirectory();
  await SlsLogger.init(
    dir: '${dir.path}/sls',                          // thư mục lưu log local
    endpoint: 'https://sls-upload-api.onrender.com',
    projectId: 'your-project',
    apiKey: '...',
    deviceId: 'unique-device-id',
    environment: 'production',                       // development | staging | production
    serverPublicKey: pem,                            // bật mã hoá đầu-cuối (mục 6)
    autoSyncInterval: const Duration(seconds: 30),   // tự sync định kỳ + khi vào background
  );

  runApp(const MyApp());
}
```

Mỗi lần `init` tạo một **session** mới; mọi event trong phiên mang cùng
`session_id` (đọc qua `SlsLogger.sessionId`). Gọi `init` lại là an toàn — hot
restart không gây lỗi.

## 4. Ghi log

Ghi log là **synchronous** — chỉ ghi xuống đĩa, không chạm network, gọi được ở
bất cứ đâu kể cả trong build/tap handler:

```dart
SlsLogger.logTrade({
  'trade_id': 'T-1001', 'symbol': 'EURUSD', 'side': 'BUY',
  'volume': 1, 'price': 1.1200,
});

SlsLogger.logEvent('screen_open', {'screen': 'Home'});

try {
  riskyOperation();
} catch (e, st) {
  SlsLogger.logCrash({'exception': e.toString(), 'stacktrace': st.toString()});
}

// event_type tuỳ ý theo <namespace>/<category>/<name>
SlsLogger.log(
  'trade/order/closed',
  {'trade_id': 'T-1001', 'profit': 25.5},
  priority: SlsPriority.high,
);
```

`event_type` được tự chuẩn hoá về `[a-z0-9_-]` (vd `'App Start'` →
`'app_start'`) vì server validate cả batch — một event sai định dạng sẽ làm
server từ chối **toàn bộ** batch.

**Gắn user để tra log về sau:**

```dart
SlsLogger.setUser('u-123');   // lúc đăng nhập
SlsLogger.setUser(null);      // lúc đăng xuất
```

`user_id` được gắn vào mọi event ghi **sau** lời gọi đó. Log ghi trước khi đăng
nhập không bị gán hồi tố — storage là append-only, và đó cũng là sự thật: lúc
ấy chưa biết ai đang dùng.

**Bắt crash toàn app** (khuyến nghị):

```dart
FlutterError.onError = (details) {
  SlsLogger.logCrash({
    'exception': details.exception.toString(),
    'stacktrace': details.stack.toString(),
  });
};
```

## 5. Đồng bộ lên server

Đơn giản nhất là bật `autoSyncInterval` khi init: SDK tự sync định kỳ **và** mỗi
khi app vào background, lỗi mạng nuốt im lặng. Tắt bằng `SlsLogger.stopAutoSync()`.

Hoặc tự điều khiển: `final uploaded = await SlsLogger.syncAll();`

- Gom batch 100 event/request, upload tuần tự đến khi hết.
- Lỗi mạng/5xx → retry backoff 5s → 10s → 20s → 40s → 60s rồi ném exception.
  Log **vẫn an toàn trên đĩa**; lần sau gửi tiếp từ đúng chỗ dừng (checkpoint
  chỉ tiến sau khi server xác nhận).
- 401/403 → ném ngay, không retry, **không bỏ log**.
- 400/413/422 → batch bị từ chối vĩnh viễn: gửi lại từng event một để chỉ bỏ
  đúng event hỏng. Hàng đợi không bao giờ kẹt.

> Backoff có thể mất tới ~135s khi hoàn toàn offline — đừng `await syncAll()`
> trên đường UI, dùng `autoSyncInterval` hoặc bọc `.timeout()`.

App crash hay bị kill? Log đã nằm trên đĩa, lần mở app tiếp theo `init` tự sync
những gì còn tồn.

## 6. Lưu trữ và mã hoá

| `environment` | File local | Upload |
|---|---|---|
| `development` | JSONL plain — đọc bằng mắt được | plain (`logs[]`) |
| `staging` / `production` | BLF, payload mã hoá AES-256-GCM | hybrid encryption nếu có `serverPublicKey` |

- **BLF** (Binary Log Format): header 26 byte, magic + version + CRC32. Record
  ghi dở do crash/mất điện bị cắt bỏ khi mở lại, các record trước nguyên vẹn.
- **Khoá local** derive từ `apiKey` bằng SHA-256.
- **Hybrid encryption**: session key AES-256 ngẫu nhiên mỗi batch, wrap bằng
  RSA-OAEP(SHA-256) với public key PEM của server.
- **Rotate & dọn dẹp**: file mới theo ngày và theo dung lượng (64MB), giữ 7
  ngày, trần 512MB. **Chỉ file đã sync xong mới bị xoá.**

## 7. Xử lý sự cố

| Hiện tượng | Nguyên nhân / cách xử lý |
|---|---|
| `syncAll()` lỗi 401/403 | Sai `projectId`/`apiKey` — SDK không retry lỗi auth |
| `syncAll()` lỗi mạng | Bình thường với offline-first: log vẫn ở local, gọi lại sau |
| **macOS**: `syncAll()` luôn lỗi mạng | Thiếu entitlement `com.apple.security.network.client` — xem mục 2 |
| Lần sync đầu chậm ~30-50s | Backend trên Render free plan ngủ sau 15 phút, request đầu chờ cold start |
| Gọi `log()` không thấy gì | Chưa gọi `SlsLogger.init()` — SDK bỏ qua im lặng |
| Muốn xem log local | Thư mục `dir`: `logs/events-*.jsonl` (development) hoặc `logs/events-*.blf`, và `metadata/checkpoint.meta` |

## 8. Phát triển

```bash
flutter test      # 24 test: unit + e2e chạy HTTP thật qua loopback
flutter analyze
```

`lib/src`: `blf.dart` (định dạng file), `crypto.dart` (AES-GCM + RSA-OAEP),
`storage.dart` (rotate/checkpoint/retention), `logger.dart` (batch, backoff,
upload). Đặc tả: `docs/` trong repo backend.

## Giấy phép

MIT — xem [LICENSE](LICENSE).
