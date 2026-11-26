import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Приглашение в чат: winterchat://join?server=100.x.x.x:8090&code=SNOW-XXXX-XXXX
/// Его открывает Winter VPN, как только вошёл в сеть друга (одна ссылка на всё).
class JoinLink {
  const JoinLink({required this.server, this.code = ''});
  final String server;
  final String code;

  @override
  bool operator ==(Object other) => other is JoinLink && other.server == server && other.code == code;

  @override
  int get hashCode => Object.hash(server, code);

  static JoinLink? parse(String text) {
    final m = RegExp(r'winterchat://\S+').firstMatch(text.trim());
    if (m == null) return null;
    final uri = Uri.tryParse(m.group(0)!);
    if (uri == null || uri.host != 'join') return null;
    final server = (uri.queryParameters['server'] ?? '').trim();
    if (server.isEmpty) return null;
    return JoinLink(server: server, code: (uri.queryParameters['code'] ?? '').trim());
  }
}

class ChatLinks {
  /// Последнее пришедшее приглашение, которое ещё не применили.
  static final pending = ValueNotifier<JoinLink?>(null);

  static StreamSubscription<Uri>? _sub;

  /// args — аргументы запуска (на Windows ссылку передаёт сама система).
  static Future<void> init(List<String> args) async {
    for (final a in args) {
      final l = JoinLink.parse(a);
      if (l != null) pending.value = l;
    }
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final links = AppLinks();
      final first = await links.getInitialLink();
      if (first != null) _take(first);
      _sub ??= links.uriLinkStream.listen(_take, onError: (_) {});
    } catch (_) {}
  }

  static void _take(Uri uri) {
    final l = JoinLink.parse(uri.toString());
    if (l != null) pending.value = l;
  }
}
