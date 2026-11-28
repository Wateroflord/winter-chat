import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import 'api.dart';

/// Исходящие сообщения: полоска загрузки для файлов, отправка без интернета
/// (уйдёт само, когда связь вернётся) и черновики.

class OutFile {
  OutFile({required this.name, required this.size, this.path, this.bytes});
  final String name;
  final int size;
  final String? path;
  final Uint8List? bytes; // только пока приложение открыто (не сохраняется)

  Map<String, dynamic> toJson() => {'name': name, 'size': size, if (path != null) 'path': path};
  static OutFile fromJson(Map j) => OutFile(name: '${j['name']}', size: (j['size'] as num?)?.toInt() ?? 0, path: j['path'] as String?);
}

enum OutState { sending, waiting, failed }

class OutItem {
  OutItem({
    required this.id,
    required this.chatId,
    required this.text,
    this.replyTo,
    this.extra = const {},
    this.files = const [],
    required this.created,
    this.deleteAfter = false,
  });
  final String id;
  final String chatId;
  final String text;
  final String? replyTo;

  /// Опрос, стикер, GIF — то, что уходит в теле сообщения как есть.
  final Map<String, dynamic> extra;
  final List<OutFile> files;
  final DateTime created;

  /// Удалить файлы с устройства после отправки (голосовые — это временные файлы).
  final bool deleteAfter;

  OutState state = OutState.waiting;
  int sentBytes = 0;
  String? error;
  int attempts = 0;
  DateTime nextTry = DateTime(2000);
  bool _cancel = false;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);
  double get progress => totalBytes == 0 ? 0 : (sentBytes / totalBytes).clamp(0, 1).toDouble();

  Map<String, dynamic> toJson() => {
        'id': id,
        'chat': chatId,
        'text': text,
        if (replyTo != null) 'reply': replyTo,
        if (extra.isNotEmpty) 'extra': extra,
        'files': [for (final f in files) f.toJson()],
        'created': created.toIso8601String(),
        if (deleteAfter) 'del': true,
        if (state == OutState.failed) 'error': error ?? 'Не отправилось',
      };

  static OutItem? fromJson(Map j) {
    try {
      final it = OutItem(
        id: '${j['id']}',
        chatId: '${j['chat']}',
        text: '${j['text'] ?? ''}',
        replyTo: j['reply'] as String?,
        extra: Map<String, dynamic>.from((j['extra'] as Map?) ?? const {}),
        files: [for (final f in (j['files'] as List? ?? const []).whereType<Map>()) OutFile.fromJson(f)],
        created: DateTime.tryParse('${j['created']}') ?? DateTime.now(),
        deleteAfter: j['del'] == true,
      );
      if (j['error'] is String) {
        it.state = OutState.failed;
        it.error = j['error'] as String;
      }
      return it;
    } catch (_) {
      return null;
    }
  }
}

class Outbox extends ChangeNotifier {
  Outbox._();
  static final Outbox I = Outbox._();

  static const _kItems = 'outbox_v1';
  final List<OutItem> items = [];
  final _sent = StreamController<RecordModel>.broadcast();

  /// Сообщение ушло на сервер — его можно показать в чате.
  Stream<RecordModel> get sent => _sent.stream;

  Timer? _timer;
  bool _busy = false;
  bool _loaded = false;
  DateTime _lastNotify = DateTime(2000);

  List<OutItem> pendingFor(String chatId) => items.where((i) => i.chatId == chatId).toList();

  void load() {
    if (_loaded) return;
    _loaded = true;
    final raw = Api.I.prefs.getString(_kItems);
    if (raw != null) {
      try {
        for (final j in (jsonDecode(raw) as List).whereType<Map>()) {
          final it = OutItem.fromJson(j);
          if (it == null) continue;
          // Файла уже нет на устройстве — отправить его не выйдет.
          if (it.files.any((f) => f.path == null || !File(f.path!).existsSync())) {
            it.state = OutState.failed;
            it.error = 'Файл пропал с устройства';
          }
          items.add(it);
        }
      } catch (_) {}
    }
    _timer ??= Timer.periodic(const Duration(seconds: 4), (_) => pump());
    pump();
  }

  void _save() {
    // Байты из памяти не сохраняем: такие сообщения после перезапуска не восстановить.
    final keep = items.where((i) => i.files.every((f) => f.path != null)).toList();
    Api.I.prefs.setString(_kItems, jsonEncode([for (final i in keep) i.toJson()]));
  }

