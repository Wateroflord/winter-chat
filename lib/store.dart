import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import 'api.dart';
import 'settings.dart';

/// Список чатов и активных звонков, обновляется в реальном времени.
class Store extends ChangeNotifier {
  Store._();
  static final Store I = Store._();

  List<RecordModel> chats = [];
  final Map<String, RecordModel> calls = {}; // chatId -> запись звонка
  bool loaded = false;
  String? error;
  bool online = true;

  final _incoming = StreamController<RecordModel>.broadcast();

  /// Новые звонки, в которых меня ещё нет.
  Stream<RecordModel> get incomingCalls => _incoming.stream;

  final _newMessages = StreamController<String>.broadcast();

  /// Пришло чужое сообщение (id чата) — для звука.
  Stream<String> get newMessages => _newMessages.stream;

  final List<UnsubscribeFunc> _unsubs = [];
  Timer? _timer;
  Timer? _typingTimer;

  /// Кто сейчас печатает: чат → человек → когда пришёл сигнал.
  final Map<String, Map<String, DateTime>> _typing = {};
  static const typingTtl = Duration(seconds: 6);

  /// Кто печатает в чате прямо сейчас (кроме меня).
  List<String> typingIn(String chatId) {
    final now = DateTime.now();
    final m = _typing[chatId];
    if (m == null) return const [];
    return [
      for (final e in m.entries)
        if (now.difference(e.value) < typingTtl && e.key != Api.I.myId) e.key,
    ];
  }

