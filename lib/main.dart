import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'bg_notify.dart';
import 'links.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'settings.dart';
import 'theme.dart';
import 'vpn.dart';
import 'package:winter_core/winter_core.dart';

const buildNumber = String.fromEnvironment('BUILD', defaultValue: 'dev');

List<String> _args = const [];

Future<void> main(List<String> args) {
  _args = args;
  return runWinterApp(repo: 'winter-chat', appName: 'Winter Chat', body: _main);
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Settings.I.init();
  await Api.I.init();
  // Ссылка-приглашение winterchat://join (её открывает Winter VPN после входа в сеть).
  await ChatLinks.init(_args);
  // На ПК Winter VPN включается сам, если сервер чата — в Winter VPN.
  unawaited(Vpn.ensureOnForServer(Api.I.serverUrl));
  runApp(WinterCrashBanner(child: const WinterChatApp()));
  BgNotify.start();
}

final navigatorKey = GlobalKey<NavigatorState>();

class WinterChatApp extends StatelessWidget {
  const WinterChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Settings.I,
      builder: (context, _) => MaterialApp(
        title: 'Winter Chat',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(accent: Settings.I.accent),
        navigatorKey: navigatorKey,
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          return MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(Settings.I.textScale)),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const Root(),
      ),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    Api.I.addListener(_changed);
    ChatLinks.pending.addListener(_onInvite);
    WidgetsBinding.instance.addObserver(this);
    BgNotify.setBackground(false);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Api.I.removeListener(_changed);
    ChatLinks.pending.removeListener(_onInvite);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Свернули — фоновая задача начинает присылать уведомления; открыли — перестаёт.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) BgNotify.setBackground(true);
    if (state == AppLifecycleState.resumed) BgNotify.setBackground(false);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Пришло приглашение, а мы уже в аккаунте: тот же сервер — просто сказать; другой — предложить перейти.
  Future<void> _onInvite() async {
    final link = ChatLinks.pending.value;
    if (link == null || !Api.I.loggedIn || _booting) return;
    final target = Api.normalizeUrl(link.server);
    final host = Uri.tryParse(target)?.host ?? '';
    final same = Api.I.knownUrls.any((u) => Uri.tryParse(u)?.host == host);
    final ctx = navigatorKey.currentContext;
    if (same) {
      ChatLinks.pending.value = null;
      if (Api.I.serverUrl != target && await Api.I.isSameServer(target)) await Api.I.switchTo(target);
      if (ctx != null && ctx.mounted) toast(ctx, 'Ты уже в этом чате ❄');
      return;
    }
    if (ctx == null || !ctx.mounted) return;
    final go = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Приглашение в другой чат'),
        content: Text('Тебя пригласили на сервер ${link.server}. Выйти из текущего аккаунта и войти там?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Остаться')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Перейти')),
        ],
      ),
    );
    if (go == true) {
      await Api.I.logout(); // экран входа подхватит приглашение
    } else {
      ChatLinks.pending.value = null;
    }
  }

  Future<void> _boot() async {
    if (Api.I.loggedIn) {
      try {
        await Api.I.afterLogin().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (mounted) setState(() => _booting = false);
    unawaited(_onInvite());
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!Api.I.loggedIn) return const LoginScreen();
    // Ключ — основной адрес: при переключении на запасной (Winter VPN) экран не пересоздаётся.
    return HomeScreen(key: ValueKey('${Api.I.primaryUrl}|${Api.I.myId}'));
  }
}
