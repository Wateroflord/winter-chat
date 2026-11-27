import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'bg_notify.dart';
import 'settings.dart';
import 'store.dart';

/// Мгновенные уведомления.
///
/// Пока приложение свёрнуто (или окно на ПК не в фокусе), оно остаётся на связи с сервером
/// и показывает уведомление сразу, как пришло сообщение. На Android для этого работает служба
/// «Winter Chat на связи» (иначе система усыпит приложение). Если приложение всё же закрыли —
/// остаётся старая проверка раз в ~15 минут (bg_notify.dart).
class Instant {
  static const _ch = MethodChannel('winter_chat/keepalive');
  static final _n = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static bool _running = false;
  static bool _started = false;

  /// Приложение свёрнуто / окно не в фокусе.
  static bool background = false;

  static bool get _android => !kIsWeb && Platform.isAndroid;

  static Future<void> init() async {
    if (_started || kIsWeb) return;
    _started = true;
    try {
      _ready = await _n.initialize(
            const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              linux: LinuxInitializationSettings(defaultActionName: 'Открыть'),
              windows: WindowsInitializationSettings(
                appName: 'Winter Chat',
                appUserModelId: 'WinterHub.WinterChat',
                guid: '6b0f3a52-8e7c-4c2b-9a0e-3f5d1c2b7a91',
              ),
            ),
          ) ??
          false;
    } catch (e) {
      debugPrint('notifications: $e');
    }
    Store.I.newMessages.listen(_onMessage);
    Settings.I.addListener(sync);
    Api.I.addListener(sync);
    await sync();
  }

  /// Включить или выключить службу «на связи» по настройкам.
  static Future<void> sync() async {
    if (!_android) return;
    final want = Api.I.loggedIn && Settings.I.notify && Settings.I.instantNotify;
    if (want == _running) return;
    _running = want;
    try {
      await _ch.invokeMethod(want ? 'start' : 'stop');
    } catch (e) {
      debugPrint('keepalive: $e');
    }
  }

  /// Система не мешает работать в фоне (Android: исключение из экономии батареи).
  static Future<bool> batteryOk() async {
    if (!_android) return true;
    try {
      return await _ch.invokeMethod<bool>('batteryOk') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Попросить систему не усыплять приложение.
  static Future<void> askBattery() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('askBattery');
    } catch (_) {}
  }

  static Future<void> _onMessage(String chatId) async {
    if (!background || !_ready) return;
    final s = Settings.I;
    if (!s.notify || s.dnd || s.isMuted(chatId)) return;
    final chat = Store.I.chat(chatId);
    if (chat == null) return;
    final api = Api.I;
    final author = chat.getStringValue('last_author');
    final group = chat.getBoolValue('is_group');
    final title = group ? '${api.nameOf(author)} · ${api.chatTitle(chat)}' : api.nameOf(author);
    var body = chat.getStringValue('last_text').trim();
    if (body.isEmpty) body = 'Новое сообщение';
    final withSound = s.notifySound;
    final details = NotificationDetails(
      android: withSound
          ? const AndroidNotificationDetails('messages', 'Сообщения', importance: Importance.high, priority: Priority.high)
          : const AndroidNotificationDetails('messages_silent', 'Сообщения без звука',
              importance: Importance.defaultImportance, priority: Priority.defaultPriority, playSound: false, enableVibration: false),
      linux: const LinuxNotificationDetails(),
      windows: const WindowsNotificationDetails(),
    );
    try {
      // Один чат — одно уведомление, новое заменяет старое.
      await _n.show(2000 + (chatId.hashCode & 0x7fff), title, body, details);
    } catch (e) {
      debugPrint('notify: $e');
    }
    // Фоновая проверка не должна показать это же сообщение ещё раз.
    try {
      final p = await SharedPreferences.getInstance();
      final at = chat.getStringValue('last_at');
      final prev = p.getString(BgNotify.kLastNotified) ?? '';
      if (at.compareTo(prev) > 0) await p.setString(BgNotify.kLastNotified, at);
    } catch (_) {}
  }
}
