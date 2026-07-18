import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sls_flutter/sls_flutter.dart';

// Đổi sang project của bạn. `dev/dev-key` là project seed sẵn trên backend.
const _endpoint = 'https://sls-upload-api.onrender.com';
const _projectId = 'dev';
const _apiKey = 'dev-key';

// development: log local là JSONL đọc bằng mắt được, upload plain.
// Đổi sang 'production' để thấy file .blf mã hoá (cần serverPublicKey mới
// upload được — xem README mục 6).
const _environment = 'development';

late final String logDir;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  logDir = '${(await getApplicationSupportDirectory()).path}/sls';
  await SlsLogger.init(
    dir: logDir,
    endpoint: _endpoint,
    projectId: _projectId,
    apiKey: _apiKey,
    deviceId: 'example-${Platform.operatingSystem}',
    environment: _environment,
    // Bật auto sync: SDK tự đẩy log định kỳ, tự sync khi vào background, và
    // tự lấy GET /config ở nền (server đổi chu kỳ thì timer đổi theo).
    autoSyncInterval: const Duration(seconds: 30),
  );

  // Mọi crash chưa bắt được đều thành log — ghi local trước, sync sau.
  FlutterError.onError = (details) {
    SlsLogger.logCrash({
      'exception': details.exception.toString(),
      'stacktrace': details.stack.toString(),
    });
    FlutterError.presentError(details);
  };

  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SLS example',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _lines = <String>[];
  int _written = 0;
  bool _syncing = false;

  /// App thật lấy từ phiên đăng nhập; ở đây là user giả để demo.
  String? _user;

  void _say(String line) => setState(() => _lines.insert(0, line));

  void _logTrade() {
    final id = 'T-${DateTime.now().millisecondsSinceEpoch % 100000}';
    SlsLogger.logTrade({
      'trade_id': id,
      'symbol': 'EURUSD',
      'side': 'BUY',
      'volume': 1,
      'price': 1.12,
    });
    setState(() => _written++);
    _say('ghi trade $id');
  }

  void _logEvent() {
    // Chữ hoa + khoảng trắng cố ý: SDK tự chuẩn hoá thành
    // event/app/screen_open, nếu không server sẽ từ chối cả batch.
    SlsLogger.logEvent('Screen Open', {'screen': 'Home'});
    setState(() => _written++);
    _say("ghi event 'Screen Open' → event/app/screen_open");
  }

  void _logCrash() {
    SlsLogger.logCrash({
      'exception': 'DemoException: nút crash được bấm',
      'stacktrace': StackTrace.current.toString(),
    });
    setState(() => _written++);
    _say('ghi crash');
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final t = Stopwatch()..start();
    try {
      final n = await SlsLogger.syncAll();
      _say(n == 0
          ? 'sync: không còn log nào chưa gửi (${t.elapsedMilliseconds}ms)'
          : 'sync: server nhận $n event (${t.elapsedMilliseconds}ms)');
    } catch (e) {
      // Offline-first: lỗi ở đây không mất log, lần sync sau gửi tiếp.
      _say('sync lỗi: $e — log vẫn nằm trên đĩa');
    } finally {
      setState(() => _syncing = false);
    }
  }

  void _toggleLogin() {
    // App thật: gọi setUser lúc đăng nhập thành công, setUser(null) lúc đăng
    // xuất, và gọi lại NGAY SAU init nếu phiên đăng nhập cũ còn hiệu lực —
    // quên bước đó thì cả phiên chạy không có user_id.
    setState(() => _user = _user == null ? 'u-demo-42' : null);
    SlsLogger.setUser(_user);
    _say(_user == null
        ? 'đăng xuất — event sau đây không còn user_id'
        : 'đăng nhập $_user — event sau đây mang user_id này');
  }

  Future<void> _showConfig() async {
    await SlsLogger.refreshConfig();
    final c = SlsLogger.remoteConfig;
    if (c.isEmpty) {
      // /config chưa deploy hoặc mạng hỏng — SDK vẫn chạy bằng mặc định.
      _say('config: server chưa trả về gì, SDK dùng mặc định');
      return;
    }
    _say('config: ${c.entries.map((e) => "${e.key}=${e.value}").join(", ")}');
    if (c['enabled'] == false) {
      _say('⚠ enabled=false — server đã khoá upload, log vẫn ghi local');
    }
  }

  void _showFiles() {
    final dir = Directory('$logDir/logs');
    if (!dir.existsSync()) {
      _say('chưa có file log nào');
      return;
    }
    final cp = File('$logDir/metadata/checkpoint.meta');
    _say(cp.existsSync()
        ? 'checkpoint: ${cp.readAsStringSync()}'
        : 'checkpoint: chưa có (chưa sync thành công lần nào)');
    for (final f in dir.listSync().whereType<File>()) {
      _say('${f.uri.pathSegments.last} — ${f.lengthSync()} byte');
    }
    _say('thư mục: $logDir');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SLS example')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$_endpoint · $_projectId · $_environment'),
                Text('session: ${SlsLogger.sessionId ?? "chưa init"}'),
                Text('user: ${SlsLogger.userId ?? "chưa đăng nhập"}'),
                Text('đã ghi local: $_written event · auto sync 30s'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                        onPressed: _logTrade, child: const Text('Log trade')),
                    FilledButton.tonal(
                        onPressed: _logEvent, child: const Text('Log event')),
                    FilledButton.tonal(
                        onPressed: _logCrash, child: const Text('Log crash')),
                    OutlinedButton(
                      onPressed: _syncing ? null : _sync,
                      child: Text(_syncing ? 'Đang sync...' : 'Sync now'),
                    ),
                    OutlinedButton(
                        onPressed: _showFiles, child: const Text('Xem file')),
                    OutlinedButton(
                        onPressed: _showConfig, child: const Text('Config')),
                    OutlinedButton(
                      onPressed: _toggleLogin,
                      child: Text(_user == null ? 'Đăng nhập' : 'Đăng xuất'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (_, i) => ListTile(
                dense: true,
                title: Text(_lines[i], style: const TextStyle(fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
