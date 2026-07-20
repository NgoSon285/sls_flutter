import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'blf.dart' as blf;
import 'crypto.dart' as crypto;

/// Storage Specification §10: con trỏ upload. `offset` là vị trí byte ngay sau
/// record cuối đã upload thành công.
class Checkpoint {
  const Checkpoint(this.file, this.offset);
  final String file;
  final int offset;

  Map<String, dynamic> toJson() => {'file': file, 'offset': offset};
}

/// Giới hạn lưu trữ (Storage Spec §11, §19–§20).
/// ponytail: hằng số mặc định theo spec, đưa vào Config khi có nhu cầu tùy chỉnh thật.
class Limits {
  const Limits({
    this.maxFileSize = 64 * 1024 * 1024,
    this.maxTotalSize = 512 * 1024 * 1024,
    this.retentionDays = 7,
  });
  final int maxFileSize;
  final int maxTotalSize;
  final int retentionDays;
}

/// Định dạng lưu trữ (Storage Spec §5):
/// development = JSONL plain, staging/production = BLF (+ mã hoá payload nếu có key).
class Storage {
  Storage._(this._root, this.jsonl, this._key, this._limits);

  /// [key] null = BLF không mã hoá; chỉ dùng khi [jsonl] false.
  factory Storage.open(
    String root, {
    required bool jsonl,
    Uint8List? key,
    Limits limits = const Limits(),
  }) {
    Directory('$root/logs').createSync(recursive: true);
    Directory('$root/metadata').createSync(recursive: true);
    final s = Storage._(root, jsonl, key, limits);
    // Crash recovery khi khởi động (Storage Spec §15): chỉ file BLF cuối cùng
    final blfFiles = s._listFiles().where((f) => f.endsWith('.blf'));
    if (blfFiles.isNotEmpty) {
      blf.recover(File('$root/logs/${blfFiles.last}'));
    }
    s._cleanup();
    return s;
  }

  final String _root;
  final bool jsonl;
  final Uint8List? _key;
  final Limits _limits;

  /// Số record đã bỏ vì không giải mã/parse được, tính từ lần [takeDropped] gần nhất.
  ///
  /// ponytail: đếm trong RAM, mất nếu app tắt trước lúc sync. Ceiling: crash ngay
  /// sau khi đọc phải file hỏng thì con số không tới được server. Ghi xuống
  /// metadata/dropped.meta nếu cần đếm chính xác tuyệt đối.
  int _dropped = 0;

  /// Đọc và reset. Logger gọi lúc sync để biến con số thành event chẩn đoán.
  int takeDropped() {
    final n = _dropped;
    _dropped = 0;
    return n;
  }

  String get _ext => jsonl ? 'jsonl' : 'blf';
  File get _checkpointFile => File('$_root/metadata/checkpoint.meta');

  Checkpoint get checkpoint {
    try {
      final m = jsonDecode(_checkpointFile.readAsStringSync());
      return Checkpoint(m['file'] as String, m['offset'] as int);
    } catch (_) {
      return const Checkpoint('', 0);
    }
  }

  void saveCheckpoint(Checkpoint cp) {
    // Atomic write: ghi file tạm rồi rename (Storage Spec §10) — checkpoint sai
    // thì mất log, còn mất checkpoint chỉ gây gửi lại (server idempotent).
    final tmp = File('$_root/metadata/checkpoint.tmp')
      ..writeAsStringSync(jsonEncode(cp.toJson()), flush: true);
    tmp.renameSync(_checkpointFile.path);
    // Checkpoint chỉ tiến sau khi upload thành công → thời điểm tốt để dọn dẹp
    _cleanup();
  }

  List<String> _listFiles() => Directory('$_root/logs')
      .listSync()
      .map((e) => e.uri.pathSegments.last)
      .where((n) => n.endsWith('.jsonl') || n.endsWith('.blf'))
      .toList()
    ..sort();

  /// File đang ghi: rotate theo ngày + theo dung lượng (Storage Spec §11).
  /// Tên `events-YYYYMMDD-NNNN.ext`, NNNN tăng khi file vượt maxFileSize.
  String _activeFile() {
    final d = DateTime.now().toUtc();
    final prefix = 'events-${d.year}${_p2(d.month)}${_p2(d.day)}-';
    final today = _listFiles().where((f) => f.startsWith(prefix));
    if (today.isEmpty) return '${prefix}0001.$_ext';

    final last = today.last;
    if (File('$_root/logs/$last').lengthSync() < _limits.maxFileSize) {
      return last;
    }
    final seq =
        int.tryParse(last.substring(prefix.length, prefix.length + 4)) ?? 0;
    return '$prefix${(seq + 1).toString().padLeft(4, '0')}.$_ext';
  }

