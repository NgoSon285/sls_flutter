/// Binary Log Format — Storage Specification §6.
/// Little endian. Header cố định 26 byte, tổng record = 30 + payload_length:
///
/// ```text
/// offset 0   magic      u32  = 0x424C5346
/// offset 4   version    u8   = 1
/// offset 5   type       u8   (§7: 1 trade, 2 crash, 3 event, 4 diagnostic)
/// offset 6   timestamp  u64  (ms epoch)
/// offset 14  sequence   u64
/// offset 22  len        u32  (số byte payload)
/// offset 26  payload    [u8; len]
/// offset 26+len crc32   u32  (trên toàn bộ header + payload)
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

const magic = 0x424C5346;
const version = 1;
const headerLen = 26;

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) >>> 0;
}

/// Record Type theo Storage Spec §7, suy từ namespace của event_type.
int recordType(String eventType) => switch (eventType.split('/').first) {
      'trade' => 1,
      'crash' => 2,
      'event' => 3,
      _ => 4,
    };

Uint8List encode(int type, int timestampMs, int sequence, Uint8List payload) {
  final buf = Uint8List(headerLen + payload.length + 4);
  final view = ByteData.sublistView(buf);
  view.setUint32(0, magic, Endian.little);
  buf[4] = version;
  buf[5] = type;
  view.setUint64(6, timestampMs, Endian.little);
  view.setUint64(14, sequence, Endian.little);
  view.setUint32(22, payload.length, Endian.little);
  buf.setAll(headerLen, payload);
  view.setUint32(headerLen + payload.length,
      crc32(Uint8List.sublistView(buf, 0, headerLen + payload.length)),
      Endian.little);
  return buf;
}

class Record {
  Record(this.recordType, this.sequence, this.payload, this.endOffset);
  final int recordType;
  final int sequence;
  final Uint8List payload;

  /// Offset byte ngay sau record này trong file.
  final int endOffset;
}

/// Đọc tuần tự record từ [offset]. Trả về `null` khi hết dữ liệu hợp lệ —
/// EOF, magic/version sai, payload cụt, hoặc CRC lệch (Storage Spec §6, §22).
Record? readRecord(RandomAccessFile f, int offset) {
  f.setPositionSync(offset);
  final header = f.readSync(headerLen);
  if (header.length < headerLen) return null;

  final view = ByteData.sublistView(header);
  if (view.getUint32(0, Endian.little) != magic || header[4] != version) {
    return null;
  }
  final type = header[5];
  final sequence = view.getUint64(14, Endian.little);
  final len = view.getUint32(22, Endian.little);

  final payload = f.readSync(len);
  if (payload.length < len) return null; // ghi dở khi crash
  final crcBytes = f.readSync(4);
  if (crcBytes.length < 4) return null;

  if (crc32(header + payload) !=
      ByteData.sublistView(crcBytes).getUint32(0, Endian.little)) {
    return null;
  }
  return Record(type, sequence, payload, offset + headerLen + len + 4);
}

/// Crash recovery (Storage Spec §15, §22): quét từ đầu file, cắt bỏ phần đuôi
/// không hợp lệ. Các record trước đó giữ nguyên.
void recover(File file) {
  final f = file.openSync(mode: FileMode.append);
  try {
    final fileLen = f.lengthSync();
    var validEnd = 0;
    for (var rec = readRecord(f, 0); rec != null;) {
      validEnd = rec.endOffset;
      rec = readRecord(f, validEnd);
    }
    if (validEnd < fileLen) {
      f.truncateSync(validEnd);
      f.flushSync();
    }
  } finally {
    f.closeSync();
  }
}
