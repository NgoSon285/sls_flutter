import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

const _nonceLen = 12;

final _rand = Random.secure();

Uint8List _randomBytes(int n) =>
    Uint8List.fromList(List.generate(n, (_) => _rand.nextInt(256)));

/// Khóa local 32 byte derive từ API key (Storage Spec §13).
/// ponytail: chuyển sang OS keystore (Keychain/Keystore) khi cần chống reverse engineering.
Uint8List deriveKey(String apiKey) =>
    SHA256Digest().process(Uint8List.fromList(utf8.encode(apiKey)));

GCMBlockCipher _gcm(Uint8List key, Uint8List nonce, bool forEncryption) =>
    GCMBlockCipher(AESEngine())
      ..init(forEncryption,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));

/// AES-256-GCM với nonce ngẫu nhiên. Trả về (nonce, ciphertext+tag).
(Uint8List, Uint8List) encryptDetached(Uint8List key, Uint8List plaintext) {
  final nonce = _randomBytes(_nonceLen);
  return (nonce, _gcm(key, nonce, true).process(plaintext));
}

/// Payload của record BLF ở production: nonce(12) || ciphertext || tag(16)
/// — Storage Spec §13.
Uint8List encrypt(Uint8List key, Uint8List plaintext) {
  final (nonce, ct) = encryptDetached(key, plaintext);
  return Uint8List(nonce.length + ct.length)
    ..setAll(0, nonce)
    ..setAll(nonce.length, ct);
}

Uint8List decrypt(Uint8List key, Uint8List data) {
  if (data.length < _nonceLen) {
    throw const FormatException('ciphertext too short');
  }
  return _gcm(key, Uint8List.sublistView(data, 0, _nonceLen), false)
      .process(Uint8List.sublistView(data, _nonceLen));
}

/// Hybrid encryption (Protocol Spec §5–§6): sinh AES-256 session key ngẫu nhiên,
/// mã hoá plaintext bằng AES-256-GCM, wrap session key bằng RSA-OAEP(SHA-256)
/// với public key PEM của server. Trả về (encrypted_key, nonce, payload) base64.
///
/// ponytail: chưa có digital signature (§7) — AES-GCM đã đảm bảo integrity;
/// thêm Ed25519 khi cần chống thay thế toàn bộ payload bởi client giả mạo.
(String, String, String) hybridEncrypt(
    String serverPublicKeyPem, Uint8List plaintext) {
  final sessionKey = _randomBytes(32);
  final (nonce, ct) = encryptDetached(sessionKey, plaintext);

  final rng = FortunaRandom()..seed(KeyParameter(_randomBytes(32)));
  final oaep = OAEPEncoding.withSHA256(RSAEngine())
    ..init(
        true,
        ParametersWithRandom(
            PublicKeyParameter<RSAPublicKey>(
                rsaPublicKeyFromPem(serverPublicKeyPem)),
            rng));

  return (
    base64.encode(oaep.process(sessionKey)),
    base64.encode(nonce),
    base64.encode(ct),
  );
}

/// Parse PEM public key: SubjectPublicKeyInfo (`BEGIN PUBLIC KEY`) hoặc
/// PKCS#1 (`BEGIN RSA PUBLIC KEY`).
RSAPublicKey rsaPublicKeyFromPem(String pem) {
  final der = base64.decode(pem
      .split('\n')
      .where((l) => !l.startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), ''));

  var seq = ASN1Parser(der).nextObject() as ASN1Sequence;
  // SPKI: [AlgorithmIdentifier, BIT STRING chứa PKCS#1 bên trong]
  if (seq.elements!.first is ASN1Sequence) {
    final bits = seq.elements![1] as ASN1BitString;
    var inner = Uint8List.fromList(bits.stringValues!);
    // có bản pointycastle giữ lại byte "unused bits" ở đầu
    if (inner.isNotEmpty && inner[0] == 0x00 && inner[1] != 0x02) {
      inner = Uint8List.sublistView(inner, 1);
    }
    seq = ASN1Parser(inner).nextObject() as ASN1Sequence;
  }
  return RSAPublicKey(
    (seq.elements![0] as ASN1Integer).integer!,
    (seq.elements![1] as ASN1Integer).integer!,
  );
}