  static String _newId() => 'out_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';

  /// Поставить сообщение в очередь. Больше 10 файлов — несколько сообщений.
  void add({
    required String chatId,
    String text = '',
    String? replyTo,
    Map<String, dynamic> extra = const {},
    List<OutFile> files = const [],
    bool deleteAfter = false,
  }) {
    load();
    var rest = files;
    var first = true;
    do {
      final batch = rest.take(10).toList();
      rest = rest.skip(10).toList();
      items.add(OutItem(
        id: _newId(),
        chatId: chatId,
        text: first ? text : '',
        replyTo: first ? replyTo : null,
        extra: first ? extra : const {},
        files: batch,
        created: DateTime.now(),
        deleteAfter: deleteAfter,
      ));
      first = false;
    } while (rest.isNotEmpty);
    _save();
    notifyListeners();
    pump();
  }

  void retry(OutItem it) {
    it.state = OutState.waiting;
    it.error = null;
    it.nextTry = DateTime(2000);
    notifyListeners();
    pump();
  }

  void remove(OutItem it) {
    it._cancel = true;
    items.remove(it);
    _save();
    notifyListeners();
  }

  /// Попробовать отправить всё, что ждёт (вызывается по таймеру и когда сеть вернулась).
  Future<void> pump({bool now = false}) async {
    if (_busy || !Api.I.loggedIn) return;
    _busy = true;
    try {
      while (true) {
        final t = DateTime.now();
        final next = items.where((i) => i.state == OutState.waiting && (now || !i.nextTry.isAfter(t))).firstOrNull;
        if (next == null) break;
        final ok = await _send(next);
        if (!ok && next.state == OutState.waiting) break; // нет связи — подождём
      }
    } finally {
      _busy = false;
    }
  }

  void _tick() {
    final t = DateTime.now();
    if (t.difference(_lastNotify) > const Duration(milliseconds: 120)) {
      _lastNotify = t;
      notifyListeners();
    }
  }

  Future<bool> _send(OutItem it) async {
    it.state = OutState.sending;
    it.sentBytes = 0;
    it._cancel = false;
    it.attempts++;
    notifyListeners();
    try {
      final multipart = <http.MultipartFile>[];
      for (final f in it.files) {
        Stream<List<int>> src;
        int len;
        if (f.path != null) {
          final file = File(f.path!);
          len = await file.length();
          src = file.openRead();
        } else if (f.bytes != null) {
          len = f.bytes!.length;
          src = Stream.fromIterable([for (var o = 0; o < len; o += 64 << 10) f.bytes!.sublist(o, min(o + (64 << 10), len))]);
        } else {
          throw 'Файл «${f.name}» пропал';
        }
        final counted = src.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(handleData: (chunk, sink) {
          if (it._cancel) {
            sink.addError('отменено');
            return;
          }
          it.sentBytes += chunk.length;
          _tick();
          sink.add(chunk);
        }));
        multipart.add(http.MultipartFile('files', counted, len, filename: f.name));
      }
      final rec = await Api.I.pb.collection('messages').create(
        body: {
          'chat': it.chatId,
          'text': it.text,
          if (it.replyTo != null) 'reply_to': it.replyTo,
          ...it.extra,
        },
        files: multipart,
        expand: Api.I.messageExpand,
      );
      items.remove(it);
      _save();
      if (it.deleteAfter) {
        for (final f in it.files) {
          try {
            if (f.path != null) File(f.path!).deleteSync();
          } catch (_) {}
        }
      }
      _sent.add(rec);
      notifyListeners();
      return true;
    } catch (e) {
      if (!items.contains(it)) return true; // отменили
      final offline = e is ClientException && e.statusCode == 0 || e is SocketException || e is TimeoutException;
      if (offline) {
        it.state = OutState.waiting;
        final wait = min(60, 3 * (1 << min(it.attempts, 5)));
        it.nextTry = DateTime.now().add(Duration(seconds: wait));
      } else {
        it.state = OutState.failed;
        it.error = Api.errorText(e, fallback: 'Не отправилось');
      }
      _save();
      notifyListeners();
      return false;
    }
  }

  // ---------- черновики ----------

  static String draft(String chatId) => Api.I.prefs.getString('draft_$chatId') ?? '';

  static void setDraft(String chatId, String text) {
    if (text.trim().isEmpty) {
      Api.I.prefs.remove('draft_$chatId');
    } else {
      Api.I.prefs.setString('draft_$chatId', text);
    }
  }
}
