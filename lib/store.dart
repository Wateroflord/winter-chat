import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import 'api.dart';

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

  final List<UnsubscribeFunc> _unsubs = [];
  Timer? _timer;

  PocketBase get _pb => Api.I.pb;

  Future<void> start() async {
    await stop();
    await refresh();
    await _subscribe();
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => refresh(silent: true));
  }

  Future<void> stop() async {
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
    }
    notifyListeners();
  }

  Future<void> _subscribe() async {
    try {
      _unsubs.add(await _pb.collection('chats').subscribe('*', (e) {
        final r = e.record;
        if (r == null) return;
        chats.removeWhere((c) => c.id == r.id);
        if (e.action != 'delete' && r.getListValue<String>('members').contains(Api.I.myId)) {
          chats.add(r);
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
    String key(RecordModel c) {
      final a = c.getStringValue('last_at');
      return a.isNotEmpty ? a : c.getStringValue('created');
    }

    chats.sort((a, b) => key(b).compareTo(key(a)));
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
