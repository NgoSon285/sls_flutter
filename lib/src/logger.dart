import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'crypto.dart' as crypto;
import 'storage.dart';

const sdkVersion = '0.1.0';
const protocolVersion = '1.0';

const _batchSize0 = 100; // mặc định, remote config ghi đè được
// Exponential backoff theo Functional Spec §13
const _backoffSecs = [5, 10, 20, 40, 60];

const _uuid = Uuid();

class Config {
  Config({
    required this.dir,
    required this.endpoint,
    required this.projectId,
    required this.apiKey,
    required this.deviceId,
    this.environment = 'production',
    this.serverPublicKey,
  });

  final String dir;
  final String endpoint;
  final String projectId;
  final String apiKey;
  final String deviceId;
  final String environment;

  /// PEM public key của server — bật hybrid encryption khi upload (staging/production).
  final String? serverPublicKey;
}

/// Ghi local trước, network chỉ là đồng bộ (Functional Spec §2).
class Logger {
  Logger(this.config)
      : sessionId = _uuid.v7(),
        _storage = Storage.open(
          config.dir,
          // Storage Spec §5: development = JSONL plain, còn lại = BLF mã hoá
          jsonl: config.environment == 'development',
          key: config.environment == 'development'
              ? null
              : crypto.deriveKey(config.apiKey),
        );

  final Config config;
  final String sessionId;
  final Storage _storage;

  // sequence không reset trong một session (Storage Spec §8)
  int _sequence = 1;

  // Remote config, ghi đè bởi GET /config nếu gọi được.
  int _batchSize = _batchSize0;
  bool _enabled = true;
  Duration? syncInterval;

  /// Gắn vào mọi event sau đó. Null (mặc định) thì không gửi field `user_id`.
  String? userId;

  /// Cấu hình server trả về ở lần [refreshConfig] gần nhất. Rỗng nếu chưa gọi
  /// được — dùng để hiển thị/chẩn đoán, logic đọc các field riêng ở trên.
  Map<String, dynamic> remoteConfig = const {};

