import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/friends_logic.dart';
import 'settings.dart';

/// Напоминание об игровом вечере за 30 минут — тем, кто нажал «Иду».
///
/// Пока приложение запущено (на ПК — в трее, на Android — со службой «на связи»),
/// проверка идёт раз в минуту. Если приложение на телефоне закрыто — её делает
/// фоновая проверка раз в ~15 минут (bg_notify.dart), так что напомнит за 15–45 минут.
class NightRemind {
  static const kDone = 'night_reminded';
  static const lead = Duration(minutes: 30);
  static final _n = FlutterLocalNotificationsPlugin();
  static Timer? _t;

  static void start() {
    if (!supported) return;
    _t ??= Timer.periodic(const Duration(minutes: 1), (_) => check());
    check();
  }

  static String _pb(DateTime d) => d.toUtc().toIso8601String().replaceFirst('T', ' ');

  /// Мои вечера («Иду»), которые начнутся в ближайший час.
  static Uri query(String server, String myId, DateTime now) =>
      Uri.parse('$server/api/collections/game_nights/records').replace(queryParameters: {
        'filter': "going.id ?= '$myId' && at >= '${_pb(now)}' && at <= '${_pb(now.add(const Duration(hours: 1)))}'",
        'sort': 'at',
        'perPage': '20',
      });

  /// Каким вечерам пора напомнить: до начала не больше [lead], ещё не напоминали.
  static List<({String id, String title, String body})> due(List<Map> items, DateTime now, Set<String> done) {
    final out = <({String id, String title, String body})>[];
    for (final n in items) {
      final id = '${n['id'] ?? ''}';
      final at = DateTime.tryParse('${n['at'] ?? ''}'.replaceFirst(' ', 'T'))?.toLocal();
      if (id.isEmpty || at == null || done.contains(id)) continue;
      final left = at.difference(now);
      if (left.isNegative || left > lead) continue;
      final going = (n['going'] as List?)?.length ?? 0;
      final mins = left.inMinutes;
      out.add((
        id: id,
        title: '🎮 ${mins <= 1 ? 'Сейчас' : 'Через $mins мин'}: ${n['game'] ?? 'игра'}',
        body: '${nightWhen(at, now)} · идут: $going. ${'${n['note'] ?? ''}'.trim().isEmpty ? 'Заходи!' : '${n['note']}'}',
      ));
    }
    return out;
  }

  static bool _busy = false;

  /// [background] — вызов из фоновой задачи Android (уведомления надо подготовить заново).
  static Future<void> check({bool background = false}) async {
    if (_busy) return;
    _busy = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      if (!(p.getBool(Settings.kNotify) ?? true) || Settings.dndActive(p)) return;
      final server = p.getString('server') ?? '';
      final auth = p.getString('auth');
      if (server.isEmpty || auth == null) return;
      final a = jsonDecode(auth) as Map;
      final token = '${a['token'] ?? ''}';
      final myId = '${(a['record'] as Map?)?['id'] ?? (a['model'] as Map?)?['id'] ?? ''}';
      if (token.isEmpty || myId.isEmpty) return;
      final now = DateTime.now();
      final r = await http.get(query(server, myId, now), headers: {'Authorization': token}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final items = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['items'] as List? ?? const []).whereType<Map>().toList();
      final done = (p.getStringList(kDone) ?? const []).toSet();
      final list = due(items, now, done);
      if (list.isEmpty) return;
      if (background) {
        await _n.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      }
      final details = NotificationDetails(
        android: (p.getBool(Settings.kNotifySound) ?? true)
            ? const AndroidNotificationDetails('nights', 'Игровые вечера', importance: Importance.high, priority: Priority.high)
            : const AndroidNotificationDetails('nights_silent', 'Игровые вечера без звука', playSound: false, enableVibration: false),
      );
      for (final n in list) {
        await _n.show(7000 + (n.id.hashCode & 0x7ff), n.title, n.body, details);
        done.add(n.id);
      }
      // Храним только последние отметки, чтобы список не рос бесконечно.
      await p.setStringList(kDone, done.toList().reversed.take(50).toList());
    } catch (e) {
      debugPrint('night remind: $e');
    } finally {
      _busy = false;
    }
  }

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isLinux);
}
