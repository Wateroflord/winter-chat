import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

const buildNumber = String.fromEnvironment('BUILD', defaultValue: 'dev');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.I.init();
  runApp(const WinterChatApp());
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

class _RootState extends State<Root> {
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    Api.I.addListener(_changed);
    _boot();
  }

  @override
  void dispose() {
    Api.I.removeListener(_changed);
    super.dispose();
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
