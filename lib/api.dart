import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart';
import 'store.dart';
import 'util.dart';

/// Связь с сервером Winter Chat (PocketBase на ноутбуке друга).
class Api extends ChangeNotifier {
  Api._();
  static final Api I = Api._();

  static const defaultPort = 8090;

  late SharedPreferences prefs;
  PocketBase? _pb;
  String serverUrl = '';

  /// Адрес, который ввёл пользователь при входе (serverUrl может временно
  /// переключиться на запасной — например, адрес в Winter VPN).
  String primaryUrl = '';

  /// Запасные адреса того же сервера (в Winter VPN, Radmin и т.п.), их сообщает сам сервер.
  List<String> altUrls = [];
  String serverId = '';

  /// Все пользователи сервера (для имён и аватарок).
  final Map<String, RecordModel> users = {};

  PocketBase get pb => _pb!;
  bool get hasClient => _pb != null;
  bool get loggedIn => _pb != null && _pb!.authStore.isValid && _pb!.authStore.record != null;
  RecordModel get me => _pb!.authStore.record!;
  String get myId => me.id;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString('server') ?? '';
    primaryUrl = prefs.getString('server_primary') ?? serverUrl;
    altUrls = prefs.getStringList('server_alts') ?? [];
    serverId = prefs.getString('server_id') ?? '';
    if (serverUrl.isNotEmpty) _makeClient();
  }

  void _makeClient() {
    _pb?.realtime.unsubscribe();
    final store = AsyncAuthStore(
      save: (data) async => prefs.setString('auth', data),
      initial: prefs.getString('auth'),
      clear: () async => prefs.remove('auth'),
    );
    _pb = PocketBase(serverUrl, authStore: store, lang: 'ru-RU');
  }

  /// «192.168.1.5» → «http://192.168.1.5:8090»
  static String normalizeUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return s;
    final hasPort = RegExp(r':\d+$').hasMatch(uri.authority);
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: hasPort ? uri.port : (uri.scheme == 'https' ? 443 : defaultPort),
    ).toString().replaceAll(RegExp(r'/$'), '');
  }

  Future<void> _useServer(String input) async {
    final url = normalizeUrl(input);
    if (url.isEmpty) throw 'Введи адрес сервера';
    Map? info;
    try {
      final res = await http.get(Uri.parse('$url/api/wc/info')).timeout(const Duration(seconds: 8));
      final j = jsonDecode(res.body);
      if (j is! Map || j['app'] != 'winter-chat') throw 'not winter';
      info = j;
    } on TimeoutException {
      throw 'Сервер не отвечает. Проверь адрес и что сервер запущен на ноутбуке.';
    } catch (e) {
      if (e is String && e != 'not winter') rethrow;
      if (e == 'not winter') throw 'По этому адресу не Winter Chat сервер.';
      throw 'Не удалось подключиться к $url. Проверь адрес и что сервер запущен.';
    }
    if (url != serverUrl || _pb == null) {
      serverUrl = url;
      await prefs.setString('server', url);
      await prefs.remove('auth');
      _makeClient();
    }
    primaryUrl = url;
    await prefs.setString('server_primary', url);
    await _saveInfo(info);
  }

  // ---------- запасные адреса (Winter VPN) ----------

  Future<void> _saveInfo(Map? j) async {
    if (j == null) return;
    final id = '${j['id'] ?? ''}';
    final port = int.tryParse('${j['port'] ?? ''}') ?? defaultPort;
    final alts = <String>[];
    final list = j['addresses'];
    if (list is List) {
      for (final a in list.whereType<Map>()) {
        final ip = '${a['ip'] ?? ''}';
        if (ip.isNotEmpty) alts.add('http://$ip:$port');
      }
    }
    serverId = id;
    altUrls = alts;
    await prefs.setString('server_id', id);
    await prefs.setStringList('server_alts', alts);
  }

  /// Обновить список запасных адресов с сервера (тихо).
  Future<void> refreshInfo() async {
    if (serverUrl.isEmpty) return;
    try {
      final res = await http.get(Uri.parse('$serverUrl/api/wc/info')).timeout(const Duration(seconds: 6));
      final j = jsonDecode(res.body);
      if (j is Map && j['app'] == 'winter-chat') {
        final id = '${j['id'] ?? ''}';
        if (serverId.isNotEmpty && id.isNotEmpty && id != serverId) return; // другой сервер — не трогаем
        await _saveInfo(j);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Все известные адреса этого сервера: основной + запасные.
  List<String> get knownUrls => {primaryUrl, ...altUrls, serverUrl}.where((u) => u.isNotEmpty).toList();

  Future<bool> isSameServer(String url) async {
    try {
      final res = await http.get(Uri.parse('$url/api/wc/info')).timeout(const Duration(seconds: 4));
      final j = jsonDecode(res.body);
      if (j is! Map || j['app'] != 'winter-chat') return false;
      final id = '${j['id'] ?? ''}';
      return serverId.isEmpty || id.isEmpty || id == serverId;
    } catch (_) {
      return false;
    }
  }

  /// Переключиться на другой адрес того же сервера, не выходя из аккаунта.
  Future<void> switchTo(String url) async {
    if (url == serverUrl) return;
    serverUrl = url;
    await prefs.setString('server', url);
    _makeClient();
    notifyListeners();
  }

  bool _failing = false;
  DateTime _lastFailover = DateTime(2000);

  /// Сервер не отвечает — попробовать запасные адреса (например, через Winter VPN).
  /// true — переключились на работающий адрес.
  Future<bool> failover() async {
    final now = DateTime.now();
    if (_failing || now.difference(_lastFailover) < const Duration(seconds: 20)) return false;
    _failing = true;
    _lastFailover = now;
    try {
      final cands = knownUrls.where((u) => u != serverUrl).toList();
      for (final u in cands) {
        if (await isSameServer(u)) {
          await switchTo(u);
          return true;
        }
      }
      return false;
    } finally {
      _failing = false;
    }
  }

  // ---------- аккаунт ----------

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final username = me.getStringValue('username');
    try {
      await pb.collection('users').update(myId, body: {
        'oldPassword': oldPassword,
        'password': newPassword,
        'passwordConfirm': newPassword,
      });
    } catch (e) {
      throw errorText(e, fallback: 'Не удалось сменить пароль');
    }
    // После смены пароля старый вход перестаёт действовать — входим заново.
    try {
      await pb.collection('users').authWithPassword(username, newPassword);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> login(String server, String username, String password) async {
    await _useServer(server);
    try {
      await pb.collection('users').authWithPassword(username.trim(), password);
    } catch (e) {
      throw errorText(e, fallback: 'Неверный логин или пароль');
    }
    await afterLogin();
  }

  Future<void> register(String server, String username, String name, String password, String invite) async {
    await _useServer(server);
    try {
      await pb.collection('users').create(
        body: {
          'username': username.trim(),
          'name': name.trim(),
          'password': password,
          'passwordConfirm': password,
          'invite': invite.trim(),
        },
        query: {'invite': invite.trim()},
      );
    } catch (e) {
      throw errorText(e, fallback: 'Не удалось зарегистрироваться');
    }
    await login(server, username, password);
  }

  Future<void> afterLogin() async {
    try {
      await pb.collection('users').authRefresh();
    } on ClientException catch (e) {
      // Аккаунт удалён или сервер переустановлен — нужно войти заново.
      if (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404) {
        await logout();
        return;
      }
    }
    try {
      await loadUsers();
    } catch (_) {}
    unawaited(refreshInfo());
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _pb?.realtime.unsubscribe();
    } catch (_) {}
    _pb?.authStore.clear();
    users.clear();
    notifyListeners();
  }

  Future<void> loadUsers() async {
    final list = await pb.collection('users').getFullList(sort: 'name');
    users
      ..clear()
      ..addEntries(list.map((u) => MapEntry(u.id, u)));
    if (loggedIn) users[myId] = users[myId] ?? me;
  }

  Future<RecordModel?> userById(String id) async {
    if (users.containsKey(id)) return users[id];
    try {
      final u = await pb.collection('users').getOne(id);
      users[id] = u;
      return u;
    } catch (_) {
      return null;
    }
  }

  String nameOf(String userId) {
    final u = users[userId];
    if (u == null) return 'Кто-то';
    final n = u.getStringValue('name').trim();
    return n.isNotEmpty ? n : u.getStringValue('username');
  }

  String nameOfRecord(RecordModel u) {
    final n = u.getStringValue('name').trim();
    return n.isNotEmpty ? n : u.getStringValue('username');
  }

  Uri? avatarUrl(String userId, {String thumb = '128x128'}) {
    final u = users[userId];
    if (u == null) return null;
    final f = u.getStringValue('avatar');
    if (f.isEmpty) return null;
    return pb.files.getURL(u, f, thumb: thumb);
  }

  Uri fileUrl(RecordModel rec, String file, {String? thumb, bool download = false}) =>
      pb.files.getURL(rec, file, thumb: thumb, download: download ? true : null);

  /// Цвет профиля (имя в группах, баннер, аватар без фото). null — не выбран.
  Color? profileColor(String userId) => parseHexColor(users[userId]?.getStringValue('color') ?? '');

  /// Статус: эмодзи и текст. null — нет или истёк.
  ({String emoji, String text})? statusOf(String userId) {
    final u = users[userId];
    if (u == null) return null;
    final text = u.getStringValue('status').trim();
    final emoji = u.getStringValue('status_emoji').trim();
    if (text.isEmpty && emoji.isEmpty) return null;
    final until = parseDate(u.getStringValue('status_until'));
    if (until != null && until.isBefore(DateTime.now())) return null;
    return (emoji: emoji, text: text);
  }

  String statusText(String userId) {
    final s = statusOf(userId);
    if (s == null) return '';
    return [s.emoji, s.text].where((e) => e.isNotEmpty).join(' ');
  }

  String bioOf(String userId) => users[userId]?.getStringValue('bio').trim() ?? '';

  Uri? bannerUrl(String userId) {
    final u = users[userId];
    final f = u?.getStringValue('banner') ?? '';
    if (u == null || f.isEmpty) return null;
    return pb.files.getURL(u, f, thumb: '960x0');
  }

  Uri? chatAvatarUrl(RecordModel chat) {
    final f = chat.getStringValue('avatar');
    if (f.isEmpty) return null;
    return pb.files.getURL(chat, f, thumb: '128x128');
  }

  /// Название чата: своё имя (если задано), для личного — имя собеседника.
  /// Канал группы — «#игры» (голосовой — просто название).
  String chatTitle(RecordModel chat) {
    final alias = Settings.I.alias(chat.id);
    if (alias.isNotEmpty) return alias;
    if (chat.getStringValue('parent').isNotEmpty) {
      final n = chat.getStringValue('name').trim();
      return chat.getStringValue('kind') == 'voice' ? n : '#$n';
    }
    if (chat.getBoolValue('is_group')) {
      final n = chat.getStringValue('name').trim();
      return n.isNotEmpty ? n : 'Группа';
    }
    final other = otherMember(chat);
    return other == null ? 'Заметки' : nameOf(other);
  }

  /// Полное название: для канала — «Группа › #игры».
  String chatTitleFull(RecordModel chat) {
    final p = chat.getStringValue('parent');
    if (p.isEmpty) return chatTitle(chat);
    final parent = Store.I.chat(p);
    return parent == null ? chatTitle(chat) : '${chatTitle(parent)} › ${chatTitle(chat)}';
  }

  /// Чат «без звука» (канал — если без звука он сам или его группа).
  bool isMuted(RecordModel chat) {
    if (Settings.I.isMuted(chat.id)) return true;
    final p = chat.getStringValue('parent');
    return p.isNotEmpty && Settings.I.isMuted(p);
  }

  // ---------- опросы, пересылка, GIF ----------

  Future<Map<String, dynamic>> vote(String messageId, List<int> options) async {
    try {
      final res = await pb.send('/api/wc/vote', method: 'POST', body: {'message': messageId, 'options': options});
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw errorText(e, fallback: 'Голос не засчитался — возможно, сервер старый');
    }
  }

  Future<int> forward(String messageId, List<String> chatIds) async {
    try {
      final res = await pb.send('/api/wc/forward', method: 'POST', body: {'message': messageId, 'chats': chatIds});
      return (res is Map ? res['sent'] as int? : null) ?? 0;
    } catch (e) {
      throw errorText(e, fallback: 'Не получилось переслать — возможно, сервер старый');
    }
  }

  /// Поиск GIF через сервер. null — поиск выключен на сервере.
  Future<List<Map<String, dynamic>>?> searchGifs(String q, {int offset = 0}) async {
    try {
      final res = await pb.send('/api/wc/gifs', query: {'q': q, 'offset': offset});
      if (res is! Map || res['enabled'] != true) return null;
      if (res['error'] is String) throw res['error'] as String;
      return [for (final i in (res['items'] as List? ?? const []).whereType<Map>()) Map<String, dynamic>.from(i)];
    } on ClientException catch (e) {
      if (e.statusCode == 404) return null; // старый сервер
      throw errorText(e, fallback: 'GIF не загрузились');
    }
  }

  String? otherMember(RecordModel chat) {
    for (final m in chat.getListValue<String>('members')) {
      if (m != myId) return m;
    }
    return null;
  }

  // ---------- прочитано / непрочитано (хранится на устройстве) ----------

  String lastRead(String chatId) => prefs.getString('read_$chatId') ?? '';

  /// Возвращает true, если отметка изменилась.
  bool markRead(RecordModel chat) {
    final at = chat.getStringValue('last_at');
    if (at.isNotEmpty && at.compareTo(lastRead(chat.id)) > 0) {
      prefs.setString('read_${chat.id}', at);
      return true;
    }
    return false;
  }

  bool isUnread(RecordModel chat) {
    final at = chat.getStringValue('last_at');
    if (at.isEmpty) return false;
    if (chat.getStringValue('last_author') == myId) return false;
    return at.compareTo(lastRead(chat.id)) > 0;
  }

  // ---------- звонки ----------

  // ---------- реакции, «печатает…», «прочитано», «в сети» ----------

  /// Поставить или снять реакцию.
  Future<void> react(String messageId, String emoji) async {
    try {
      await pb.send('/api/wc/react', method: 'POST', body: {'message': messageId, 'emoji': emoji});
    } catch (e) {
      throw errorText(e, fallback: 'Реакция не поставилась — возможно, сервер старый');
    }
  }

  final Map<String, DateTime> _typingSent = {};

  /// Сообщить, что я печатаю (не чаще раза в 3 секунды).
  void typing(String chatId) {
    final now = DateTime.now();
    final last = _typingSent[chatId];
    if (last != null && now.difference(last) < const Duration(seconds: 3)) return;
    _typingSent[chatId] = now;
    pb.send('/api/wc/typing', method: 'POST', body: {'chat': chatId}).catchError((_) => null);
  }

  final Map<String, DateTime> _readSent = {};

  /// Отметить на сервере, что я прочитал чат (для галочек у друзей).
  void readOnServer(RecordModel chat) {
    final mine = readsOf(chat)[myId] ?? '';
    final lastAt = chat.getStringValue('last_at');
    if (lastAt.isEmpty || mine.compareTo(lastAt) >= 0 || chat.getStringValue('last_author') == myId) return;
    final now = DateTime.now();
    final last = _readSent[chat.id];
    if (last != null && now.difference(last) < const Duration(seconds: 3)) return;
    _readSent[chat.id] = now;
    pb.send('/api/wc/read', method: 'POST', body: {'chat': chat.id}).catchError((_) => null);
  }

  /// Кто до какого времени прочитал чат.
  Map<String, String> readsOf(RecordModel chat) {
    final r = chat.data['reads'];
    if (r is! Map) return const {};
    return {for (final e in r.entries) '${e.key}': '${e.value}'};
  }

  /// Прочитал ли кто-то из других участников сообщение, созданное в [created].
  bool readByOthers(RecordModel chat, String created) {
    for (final e in readsOf(chat).entries) {
      if (e.key != myId && e.value.compareTo(created) >= 0) return true;
    }
    return false;
  }

  /// Отметиться «в сети».
  Future<void> ping() async {
    if (!loggedIn || !Settings.I.showOnline) return;
    try {
      await pb.send('/api/wc/ping', method: 'POST');
    } catch (_) {}
  }

  DateTime? lastSeen(String userId) => parseDate(users[userId]?.getStringValue('last_seen') ?? '');

  bool isOnline(String userId) {
    final t = lastSeen(userId);
    return t != null && DateTime.now().difference(t) < const Duration(seconds: 150);
  }

  /// «в сети», «был(а) 5 мин назад», «был(а) вчера в 21:40».
  String lastSeenText(String userId) {
    final t = lastSeen(userId);
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d < const Duration(seconds: 150)) return 'в сети';
    if (d < const Duration(hours: 1)) return 'был(а) ${d.inMinutes} мин назад';
    if (sameDay(t, DateTime.now())) return 'был(а) сегодня в ${hhmm(t)}';
    if (sameDay(t, DateTime.now().subtract(const Duration(days: 1)))) return 'был(а) вчера в ${hhmm(t)}';
    return 'был(а) ${shortTime(t)}';
  }

  Future<({String url, String token})> callToken(String chatId, {bool quiet = false}) async {
    try {
      final res = await pb.send('/api/wc/call-token', method: 'POST', body: {'chat': chatId, if (quiet) 'quiet': true});
      final path = (res['path'] ?? '/lk') as String;
      return (url: '$serverUrl$path', token: res['token'] as String);
    } catch (e) {
      throw errorText(e, fallback: 'Не удалось начать звонок');
    }
  }

  // ---------- ошибки по-русски ----------

  static String errorText(Object e, {String fallback = 'Что-то пошло не так'}) {
    if (e is String) return e;
    if (e is ClientException) {
      if (e.statusCode == 0) return 'Нет связи с сервером. Он запущен?';
      final r = e.response;
      final data = r['data'];
      if (data is Map && data.isNotEmpty) {
        final parts = <String>[];
        data.forEach((key, v) {
          if (key == 'existing') return;
          final code = v is Map ? '${v['code']}' : '';
          final msg = v is Map ? '${v['message']}' : '$v';
          parts.add(_fieldError(key.toString(), code, msg));
        });
        if (parts.isNotEmpty) return parts.join('\n');
      }
      final msg = (r['message'] ?? '').toString();
      if (msg.isNotEmpty && !msg.startsWith('Failed to') && !msg.startsWith('Something went wrong')) return msg;
      if (e.statusCode == 400 || e.statusCode == 401) return fallback;
      if (e.statusCode == 403) return 'Нет доступа';
      if (e.statusCode == 404) return 'Не найдено';
      return fallback;
    }
    return fallback;
  }

  static String _fieldError(String field, String code, String msg) {
    final f = switch (field) {
      'username' => 'Логин',
      'password' => 'Пароль',
      'oldPassword' => 'Старый пароль',
      'passwordConfirm' => 'Пароль',
      'name' => 'Имя',
      'identity' => 'Логин',
      'code' => '',
      'existing' => '',
      _ => field,
    };
    final m = switch (code) {
      'validation_not_unique' => 'уже занят',
      'validation_invalid_old_password' => 'неверный',
      'validation_min_text_constraint' || 'validation_length_out_of_range' => field.startsWith('password')
          ? 'минимум 8 символов'
          : 'слишком короткий (минимум 3 символа)',
      'validation_max_text_constraint' => 'слишком длинный',
      'validation_invalid_format' => 'только латинские буквы, цифры, точка, _ и -',
      'validation_required' => 'обязательно',
      _ => msg,
    };
    return f.isEmpty ? m : '$f: $m';
  }
}
