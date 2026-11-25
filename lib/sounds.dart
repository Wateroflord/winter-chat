import 'package:media_kit/media_kit.dart';

import 'settings.dart';

/// Звук нового сообщения, пока приложение открыто.
class Sounds {
  static Player? _player;
  static DateTime _last = DateTime(2000);

  static Future<void> message({bool force = false}) async {
    if (!force && (!Settings.I.inAppSound || Settings.I.dnd)) return;
    // Пачка сообщений подряд — один звук.
    final now = DateTime.now();
    if (!force && now.difference(_last) < const Duration(milliseconds: 1500)) return;
    _last = now;
    try {
      final p = _player ??= Player();
      await p.setVolume(70);
      await p.open(Media('asset:///assets/sounds/message.wav'));
    } catch (_) {}
  }
}