  /// Lấy cấu hình runtime từ server. Best-effort: hỏng thì giữ mặc định —
  /// mất mạng không được phép làm SDK ngừng ghi log.
  Future<void> refreshConfig() async {
    try {
      final resp = await http.get(
        Uri.parse('${config.endpoint}/config'),
        headers: {
          'x-project-id': config.projectId,
          'x-api-key': config.apiKey,
          'x-device-id': config.deviceId,
        },
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final c = jsonDecode(resp.body) as Map<String, dynamic>;
      remoteConfig = c;
      _batchSize = (c['batch_size'] as int?)?.clamp(1, 1000) ?? _batchSize;
      _enabled = c['enabled'] as bool? ?? _enabled;
      final secs = c['sync_interval_seconds'] as int?;
      if (secs != null) syncInterval = Duration(seconds: secs);
    } catch (_) {
      // giữ nguyên cấu hình hiện tại
    }
  }

  void log(String eventType, String priority, Map<String, dynamic> payload) {
    _storage.append({
      'event_id': _uuid.v7(),
      'event_type': normalizeEventType(eventType),
      'schema_version': '1.0.0',
      'timestamp': _nowRfc3339(),
      'sequence': _sequence++,
      'priority': priority,
      'environment': config.environment,
      'sdk_version': sdkVersion,
      'plugin_name': 'core',
      'plugin_version': sdkVersion,
      'platform': Platform.operatingSystem,
      // Optional (Event Model §5): chỉ gửi khi có, để server không phải lưu NULL
      // và index partial trên user_id không phình.
      if (userId != null) 'user_id': userId,
      'payload': payload,
    });
  }

  /// Đồng bộ đến khi hết log. Trả về số event server đã nhận.
  Future<int> syncAll() async {
    // enabled=false: van khoá từ xa khi một app spam. Log vẫn ghi local, chỉ
    // ngừng upload — bật lại là gửi tiếp từ đúng checkpoint.
    if (!_enabled) return 0;
    var total = 0;
    var retries = 0;
    while (true) {
      try {
        final n = await _syncOnce(_batchSize);
        if (n == 0) return total;
        total += n;
        retries = 0;
      } on _HttpStatus catch (e) {
        // 400/413/422: batch bị từ chối vĩnh viễn (Protocol Spec §11) — gửi lại
        // từng event để chỉ bỏ event hỏng, phần còn lại vẫn đi.
        if (e.isPoison) {
          final n = await _drainOne();
          if (n == null) return total;
          total += n;
          retries = 0;
          continue;
        }
        // 401/403 không retry và không bỏ log — sửa key xong sync lại là gửi được.
        // 5xx, 429 (rate limit), 408 là lỗi tạm → rơi xuống backoff.
        if (e.code < 500 && !e.isTransient) rethrow;
        if (retries >= _backoffSecs.length) rethrow;
        await Future<void>.delayed(Duration(seconds: _backoffSecs[retries++]));
      } catch (e) {
        if (retries >= _backoffSecs.length) rethrow;
        await Future<void>.delayed(Duration(seconds: _backoffSecs[retries++]));
      }
    }
  }

  Future<int> _syncOnce(int max) async {
    final batch = _storage.readBatch(max);
    if (batch == null) return 0;
    final (events, cp) = batch;
    await _upload(events);
    _storage.saveCheckpoint(cp);
    return events.length;
  }

  /// null = hết log, 1 = gửi được, 0 = phải bỏ event hỏng.
  ///
  /// ponytail: bỏ đúng event server không bao giờ nhận — mất 1 event, đổi lại
  /// hàng đợi không kẹt vĩnh viễn. Ceiling: nếu server đổi contract ở mức batch
  /// (vd chặn protocol_version) thì mọi event đều 400 và sẽ bị bỏ dần. Muốn an
  /// toàn hơn thì chuyển event hỏng sang thư mục quarantine thay vì bỏ hẳn.
  Future<int?> _drainOne() async {
    final batch = _storage.readBatch(1);
    if (batch == null) return null;
    final (events, cp) = batch;
    try {
      await _upload(events);
    } on _HttpStatus catch (e) {
      if (!e.isPoison) rethrow;
      _storage.saveCheckpoint(cp); // bỏ event độc, hàng đợi đi tiếp
      return 0;
    }
    _storage.saveCheckpoint(cp);
    return 1;
  }

  Future<void> _upload(List<dynamic> events) async {
    // Protocol Spec §9
    final body = <String, dynamic>{
      'protocol_version': protocolVersion,
      'batch_id': _uuid.v7(),
      'device_id': config.deviceId,
      'session_id': sessionId,
    };

    final pem = config.serverPublicKey;
    if (pem != null) {
      final (encryptedKey, nonce, payload) = crypto.hybridEncrypt(
          pem, Uint8List.fromList(utf8.encode(jsonEncode(events))));
      body.addAll({
        'environment': config.environment,
        'algorithm': 'AES-256-GCM',
        'encrypted_key': encryptedKey,
        'nonce': nonce,
        'payload': payload,
      });
    } else {
      body['logs'] = events;
    }

    final resp = await http.post(
      Uri.parse('${config.endpoint}/logs/upload'),
      headers: {
        'content-type': 'application/json',
        'x-project-id': config.projectId,
        'x-api-key': config.apiKey,
        // Rate limit của server đếm theo project + device: một thiết bị lỗi
        // không kéo cả project vào 429.
        'x-device-id': config.deviceId,
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode >= 400) throw _HttpStatus(resp.statusCode);

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    // `duplicated: true` là THÀNH CÔNG (Protocol Spec §10, §12) — coi là lỗi
    // thì checkpoint không tiến và hàng đợi kẹt vĩnh viễn.
    if (decoded['success'] != true) {
      throw StateError('server rejected batch, code=${decoded['code']}');
    }
  }
}

class _HttpStatus implements Exception {
  _HttpStatus(this.code);
  final int code;

  /// Gửi lại y hệt sẽ luôn hỏng: 400 sai contract, 413 quá lớn, 422.
  bool get isPoison => code == 400 || code == 413 || code == 422;

  /// 4xx nhưng chỉ là tạm thời: 429 rate limit, 408 timeout — phải backoff rồi
  /// gửi lại, tuyệt đối không bỏ log.
  bool get isTransient => code == 429 || code == 408;

  @override
  String toString() => 'SLS upload failed: HTTP $code';
}

String _nowRfc3339() {
  final d = DateTime.now().toUtc();
  return '${d.toIso8601String().split('.').first}'
      '.${d.millisecond.toString().padLeft(3, '0')}Z';
}

/// Chuẩn hoá event_type về regex server (Event Model §8):
/// `^[a-z0-9_-]+(/[a-z0-9_-]+)+$`.
///
/// Chặn ở đây vì server validate cả batch: một event sai (vd
/// `'leanServices request'` — có chữ hoa và dấu cách) làm server trả 400 cho
/// **toàn bộ** batch, checkpoint không tiến ⇒ kẹt vĩnh viễn log của thiết bị.
String normalizeEventType(String s) => s
    .split('/')
    .map((seg) {
      final out = StringBuffer();
      for (final c in seg.toLowerCase().codeUnits) {
        final ok = (c >= 0x61 && c <= 0x7a) || // a-z
            (c >= 0x30 && c <= 0x39) || // 0-9
            c == 0x5f || // _
            c == 0x2d; // -
        if (ok) {
          out.writeCharCode(c);
        } else if (!out.toString().endsWith('_')) {
          out.write('_'); // khoảng trắng, ký tự lạ, unicode → '_'
        }
      }
      return out.toString();
    })
    .where((seg) => seg.isNotEmpty)
    .join('/');
