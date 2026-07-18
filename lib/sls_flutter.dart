library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'src/logger.dart';

export 'src/logger.dart' show Config, Logger, normalizeEventType;

/// Mức ưu tiên event — Event Model Specification §9.
enum SlsPriority { critical, high, normal, low, debug }

/// Offline-first logging SDK. Dart thuần, không cần native build.
///
/// ```dart
/// await SlsLogger.init(
///   dir: '${(await getApplicationSupportDirectory()).path}/sls',
///   endpoint: 'https://logs.example.com',
///   projectId: 'my-project',
///   apiKey: '...',
///   deviceId: '...',
/// );
/// SlsLogger.logTrade({'trade_id': 'T-1', 'symbol': 'EURUSD', 'side': 'BUY'});
/// await SlsLogger.syncAll();
/// ```
class SlsLogger {
  SlsLogger._();

  static Logger? _logger;
  static Timer? _autoSyncTimer;
  static _LifecycleSyncObserver? _lifecycleObserver;
  static bool _syncing = false;

  /// Session hiện tại, null nếu chưa [init].
  static String? get sessionId => _logger?.sessionId;

  /// Khởi tạo SDK. Gọi một lần khi app start; gọi lại là an toàn (hot restart).
  ///
  /// [serverPublicKey]: PEM public key của server — bật hybrid encryption khi
  /// upload (bắt buộc với staging/production, Protocol Spec §13). Với
  /// production, log local cũng tự động mã hoá AES-256-GCM.
  ///
  /// [autoSyncInterval]: nếu đặt, SDK tự sync định kỳ và mỗi khi app vào
  /// background. Lỗi mạng bị nuốt im lặng — log vẫn ở local, lần sau gửi tiếp.
  static Future<void> init({
    required String dir,
    required String endpoint,
    required String projectId,
    required String apiKey,
    required String deviceId,
    String environment = 'production',
    String? serverPublicKey,
    Duration? autoSyncInterval,
  }) async {
    stopAutoSync();
    _logger = Logger(Config(
      dir: dir,
      endpoint: endpoint,
      projectId: projectId,
      apiKey: apiKey,
      deviceId: deviceId,
      environment: environment,
      serverPublicKey: serverPublicKey,
    ));
    if (autoSyncInterval != null) {
      _startAutoSync(autoSyncInterval);
      // Sync ngay khi mở app: đẩy log còn tồn của phiên trước (kể cả phiên crash)
      unawaited(_safeSync());
      // Lấy remote config ở nền — không chặn init, mất mạng cũng không sao.
      // Server chỉ định chu kỳ khác thì đổi timer theo (GET /config).
      unawaited(_logger!.refreshConfig().then((_) {
        final remote = _logger?.syncInterval;
        if (remote != null && remote != autoSyncInterval) _startAutoSync(remote);
      }));
    }
  }

  static void _startAutoSync(Duration interval) {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(interval, (_) => _safeSync());
    if (_lifecycleObserver == null) {
      _lifecycleObserver = _LifecycleSyncObserver();
      WidgetsBinding.instance.addObserver(_lifecycleObserver!);
    }
  }

  /// Tắt auto sync (nếu đã bật qua `autoSyncInterval`).
  static void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    if (_lifecycleObserver != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
      _lifecycleObserver = null;
    }
  }

  /// Sync nuốt lỗi + chống chạy chồng, dùng cho auto sync.
  static Future<void> _safeSync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      await _logger?.syncAll();
    } catch (_) {
      // offline first: lỗi mạng bỏ qua, log vẫn ở local
    } finally {
      _syncing = false;
    }
  }

  /// Gắn user vào mọi event ghi **sau lời gọi này** — để tra log theo người dùng.
  /// Gọi lúc đăng nhập; truyền null khi đăng xuất.
  ///
  /// Event đã ghi trước đó không đổi (append-only): log trước khi đăng nhập vẫn
  /// không có user, đúng với thực tế lúc nó xảy ra.
  static void setUser(String? userId) => _logger?.userId = userId;

  /// User đang gắn, null nếu chưa [setUser].
  static String? get userId => _logger?.userId;

  /// Ghi event xuống local storage (append-only, không chạm network).
  static void log(
    String eventType,
    Map<String, dynamic> payload, {
    SlsPriority priority = SlsPriority.normal,
  }) =>
      _logger?.log(eventType, priority.name, payload);

  static void logTrade(Map<String, dynamic> payload, {String name = 'opened'}) =>
      log('trade/order/$name', payload, priority: SlsPriority.high);

  static void logEvent(String name, Map<String, dynamic> payload) =>
      log('event/app/$name', payload);

  static void logCrash(Map<String, dynamic> payload) =>
      log('crash/dart/exception', payload, priority: SlsPriority.critical);

  /// Upload toàn bộ log chưa đồng bộ. Trả về số event server đã nhận.
  static Future<int> syncAll() async => await _logger?.syncAll() ?? 0;

  /// Lấy lại cấu hình runtime từ `GET /config` (batch size, chu kỳ sync, van
  /// bật/tắt upload). Best-effort — hỏng thì giữ cấu hình đang dùng.
  /// `init` với `autoSyncInterval` đã tự gọi một lần ở nền.
  static Future<void> refreshConfig() async => _logger?.refreshConfig();

  /// Cấu hình server trả về ở lần [refreshConfig] gần nhất; rỗng nếu chưa lấy được.
  static Map<String, dynamic> get remoteConfig =>
      _logger?.remoteConfig ?? const {};
}

/// Sync khi app vào background (một phần của auto sync).
class _LifecycleSyncObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(SlsLogger._safeSync());
    }
  }
}