  /// Retention + FIFO (Storage Spec §19–§20). Chỉ xoá file đã sync xong
  /// (đứng trước checkpoint) — không bao giờ xoá log chưa upload.
  void _cleanup() {
    final cp = checkpoint;
    if (cp.file.isEmpty) return;
    final files = _listFiles();
    final synced = files.where((f) => f.compareTo(cp.file) < 0).toList();

    final cutoff =
        DateTime.now().subtract(Duration(days: _limits.retentionDays));
    for (final f in synced.toList()) {
      final file = File('$_root/logs/$f');
      if (!file.lastModifiedSync().isAfter(cutoff)) {
        file.deleteSync();
        synced.remove(f);
        files.remove(f);
      }
    }

    var total = files.fold(0, (t, f) => t + File('$_root/logs/$f').lengthSync());
    for (final f in synced) {
      if (total <= _limits.maxTotalSize) break;
      final file = File('$_root/logs/$f');
      total -= file.lengthSync();
      file.deleteSync();
    }
  }

  void append(Map<String, dynamic> event) {
    final f = File('$_root/logs/${_activeFile()}')
        .openSync(mode: FileMode.writeOnlyAppend);
    try {
      if (jsonl) {
        f.writeStringSync('${jsonEncode(event)}\n');
      } else {
        var payload = Uint8List.fromList(utf8.encode(jsonEncode(event)));
        if (_key != null) payload = crypto.encrypt(_key, payload);
        f.writeFromSync(blf.encode(
          blf.recordType(event['event_type'] as String),
          DateTime.now().millisecondsSinceEpoch,
          event['sequence'] as int,
          payload,
        ));
      }
      f.flushSync();
    } finally {
      f.closeSync();
    }
  }

  /// Đọc tuần tự từ checkpoint (Storage Spec §17). Trả về batch + checkpoint mới;
  /// caller chỉ save checkpoint sau khi upload thành công.
  (List<dynamic>, Checkpoint)? readBatch(int max) {
    final files = _listFiles();
    final cp = checkpoint;
    if (cp.file.isEmpty && files.isEmpty) return null;

    var file = cp.file.isEmpty ? files.first : cp.file;
    var offset = cp.file.isEmpty ? 0 : cp.offset;

    while (true) {
      final path = '$_root/logs/$file';
      final (events, end) = file.endsWith('.blf')
          ? _readBlf(path, offset, max)
          : _readJsonl(path, offset, max);
      if (events.isNotEmpty) return (events, Checkpoint(file, end));

      // File đã đọc hết: chuyển sang file kế tiếp nếu có
      final next = files.where((f) => f.compareTo(file) > 0);
      if (next.isEmpty) return null;
      file = next.first;
      offset = 0;
    }
  }

  (List<dynamic>, int) _readBlf(String path, int offset, int max) {
    final f = File(path).openSync();
    try {
      final events = [];
      var pos = offset;
      while (events.length < max) {
        final rec = blf.readRecord(f, pos);
        if (rec == null) break;
        pos = rec.endOffset;
        final plain =
            _key != null ? crypto.decrypt(_key, rec.payload) : rec.payload;
        try {
          events.add(jsonDecode(utf8.decode(plain)));
        } catch (_) {
          // Bỏ record hỏng để không chặn hàng đợi — nhưng ĐẾM lại. Mất log âm
          // thầm là thứ tệ nhất trong hệ thống hứa không mất log; Logger đọc con
          // số này rồi gửi lên thành event chẩn đoán.
          _dropped++;
        }
      }
      return (events, pos);
    } finally {
      f.closeSync();
    }
  }

  (List<dynamic>, int) _readJsonl(String path, int offset, int max) {
    final f = File(path).openSync();
    try {
      // Đọc phần còn lại rồi tách dòng: file rotate ở 64MB nên bounded.
      f.setPositionSync(offset);
      final rest = utf8.decode(f.readSync(f.lengthSync() - offset));
      final events = [];
      var pos = offset;
      final lines = rest.split('\n');
      // Phần sau '\n' cuối cùng: rỗng, hoặc là dòng đang ghi dở lúc crash. Chưa
      // tính nó — nếu tính thì record đó vừa bị bỏ vừa bị nhảy qua vĩnh viễn
      // (Storage Spec §22), và mỗi lần crash lại báo nhầm một record hỏng.
      lines.removeLast();
      for (final line in lines) {
        if (events.length >= max) break;
        pos += utf8.encode(line).length + 1;
        if (line.isEmpty) continue;
        try {
          events.add(jsonDecode(line));
        } catch (_) {
          _dropped++;
        }
      }
      return (events, pos);
    } finally {
      f.closeSync();
    }
  }
}

String _p2(int n) => n.toString().padLeft(2, '0');
