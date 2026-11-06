import 'package:flutter/material.dart';

import 'api.dart';
import 'bg_notify.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'package:winter_core/winter_core.dart';

const buildNumber = String.fromEnvironment('BUILD', defaultValue: 'dev');

void main() => runWinterApp(repo: 'winter-chat', appName: 'Winter Chat', body: _main);

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.I.init();
  runApp(WinterCrashBanner(child: const WinterChatApp()));
  BgNotify.start();
}

final navigatorKey = GlobalKey<NavigatorState>();

class WinterChatApp extends StatelessWidget {
  const WinterChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Winter Chat',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: navigatorKey,
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
    return HomeScreen(key: ValueKey('${Api.I.serverUrl}|${Api.I.myId}'));
  }
}
