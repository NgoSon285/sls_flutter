import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart' hide Padding;
import 'package:sls_flutter/src/blf.dart' as blf;
import 'package:sls_flutter/src/crypto.dart' as crypto;
import 'package:sls_flutter/src/logger.dart';
import 'package:sls_flutter/src/storage.dart';

Directory tempDir() => Directory.systemTemp.createTempSync('sls-test-');

Map<String, dynamic> sample(int seq) => {
      'event_id': 'e$seq',
      'event_type': 'trade/order/opened',
      'schema_version': '1.0.0',
      'timestamp': '2026-07-18T00:00:00.000Z',
      'sequence': seq,
      'priority': 'normal',
      'environment': 'development',
      'sdk_version': '0.1.0',
      'plugin_name': 'core',
      'plugin_version': '0.1.0',
      'platform': 'test',
      'payload': {'symbol': 'EURUSD'},
    };

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('normalizeEventType', () {
    // Bản kiểm tương đương regex server: ^[a-z0-9_-]+(/[a-z0-9_-]+)+$
    bool hopLe(String s) {
      final segs = s.split('/');
      return segs.length >= 2 &&
          segs.every((seg) => RegExp(r'^[a-z0-9_-]+$').hasMatch(seg));
    }

    test('chuẩn hoá đúng regex server', () {
      // ca thật đã làm kẹt hàng đợi
      expect(normalizeEventType('event/app/leanServices request'),
          'event/app/leanservices_request');
      expect(normalizeEventType('trade/order/OPEN'), 'trade/order/open');
      expect(normalizeEventType('a//b'), 'a/b'); // segment rỗng bị bỏ
      expect(normalizeEventType('event/app/x  y'), 'event/app/x_y');
      expect(normalizeEventType('event/app/tiếng việt'), 'event/app/ti_ng_vi_t');
      // 2 segment vẫn hợp lệ theo Event Model §8
      expect(normalizeEventType('session/start'), 'session/start');

      for (final t in [
        'event/app/leanServices request',
        'trade/order/OPEN',
        'a//b',
        'event/app/x  y',
        'event/app/tiếng việt',
        'session/start',
        'event/app/',
        'event/app/  ',
      ]) {
        expect(hopLe(normalizeEventType(t)), isTrue,
            reason: '$t → ${normalizeEventType(t)} vẫn sai contract');
      }
    });
  });

  group('blf', () {
    test('layout đúng Storage Spec §6', () {
      final rec = blf.encode(2, 0x0102030405060708, 7, bytes('ab'));
      expect(rec.length, 26 + 2 + 4, reason: 'header 26 + payload + crc 4');
      final v = ByteData.sublistView(rec);
      expect(v.getUint32(0, Endian.little), 0x424C5346);
      expect(rec[4], 1); // version
      expect(rec[5], 2); // type
      expect(v.getUint64(6, Endian.little), 0x0102030405060708);
      expect(v.getUint64(14, Endian.little), 7);
      expect(v.getUint32(22, Endian.little), 2); // payload length
      expect(v.getUint32(28, Endian.little), blf.crc32(rec.sublist(0, 28)));
    });

    test('record type suy từ namespace (§7)', () {
      expect(blf.recordType('trade/order/opened'), 1);
      expect(blf.recordType('crash/dart/exception'), 2);
      expect(blf.recordType('event/app/x'), 3);
      expect(blf.recordType('network/http/request'), 4);
    });

    test('roundtrip nhiều record', () {
      final dir = tempDir();
      final path = File('${dir.path}/a.blf');
      final w = path.openSync(mode: FileMode.writeOnlyAppend);
      for (var i = 1; i <= 3; i++) {
        w.writeFromSync(blf.encode(1, 1000 + i, i, bytes('payload-$i')));
      }
      w.closeSync();

      final r = path.openSync();
      var offset = 0;
      for (var i = 1; i <= 3; i++) {
        final rec = blf.readRecord(r, offset)!;
        expect(rec.recordType, 1);
        expect(rec.sequence, i);
        expect(utf8.decode(rec.payload), 'payload-$i');
        offset = rec.endOffset;
      }
      expect(blf.readRecord(r, offset), isNull);
      r.closeSync();
      dir.deleteSync(recursive: true);
    });

    test('recover cắt đuôi hỏng, giữ record tốt', () {
      final dir = tempDir();
      final path = File('${dir.path}/a.blf');
      final w = path.openSync(mode: FileMode.writeOnlyAppend);
      w.writeFromSync(blf.encode(2, 1, 1, bytes('good')));
      final goodLen = w.lengthSync();
      // giả lập crash: record thứ hai chỉ ghi được một nửa
      final torn = blf.encode(2, 2, 2, bytes('torn-record'));
      w.writeFromSync(torn.sublist(0, torn.length ~/ 2));
      w.closeSync();

      blf.recover(path);
      expect(path.lengthSync(), goodLen);

      final r = path.openSync();
      expect(utf8.decode(blf.readRecord(r, 0)!.payload), 'good');
      r.closeSync();
      dir.deleteSync(recursive: true);
    });

    test('CRC sai bị từ chối', () {
      final dir = tempDir();
      final path = File('${dir.path}/a.blf');
      final encoded = blf.encode(3, 1, 1, bytes('data'));
      encoded[encoded.length - 6] ^= 0xFF; // sửa payload, CRC không còn khớp
      path.writeAsBytesSync(encoded);

      final r = path.openSync();
      expect(blf.readRecord(r, 0), isNull);
      r.closeSync();
      dir.deleteSync(recursive: true);
    });
  });

  group('crypto', () {
    test('roundtrip + tamper', () {
      final key = crypto.deriveKey('dev-key');
      final ct = crypto.encrypt(key, bytes('hello'));
      expect(utf8.decode(crypto.decrypt(key, ct)), 'hello');
      expect(ct.length, 12 + 5 + 16, reason: 'nonce || ciphertext || tag');

      // sửa 1 byte ciphertext → GCM tag phải fail
      final bad = Uint8List.fromList(ct)..[ct.length - 1] ^= 1;
      expect(() => crypto.decrypt(key, bad), throwsA(anything));

      // khóa sai → fail
      expect(() => crypto.decrypt(crypto.deriveKey('other'), ct),
          throwsA(anything));
    });

    test('hybrid encrypt roundtrip', () {
      // RSA-2048 cho test nhanh; production dùng RSA-4096
      final rng = FortunaRandom()
        ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i))));
      final pair = (RSAKeyGenerator()
            ..init(ParametersWithRandom(
                RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rng)))
          .generateKeyPair();
      final pub = pair.publicKey as RSAPublicKey;
      final priv = pair.privateKey as RSAPrivateKey;

      final pem = '-----BEGIN PUBLIC KEY-----\n'
          '${base64.encode(_spkiDer(pub))}\n'
          '-----END PUBLIC KEY-----';

      final (ek, nonce, ct) = crypto.hybridEncrypt(pem, bytes('secret logs'));

      // Server side: unwrap session key rồi giải mã payload
      final sessionKey = (OAEPEncoding.withSHA256(RSAEngine())
            ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv)))
          .process(base64.decode(ek));
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
            false,
            AEADParameters(KeyParameter(sessionKey), 128,
                base64.decode(nonce), Uint8List(0)));
      expect(utf8.decode(gcm.process(base64.decode(ct))), 'secret logs');
    });
  });

  group('storage', () {
    void roundtrip({required bool jsonl, Uint8List? key}) {
      final dir = tempDir();
      final s = Storage.open(dir.path, jsonl: jsonl, key: key);
      for (var i = 1; i <= 5; i++) {
        s.append(sample(i));
      }

      // Đọc batch 3, commit checkpoint, phần còn lại phải là 2
      final (batch, cp) = s.readBatch(3)!;
      expect(batch.length, 3);
      expect(batch[0]['event_type'], 'trade/order/opened');
      s.saveCheckpoint(cp);

      final (rest, cp2) = s.readBatch(100)!;
      expect(rest.length, 2);
      s.saveCheckpoint(cp2);

      expect(s.readBatch(100), isNull);
      dir.deleteSync(recursive: true);
    }

    test('jsonl roundtrip', () => roundtrip(jsonl: true));
    test('blf plain roundtrip', () => roundtrip(jsonl: false));
    test('blf encrypted roundtrip',
        () => roundtrip(jsonl: false, key: crypto.deriveKey('dev-key')));

    test('checkpoint đúng định dạng §10', () {
      final dir = tempDir();
      final s = Storage.open(dir.path, jsonl: true);
      s.append(sample(1));
      s.saveCheckpoint(s.readBatch(1)!.$2);

      final m = jsonDecode(File('${dir.path}/metadata/checkpoint.meta')
          .readAsStringSync()) as Map<String, dynamic>;
      expect(m.keys.toSet(), {'file', 'offset'});
      expect(m['file'], startsWith('events-'));
      expect(m['offset'], greaterThan(0));
      dir.deleteSync(recursive: true);
    });

    test('record hỏng bị bỏ nhưng ĐƯỢC ĐẾM, không mất âm thầm', () {
      final dir = tempDir();
      final s = Storage.open(dir.path, jsonl: true);
      s.append(sample(1));
      s.append(sample(2));

      // Chèn một dòng rác vào giữa: đọc được record tốt, đếm được record hỏng.
      final f = Directory('${dir.path}/logs').listSync().first as File;
      final lines = f.readAsStringSync().split('\n');
      f.writeAsStringSync('${lines[0]}\nkhông-phải-json\n${lines[1]}\n');

      final (events, _) = s.readBatch(10)!;
      expect(events.length, 2, reason: 'record tốt vẫn phải đọc được');
      expect(s.takeDropped(), 1);
      expect(s.takeDropped(), 0, reason: 'đọc xong phải reset, không báo trùng');
      dir.deleteSync(recursive: true);
    });

    test('dòng ghi dở lúc crash không bị tính là hỏng', () {
      final dir = tempDir();
      final s = Storage.open(dir.path, jsonl: true);
      s.append(sample(1));
      // Ghi dở: không có '\n' kết thúc. Nếu tính nó là record hỏng thì mỗi lần
      // crash lại báo nhầm một mất mát, và record đó bị nhảy qua vĩnh viễn.
      final f = Directory('${dir.path}/logs').listSync().first as File;
      f.writeAsStringSync('{"event_id":"dang-ghi-do"', mode: FileMode.append);

      final (events, _) = s.readBatch(10)!;
      expect(events.length, 1);
      expect(s.takeDropped(), 0);
      dir.deleteSync(recursive: true);
    });

    test('file BLF mã hoá không lộ plaintext', () {
      final dir = tempDir();
      Storage.open(dir.path, jsonl: false, key: crypto.deriveKey('k'))
          .append(sample(1));
      final f = Directory('${dir.path}/logs').listSync().first as File;
      expect(utf8.decode(f.readAsBytesSync(), allowMalformed: true),
          isNot(contains('EURUSD')));
      dir.deleteSync(recursive: true);
    });

    test('rotate theo dung lượng, đọc đúng thứ tự', () {
      final dir = tempDir();
      // file rất nhỏ để ép rotate sau mỗi record
      final s = Storage.open(dir.path,
          jsonl: true, limits: const Limits(maxFileSize: 10));
      for (var i = 1; i <= 4; i++) {
        s.append(sample(i));
      }
      expect(Directory('${dir.path}/logs').listSync().length,
          greaterThanOrEqualTo(4));

      final seqs = <int>{};
      while (true) {
        final b = s.readBatch(100);
        if (b == null) break;
        seqs.addAll(b.$1.map((e) => e['sequence'] as int));
        s.saveCheckpoint(b.$2);
      }
      expect(seqs, {1, 2, 3, 4});
      dir.deleteSync(recursive: true);
    });

    test('cleanup chỉ xoá file đã sync', () {
      final dir = tempDir();
      final s = Storage.open(dir.path,
          jsonl: true,
          // mỗi record một file, ép FIFO xoá mọi file đã sync
          limits: const Limits(maxFileSize: 10, maxTotalSize: 1));
      for (var i = 1; i <= 3; i++) {
        s.append(sample(i));
      }
      for (var i = 0; i < 2; i++) {
        s.saveCheckpoint(s.readBatch(1)!.$2);
      }

      expect(Directory('${dir.path}/logs').listSync().length, lessThan(3),
          reason: 'file synced phải bị xoá');
      final (batch, _) = s.readBatch(10)!;
      expect(batch.length, 1);
      expect(batch[0]['sequence'], 3, reason: 'log chưa sync không được mất');
      dir.deleteSync(recursive: true);
    });

    test('retention 0 ngày xoá file synced ngay', () {
      final dir = tempDir();
      final s = Storage.open(dir.path,
          jsonl: true,
          limits: const Limits(maxFileSize: 10, retentionDays: 0));
      s.append(sample(1));
      s.append(sample(2));

      // checkpoint trỏ sang file 2 → file 1 thành synced, retention 0 xoá ngay
      for (var i = 0; i < 2; i++) {
        s.saveCheckpoint(s.readBatch(1)!.$2);
      }
      expect(Directory('${dir.path}/logs').listSync().length, 1,
          reason: 'chỉ còn file checkpoint đang trỏ');
      dir.deleteSync(recursive: true);
    });

    test('BLF recover khi mở lại sau ghi dở', () {
      final dir = tempDir();
      Storage.open(dir.path, jsonl: false).append(sample(1));

      // giả lập crash: nối rác vào cuối file
      final f = Directory('${dir.path}/logs').listSync().first as File;
      f.writeAsBytesSync([0xDE, 0xAD, 0xBE], mode: FileMode.append);

      final s = Storage.open(dir.path, jsonl: false);
      expect(s.readBatch(10)!.$1.length, 1);
      dir.deleteSync(recursive: true);
    });
  });
}

/// Bọc RSAPublicKey thành DER SubjectPublicKeyInfo để test parser PEM.
Uint8List _spkiDer(RSAPublicKey pub) {
  final pkcs1 = ASN1Sequence()
    ..add(ASN1Integer(pub.modulus!))
    ..add(ASN1Integer(pub.exponent!));
  final algo = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'))
    ..add(ASN1Null());
  return (ASN1Sequence()
        ..add(algo)
        ..add(ASN1BitString(stringValues: pkcs1.encode())))
      .encode();
}