  void _onTyping(String chat, String user) {
    _typing.putIfAbsent(chat, () => {})[user] = DateTime.now();
    notifyListeners();
    _typingTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      var changed = false;
      for (final m in _typing.values) {
        final before = m.length;
        m.removeWhere((_, t) => now.difference(t) >= typingTtl);
        if (m.length != before) changed = true;
      }
      _typing.removeWhere((_, m) => m.isEmpty);
      if (_typing.isEmpty) {
        _typingTimer?.cancel();
        _typingTimer = null;
      }
      if (changed) notifyListeners();
    });
  }

  PocketBase get _pb => Api.I.pb;

  /// Какой чат сейчас открыт на экране (чтобы не звенеть его сообщениями).
  String? visibleChat;

  // ---------- упоминания: меня позвали через @ник / @все ----------

  static const _kMentions = 'mentions_v1';
  Set<String>? _mentioned;
  Set<String> get _ment => _mentioned ??= (Api.I.prefs.getStringList(_kMentions) ?? const []).toSet();

  bool isMentioned(String chatId) => _ment.contains(chatId);

  void clearMention(String chatId) {
    if (_ment.remove(chatId)) {
      Api.I.prefs.setStringList(_kMentions, _ment.toList());
      notifyListeners();
    }
  }

  /// В последнем сообщении чата позвали меня (по нику или всех).
  static bool mentionsMe(RecordModel chat) {
    final m = chat.data['last_mention'];
    if (m is! List || !Api.I.loggedIn) return false;
    return m.contains('all') || m.contains(Api.I.myId);
  }

  int _gen = 0;

  Future<void> start() async {
    final gen = ++_gen;
    await _stop();
    await refresh();
    // Пока ждали ответа, могли переключиться на запасной адрес и запуститься заново.
    if (gen != _gen) return;
    await _subscribe();
    if (gen != _gen) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => refresh(silent: true));
  }

  Future<void> stop() {
    _gen++;
    return _stop();
  }

  Future<void> _stop() async {
    _timer?.cancel();
    _timer = null;
    for (final u in _unsubs) {
      try {
        await u();
      } catch (_) {}
    }
    _unsubs.clear();
    chats = [];
    calls.clear();
    loaded = false;
    error = null;
  }

  Future<void> refresh({bool silent = false}) async {
    try {
      final list = await _pb.collection('chats').getFullList(sort: '-last_at,-created');
      chats = list;
      _sort();
      final cl = await _pb.collection('calls').getFullList();
      calls
        ..clear()
        ..addEntries(cl.map((c) => MapEntry(c.getStringValue('chat'), c)));
      error = null;
      online = true;
      loaded = true;
    } catch (e) {
      online = false;
      if (!silent || !loaded) error = Api.errorText(e, fallback: 'Нет связи с сервером');
      loaded = true;
      notifyListeners();
      // Основной адрес не отвечает — пробуем запасные (например, через Winter VPN).
      if (await Api.I.failover()) {
        await start();
      }
      return;
    }
    notifyListeners();
  }

  Future<void> _subscribe() async {
    try {
      _unsubs.add(await _pb.collection('chats').subscribe('*', (e) {
        final r = e.record;
        if (r == null) return;
        final before = chat(r.id);
        chats.removeWhere((c) => c.id == r.id);
        if (e.action != 'delete' && r.getListValue<String>('members').contains(Api.I.myId)) {
          chats.add(r);
          final at = r.getStringValue('last_at');
          final was = before?.getStringValue('last_at') ?? '';
          if (at.isNotEmpty && at.compareTo(was) > 0 && r.getStringValue('last_author') != Api.I.myId) {
            _typing[r.id]?.remove(r.getStringValue('last_author')); // написал — уже не печатает
            if (mentionsMe(r) && visibleChat != r.id && _ment.add(r.id)) {
              Api.I.prefs.setStringList(_kMentions, _ment.toList());
            }
            _newMessages.add(r.id);
          }
        }
        _sort();
        notifyListeners();
      }));
      _unsubs.add(await _pb.collection('calls').subscribe('*', (e) {
        final r = e.record;
        if (r == null) return;
        final chatId = r.getStringValue('chat');
        if (e.action == 'delete') {
          calls.remove(chatId);
        } else {
          final before = calls[chatId];
          calls[chatId] = r;
          final parts = r.getListValue<String>('participants');
          if (before == null && parts.isNotEmpty && !parts.contains(Api.I.myId)) {
            _incoming.add(r);
          }
        }
        notifyListeners();
      }));
      // «Печатает…» — сервер присылает только участникам чата.
      try {
        _unsubs.add(await _pb.realtime.subscribe('wc_typing', (e) {
          try {
            final j = jsonDecode(e.data);
            if (j is Map && j['chat'] is String && j['user'] is String) _onTyping(j['chat'] as String, j['user'] as String);
          } catch (_) {}
        }));
      } catch (_) {}
      _unsubs.add(await _pb.collection('users').subscribe('*', (e) {
        final r = e.record;
        if (r == null) return;
        if (e.action == 'delete') {
          Api.I.users.remove(r.id);
        } else {
          Api.I.users[r.id] = r;
        }
        notifyListeners();
      }));
      _pb.realtime.onDisconnect = (_) {
        online = false;
        notifyListeners();
      };
    } catch (_) {
      // realtime переподключится сам; список обновится по таймеру
    }
  }

  void _sort() {
    // Группа поднимается и от сообщений в её каналах.
    final latest = <String, String>{};
    for (final c in chats) {
      final p = c.getStringValue('parent');
      if (p.isEmpty || c.getStringValue('kind') == 'voice') continue;
      final a = c.getStringValue('last_at');
      if (a.compareTo(latest[p] ?? '') > 0) latest[p] = a;
    }
    String key(RecordModel c) {
      var a = c.getStringValue('last_at');
      if (a.isEmpty) a = c.getStringValue('created');
      final k = latest[c.id];
      return k != null && k.compareTo(a) > 0 ? k : a;
    }

    // Закреплённые — сверху, внутри групп — по последнему сообщению.
    chats.sort((a, b) {
      final pa = Settings.I.isPinned(a.id), pb = Settings.I.isPinned(b.id);
      if (pa != pb) return pa ? -1 : 1;
      return key(b).compareTo(key(a));
    });
  }

  /// Пересортировать (после закрепления чата).
  void resort() {
    _sort();
    notifyListeners();
  }

  RecordModel? chat(String id) {
    for (final c in chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<String> callParticipants(String chatId) => calls[chatId]?.getListValue<String>('participants') ?? const [];

  void replaceChat(RecordModel r) {
    chats.removeWhere((c) => c.id == r.id);
    chats.add(r);
    _sort();
    notifyListeners();
  }

  /// Перерисовать список (например, после прочтения чата).
  void ping() => notifyListeners();

  void removeChat(String id) {
    chats.removeWhere((c) => c.id == id);
    notifyListeners();
  }

  /// Найти или создать личный чат с человеком.
  Future<RecordModel> openDirect(String userId) async {
    for (final c in chats) {
      if (!c.getBoolValue('is_group')) {
        final m = c.getListValue<String>('members');
        if (m.length == 2 && m.contains(userId) && m.contains(Api.I.myId)) return c;
      }
    }
    try {
      final r = await _pb.collection('chats').create(body: {
        'is_group': false,
        'members': [Api.I.myId, userId],
      });
      replaceChat(r);
      return r;
    } on ClientException catch (e) {
      final data = e.response['data'];
      final item = data is Map ? data['existing'] : null;
      final existing = item is Map ? item['code'] : null;
      if (existing is String && existing.isNotEmpty) {
        final r = await _pb.collection('chats').getOne(existing);
        replaceChat(r);
        return r;
      }
      throw Api.errorText(e, fallback: 'Не удалось создать чат');
    }
  }

  Future<RecordModel> createGroup(String name, List<String> members) async {
    try {
      final r = await _pb.collection('chats').create(body: {
        'is_group': true,
        'name': name.trim(),
        'members': {Api.I.myId, ...members}.toList(),
      });
      replaceChat(r);
      return r;
    } catch (e) {
      throw Api.errorText(e, fallback: 'Не удалось создать группу');
    }
  }
}
