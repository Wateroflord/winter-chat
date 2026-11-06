import 'dart:convert';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Уведомления о новых сообщениях, когда приложение закрыто или свёрнуто (Android).
///
/// Раз в 15 минут (чаще Android не разрешает) фоновая задача спрашивает сервер
/// о сообщениях, пришедших с момента, как приложение ушло в фон, и показывает их.
/// Пока приложение открыто — ничего не показывает.
class BgNotify {
  static const _alarmId = 9157;
  static final _n = FlutterLocalNotificationsPlugin();

  static const kBgSince = 'bg_since';
  static const kLastNotified = 'bg_last_notified';

  static Future<void> _initPlugin() =>
      _n.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));

  /// Формат даты PocketBase: 2026-11-06 07:00:00.000Z
  static String pbDate(DateTime d) => d.toUtc().toIso8601String().replaceFirst('T', ' ');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.initialize();
      await _initPlugin();
      await _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      await AndroidAlarmManager.periodic(const Duration(minutes: 15), _alarmId, chatCheckEntry,
          rescheduleOnReboot: true, allowWhileIdle: true);
    } catch (e) {
      debugPrint('bg notify: $e');
    }
  }

  /// Приложение свернули / открыли.
  static Future<void> setBackground(bool bg) async {
    if (!Platform.isAndroid) return;
    final p = await SharedPreferences.getInstance();
    if (bg) {
      await p.setString(kBgSince, pbDate(DateTime.now()));
    } else {
      await p.remove(kBgSince);
      try {
        await _n.cancelAll();
      } catch (_) {}
    }
  }

  /// Запрос к серверу: новые чужие сообщения после [since].
  static Uri query(String server, String myId, String since) => Uri.parse('$server/api/collections/messages/records').replace(
        queryParameters: {
          'filter': "created > '$since' && author != '$myId'",
          'sort': '-created',
          'perPage': '20',
          'expand': 'author,chat',
          'fields': 'id,created,text,files,expand.author.name,expand.author.username,expand.chat.name,expand.chat.is_group',
        },
      );

  /// Текст уведомлений из ответа сервера (проверяется тестами).
  static List<({String title, String body})> format(Map res) {
    final out = <({String title, String body})>[];
    for (final m in (res['items'] as List? ?? const []).whereType<Map>()) {
      final ex = (m['expand'] as Map?) ?? const {};
      final a = (ex['author'] as Map?) ?? const {};
      final c = (ex['chat'] as Map?) ?? const {};
      final who = '${a['name'] ?? ''}'.trim().isNotEmpty ? '${a['name']}' : '${a['username'] ?? 'Кто-то'}';
      final group = c['is_group'] == true && '${c['name'] ?? ''}'.trim().isNotEmpty;
      var text = '${m['text'] ?? ''}'.trim();
      if (text.isEmpty) text = (m['files'] is List && (m['files'] as List).isNotEmpty) ? '📎 Файл' : 'Новое сообщение';
      if (text.length > 200) text = '${text.substring(0, 200)}…';
      out.add((title: group ? '$who · ${c['name']}' : who, body: text));
    }
    return out.reversed.toList();
  }

  static Future<void> check() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final bgSince = p.getString(kBgSince);
    final server = p.getString('server') ?? '';
    final auth = p.getString('auth');
    if (bgSince == null || server.isEmpty || auth == null) return;
    final a = jsonDecode(auth) as Map;
    final token = '${a['token'] ?? ''}';
    final myId = '${(a['record'] as Map?)?['id'] ?? (a['model'] as Map?)?['id'] ?? ''}';
    if (token.isEmpty || myId.isEmpty) return;
    final last = p.getString(kLastNotified);
    final since = last != null && last.compareTo(bgSince) > 0 ? last : bgSince;
    final r = await http.get(query(server, myId, since), headers: {'Authorization': token}).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return;
    final res = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    final items = (res['items'] as List? ?? const []).whereType<Map>().toList();
    if (items.isEmpty) return;
    await p.setString(kLastNotified, '${items.first['created']}');
    await _initPlugin();
    final list = format(res);
    final details = const NotificationDetails(
      android: AndroidNotificationDetails('messages', 'Сообщения', importance: Importance.high, priority: Priority.high),
    );
    if (list.length > 3) {
      await _n.show(_alarmId, 'Winter Chat', 'Новых сообщений: ${list.length}', details);
    } else {
      for (var i = 0; i < list.length; i++) {
        await _n.show(_alarmId + 1 + i, list[i].title, list[i].body, details);
      }
    }
  }
}

@pragma('vm:entry-point')
Future<void> chatCheckEntry() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await BgNotify.check();
  } catch (_) {}
}
