import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'bg_notify.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'settings.dart';
import 'theme.dart';
import 'package:winter_core/winter_core.dart';

const buildNumber = String.fromEnvironment('BUILD', defaultValue: 'dev');

Future<void> main() => runWinterApp(repo: 'winter-chat', appName: 'Winter Chat', body: _main);

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Settings.I.init();
  await Api.I.init();
  runApp(WinterCrashBanner(child: const WinterChatApp()));
  BgNotify.start();
}

final navigatorKey = GlobalKey<NavigatorState>();

class WinterChatApp extends StatefulWidget {
  const WinterChatApp({super.key});

  @override
  State<WinterChatApp> createState() => _WinterChatAppState();
}

class _WinterChatAppState extends State<WinterChatApp> {
  @override
  void initState() {
    super.initState();
    W.apply(Settings.I.palette, Settings.I.accent);
    Settings.I.addListener(_changed);
  }

  @override
  void dispose() {
    Settings.I.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    W.apply(Settings.I.palette, Settings.I.accent);
    // Тема, пузыри, аватары — всё читается при построении, поэтому перестраиваем всё дерево.
    rebuildAll(context);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Winter Chat',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: navigatorKey,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(Settings.I.textScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const Root(),
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
    WidgetsBinding.instance.addObserver(this);
    BgNotify.setBackground(false);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Api.I.removeListener(_changed);
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

  Future<void> _boot() async {
    if (Api.I.loggedIn) {
      try {
        await Api.I.afterLogin().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (mounted) setState(() => _booting = false);
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
