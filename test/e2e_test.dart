import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart' hide Padding;
import 'package:sls_flutter/sls_flutter.dart';

/// Server giả: ghi lại request nhận được, trả lời theo Protocol Spec §10.
class FakeServer {
  FakeServer(this._server, this.status, this.config, this.configStatus) {
    _server.listen((req) async {
      // GET /config — remote config (Protocol: chỉ giá trị không bí mật)
      if (req.uri.path == '/config') {
        req.response.statusCode = configStatus;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(config));
        await req.response.close();
        return;
      }

      final body = jsonDecode(await utf8.decoder.bind(req).join());
      uploads.add((headers: req.headers, body: body as Map<String, dynamic>));
      req.response.statusCode = status(uploads.length);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'success': req.response.statusCode < 400,
        'code': 1000,
        'accepted': (body['logs'] as List?)?.length ?? 1,
        'server_time': '2026-07-18T00:00:00.000Z',
      }));
      await req.response.close();
    });
  }

  static Future<FakeServer> start({
    int Function(int)? status,
    Map<String, dynamic> config = const {},
    int configStatus = 200,
  }) async =>
      FakeServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
          status ?? (_) => 200, config, configStatus);

  final HttpServer _server;
  final int Function(int nth) status;
  final int configStatus;
  Map<String, dynamic> config;
  final uploads = <({HttpHeaders headers, Map<String, dynamic> body})>[];

  String get endpoint => 'http://127.0.0.1:${_server.port}';
  Future<void> stop() => _server.close(force: true);

  List<dynamic> get allLogs =>
      uploads.expand((r) => r.body['logs'] as List).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Binding của flutter_test cài HttpOverrides ép mọi request về 400.
  // Gỡ ra để test nói chuyện thật với FakeServer trên loopback.
  HttpOverrides.global = null;

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sls-e2e-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> initSdk(String endpoint,
          {String env = 'development', String? pubKey}) =>
      SlsLogger.init(
        dir: dir.path,
        endpoint: endpoint,
        projectId: 'proj-1',
        apiKey: 'secret-key',
        deviceId: 'device-1',
        environment: env,
        serverPublicKey: pubKey,
      );

  test('log → sync → server nhận đủ event, đúng header', () async {
    final server = await FakeServer.start();
    await initSdk(server.endpoint);

    SlsLogger.logTrade({'trade_id': 'T-1', 'symbol': 'EURUSD', 'side': 'BUY'});
    SlsLogger.logEvent('leanServices request', {'ms': 12});
    SlsLogger.logCrash({'error': 'boom'});

    expect(await SlsLogger.syncAll(), 3);

    final req = server.uploads.single;
    expect(req.headers.value('x-project-id'), 'proj-1');
    expect(req.headers.value('x-api-key'), 'secret-key');
    expect(req.body['protocol_version'], '1.0');
    expect(req.body['device_id'], 'device-1');
    expect(req.body['session_id'], SlsLogger.sessionId);

    final logs = server.allLogs;
    expect(logs.map((e) => e['event_type']), [
      'trade/order/opened',
      'event/app/leanservices_request', // đã chuẩn hoá
      'crash/dart/exception',
    ]);
    expect(logs.map((e) => e['priority']), ['high', 'normal', 'critical']);
    expect(logs.map((e) => e['sequence']), [1, 2, 3]);
    expect(logs.first['payload']['symbol'], 'EURUSD');

    // đã sync hết → lần sau không gửi lại
    expect(await SlsLogger.syncAll(), 0);
    expect(server.uploads.length, 1);
    await server.stop();
  });

  test('offline: log của phiên trước vẫn còn sau khi mở lại SDK', () async {
    // endpoint chết → chưa sync được gì, checkpoint không tiến
    await initSdk('http://127.0.0.1:1');
    SlsLogger.logEvent('a', {'i': 1});

    // server sống, SDK mở lại cùng thư mục → log phiên trước vẫn đó
    final server = await FakeServer.start();
    await initSdk(server.endpoint);
    SlsLogger.logEvent('b', {'i': 2});

    expect(await SlsLogger.syncAll(), 2);
    expect(server.allLogs.map((e) => e['event_type']),
        ['event/app/a', 'event/app/b']);
    await server.stop();
  });

  test('server 500: backoff rồi gửi lại, không mất và không nhân đôi log',
      () async {
    // request đầu 5xx → SDK ngủ 5s (backoff bậc 1) rồi thử lại
    final server = await FakeServer.start(status: (n) => n == 1 ? 500 : 200);
    await initSdk(server.endpoint);
    SlsLogger.logEvent('a', {'i': 1});
    SlsLogger.logEvent('b', {'i': 2});

    expect(await SlsLogger.syncAll(), 2);
    expect(server.uploads.length, 2, reason: 'lần 1 hỏng, lần 2 thành công');
    expect(server.uploads.last.body['logs'].length, 2,
        reason: 'batch gửi lại nguyên vẹn');
    expect(await SlsLogger.syncAll(), 0);
    await server.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('server 401: không retry, KHÔNG bỏ log', () async {
    final server = await FakeServer.start(status: (_) => 401);
    await initSdk(server.endpoint);
    SlsLogger.logEvent('a', {'i': 1});

    await expectLater(SlsLogger.syncAll(), throwsA(anything));
    expect(server.uploads.length, 1, reason: 'không retry lỗi auth');

    // sửa key xong (server nhận lại) thì log cũ vẫn gửi được
    await server.stop();
    final ok = await FakeServer.start();
    await initSdk(ok.endpoint);
    expect(await SlsLogger.syncAll(), 1);
    expect(ok.allLogs.single['event_type'], 'event/app/a');
    await ok.stop();
  });

  test('server 429: backoff rồi gửi lại, KHÔNG bỏ log', () async {
    // rate limit là lỗi tạm — bỏ log ở đây là mất dữ liệu vì server quá tải
    final server = await FakeServer.start(status: (n) => n == 1 ? 429 : 200);
    await initSdk(server.endpoint);
    SlsLogger.logEvent('a', {'i': 1});

    expect(await SlsLogger.syncAll(), 1);
    expect(server.uploads.length, 2, reason: 'phải thử lại sau backoff');
    // lần gửi lại mang đúng event cũ — không mất, không đổi nội dung
    expect(server.uploads.last.body['logs'].single['event_type'],
        'event/app/a');
    await server.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('gửi kèm x-device-id để server rate limit theo thiết bị', () async {
    final server = await FakeServer.start();
    await initSdk(server.endpoint);
    SlsLogger.logEvent('a', {});
    await SlsLogger.syncAll();
    expect(server.uploads.single.headers.value('x-device-id'), 'device-1');
    await server.stop();
  });

  test('server 400: bỏ đúng event độc, phần còn lại vẫn đi', () async {
    // request 1 = cả batch → 400. Sau đó drain từng event: event đầu 400, còn lại 200.
    final server =
        await FakeServer.start(status: (n) => n == 1 || n == 2 ? 400 : 200);
    await initSdk(server.endpoint);
    for (var i = 1; i <= 3; i++) {
      SlsLogger.logEvent('e$i', {'i': i});
    }

    expect(await SlsLogger.syncAll(), 2, reason: '1 event độc bị bỏ');
    expect(server.allLogs.last['payload']['i'], 3);
    await server.stop();
  });

  test('production: log local mã hoá + upload hybrid encryption', () async {
    final server = await FakeServer.start();
    final (pem, priv) = _rsaKeyPair();
    await initSdk(server.endpoint, env: 'production', pubKey: pem);

    SlsLogger.logTrade({'trade_id': 'T-9', 'symbol': 'XAUUSD'});
    expect(await SlsLogger.syncAll(), 1);

    // file local là BLF, không lộ plaintext
    final f = Directory('${dir.path}/logs').listSync().single as File;
    expect(f.path, endsWith('.blf'));
    expect(utf8.decode(f.readAsBytesSync(), allowMalformed: true),
        isNot(contains('XAUUSD')));

    // body upload không có 'logs' plain, giải mã lại đúng nội dung
    final body = server.uploads.single.body;
    expect(body['logs'], isNull);
    expect(body['algorithm'], 'AES-256-GCM');
    expect(body['environment'], 'production');

    final sessionKey = (OAEPEncoding.withSHA256(RSAEngine())
          ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv)))
        .process(base64.decode(body['encrypted_key'] as String));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
          false,
          AEADParameters(KeyParameter(sessionKey), 128,
              base64.decode(body['nonce'] as String), Uint8List(0)));
    final logs = jsonDecode(
        utf8.decode(gcm.process(base64.decode(body['payload'] as String))));
    expect(logs.single['payload']['symbol'], 'XAUUSD');
    expect(logs.single['event_type'], 'trade/order/opened');
    await server.stop();
  });

  test('remote config: batch_size và enabled từ GET /config', () async {
    final server = await FakeServer.start(config: {'batch_size': 2});
    await initSdk(server.endpoint);
    for (var i = 1; i <= 5; i++) {
      SlsLogger.logEvent('e$i', {'i': i});
    }

    await SlsLogger.refreshConfig();
    expect(await SlsLogger.syncAll(), 5);
    // 5 event, batch 2 → 3 request (2+2+1) thay vì 1 request 100 event
    expect(server.uploads.map((r) => (r.body['logs'] as List).length), [2, 2, 1]);

    // van khoá từ xa: enabled=false thì ngừng upload, log vẫn ghi local
    server.config = {'enabled': false};
    await SlsLogger.refreshConfig();
    SlsLogger.logEvent('sau-khi-tat', {});
    expect(await SlsLogger.syncAll(), 0);
    expect(server.uploads.length, 3, reason: 'không gửi thêm request nào');
    await server.stop();
  });

  test('remote config chết thì SDK vẫn chạy với mặc định', () async {
    final server = await FakeServer.start(configStatus: 500);
    await initSdk(server.endpoint);
    SlsLogger.logEvent('a', {});

    await SlsLogger.refreshConfig(); // không được ném
    expect(await SlsLogger.syncAll(), 1);
    await server.stop();
  });

  test('autoSyncInterval tự đẩy log không cần gọi syncAll', () async {
    final server = await FakeServer.start();
    await SlsLogger.init(
      dir: dir.path,
      endpoint: server.endpoint,
      projectId: 'proj-1',
      apiKey: 'k',
      deviceId: 'd',
      environment: 'development',
      autoSyncInterval: const Duration(milliseconds: 50),
    );
    SlsLogger.logEvent('tick', {});

    for (var i = 0; i < 40 && server.allLogs.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    SlsLogger.stopAutoSync();
    expect(server.allLogs.single['event_type'], 'event/app/tick');
    await server.stop();
  });
}

(String, RSAPrivateKey) _rsaKeyPair() {
  final rng = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i * 7))));
  final pair = (RSAKeyGenerator()
        ..init(ParametersWithRandom(
            RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rng)))
      .generateKeyPair();
  final pub = pair.publicKey as RSAPublicKey;
  final pkcs1 = ASN1Sequence()
    ..add(ASN1Integer(pub.modulus!))
    ..add(ASN1Integer(pub.exponent!));
  final der = (ASN1Sequence()
        ..add(ASN1Sequence()
          ..add(ASN1ObjectIdentifier.fromIdentifierString(
              '1.2.840.113549.1.1.1'))
          ..add(ASN1Null()))
        ..add(ASN1BitString(stringValues: pkcs1.encode())))
      .encode();
  return (
    '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n-----END PUBLIC KEY-----',
    pair.privateKey as RSAPrivateKey,
  );
}
