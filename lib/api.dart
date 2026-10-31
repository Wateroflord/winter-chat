import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Связь с сервером Winter Chat (PocketBase на ноутбуке друга).
class Api extends ChangeNotifier {
  Api._();
  static final Api I = Api._();

  static const defaultPort = 8090;

  late SharedPreferences prefs;
  PocketBase? _pb;
  String serverUrl = '';

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
    try {
      final res = await http.get(Uri.parse('$url/api/wc/info')).timeout(const Duration(seconds: 8));
      final j = jsonDecode(res.body);
      if (j is! Map || j['app'] != 'winter-chat') throw 'not winter';
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

  /// Название чата: для личного — имя собеседника.
  String chatTitle(RecordModel chat) {
    if (chat.getBoolValue('is_group')) {
      final n = chat.getStringValue('name').trim();
      return n.isNotEmpty ? n : 'Группа';
    }
    final other = otherMember(chat);
    return other == null ? 'Заметки' : nameOf(other);
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

  Future<({String url, String token})> callToken(String chatId) async {
    try {
      final res = await pb.send('/api/wc/call-token', method: 'POST', body: {'chat': chatId});
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
      'passwordConfirm' => 'Пароль',
      'name' => 'Имя',
      'identity' => 'Логин',
      'code' => '',
      'existing' => '',
      _ => field,
    };
    final m = switch (code) {
      'validation_not_unique' => 'уже занят',
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
