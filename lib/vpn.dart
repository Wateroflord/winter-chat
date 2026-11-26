import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Адрес этого устройства в Winter VPN.
class VpnAddr {
  const VpnAddr(this.ip, this.iface);
  final String ip;
  final String iface;
}

/// Winter VPN: включён ли он, включить его, открыть приложение.
class Vpn {
  static const releasesUrl = 'https://github.com/Wateroflord/winter-vpn/releases/latest';

  /// Winter VPN выдаёт адреса 100.64.0.0 – 100.127.255.255.
  static bool isWinter(String ip) {
    final s = ip.split('.');
    if (s.length != 4) return false;
    final a = int.tryParse(s[0]);
    final b = int.tryParse(s[1]);
    return a == 100 && b != null && b >= 64 && b <= 127;
  }

  /// Адрес сервера вида http://100.1.2.3:8090 — в Winter VPN.
  static bool isWinterUrl(String url) => isWinter(Uri.tryParse(url)?.host ?? '');

  static bool get _windows => !kIsWeb && Platform.isWindows;
  static bool get _android => !kIsWeb && Platform.isAndroid;

  /// Адреса этого устройства в Winter VPN. Пусто — VPN выключен.
  static Future<List<VpnAddr>> local() async {
    if (kIsWeb) return const [];
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      return [
        for (final ifc in list)
          for (final a in ifc.addresses)
            if (isWinter(a.address)) VpnAddr(a.address, ifc.name),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> isOn() async => (await local()).isNotEmpty;

  /// Движок Winter VPN на этом ПК (Windows).
  static String? get _cli {
    if (!_windows) return null;
    for (final v in ['ProgramW6432', 'ProgramFiles']) {
      final pf = Platform.environment[v];
      if (pf == null) continue;
      final p = '$pf\\Winter VPN\\winter-vpn-cli.exe';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// Стоит ли Winter VPN на этом ПК (на телефоне не узнать — считаем, что да).
  static bool get installedOnPc => _cli != null;

  /// Включить Winter VPN.
  /// ПК: тихо, без окон (если он выключен, а в сеть уже входили).
  /// Телефон: короткая ссылка wintervpn://connect — Winter VPN включится и не откроется.
  /// Возвращает false, если включить не получилось (нет приложения или ещё не входили в сеть).
  static Future<bool> connect() async {
    final cli = _cli;
    if (cli != null) {
      try {
        final st = await Process.run(cli, ['status', '--json'], stdoutEncoding: utf8)
            .timeout(const Duration(seconds: 8));
        final out = '${st.stdout}'.trim();
        if (!out.startsWith('{')) return false;
        final j = jsonDecode(out) as Map<String, dynamic>;
        final state = '${j['BackendState']}';
        if (state == 'Running') return true;
        if (state != 'Stopped') return false; // нужно войти в сеть — это делает приложение Winter VPN
        final name = '${(j['Self'] as Map?)?['HostName'] ?? ''}';
        final r = await Process.run(cli, [
          'up',
          '--reset',
          '--unattended',
          if (name.isNotEmpty) '--hostname=$name',
          '--timeout=20s',
        ]).timeout(const Duration(seconds: 30));
        return r.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    if (_android) {
      try {
        return await launchUrl(Uri.parse('wintervpn://connect'), mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// При запуске чата на ПК: сервер в Winter VPN, а VPN выключен — включить сам.
  static Future<void> ensureOnForServer(String serverUrl) async {
    if (!_windows || !isWinterUrl(serverUrl) || await isOn()) return;
    await connect();
  }

  /// Открыть приложение Winter VPN. Если его нет — страницу загрузки.
  /// Возвращает false, если пришлось открыть страницу загрузки.
  static Future<bool> open() async {
    try {
      if (await launchUrl(Uri.parse('wintervpn://open'), mode: LaunchMode.externalApplication)) return true;
    } catch (_) {}
    try {
      await launchUrl(Uri.parse(releasesUrl), mode: LaunchMode.externalApplication);
    } catch (_) {}
    return false;
  }
}
