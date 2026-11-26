import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Адрес этого устройства в VPN-сети.
class VpnAddr {
  const VpnAddr(this.ip, this.kind, this.iface);
  final String ip;
  final String kind; // 'Winter VPN', 'Radmin VPN', 'ZeroTier'
  final String iface;
}

/// Winter VPN и другие VPN для игр (Radmin, ZeroTier): определить, включены ли они,
/// и открыть приложение Winter VPN.
class Vpn {
  static const releasesUrl = 'https://github.com/Wateroflord/winter-vpn/releases/latest';

  /// Winter VPN (движок Tailscale) выдаёт адреса 100.64.0.0 – 100.127.255.255.
  static bool isWinter(String ip) {
    final p = _parts(ip);
    return p != null && p[0] == 100 && p[1] >= 64 && p[1] <= 127;
  }

  static bool isRadmin(String ip) {
    final p = _parts(ip);
    return p != null && p[0] == 26;
  }

  static List<int>? _parts(String ip) {
    final s = ip.split('.');
    if (s.length != 4) return null;
    final out = <int>[];
    for (final x in s) {
      final v = int.tryParse(x);
      if (v == null || v < 0 || v > 255) return null;
      out.add(v);
    }
    return out;
  }

  /// Какой VPN нужен, чтобы попасть на этот адрес ('' — обычный адрес).
  static String kindOfHost(String host) {
    if (isWinter(host)) return 'Winter VPN';
    if (isRadmin(host)) return 'Radmin VPN';
    return '';
  }

  /// Какой VPN нужен для адреса сервера вида http://100.1.2.3:8090.
  static String kindOfUrl(String url) => kindOfHost(Uri.tryParse(url)?.host ?? '');

  /// VPN-адреса этого устройства. Пусто — VPN выключен.
  static Future<List<VpnAddr>> local() async {
    if (kIsWeb) return const [];
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      final out = <VpnAddr>[];
      for (final ifc in list) {
        final name = ifc.name.toLowerCase();
        for (final a in ifc.addresses) {
          final ip = a.address;
          if (isWinter(ip) || name.contains('winter') || name.contains('tailscale')) {
            out.add(VpnAddr(ip, 'Winter VPN', ifc.name));
          } else if (isRadmin(ip) || name.contains('radmin')) {
            out.add(VpnAddr(ip, 'Radmin VPN', ifc.name));
          } else if (name.startsWith('zt') || name.contains('zerotier')) {
            out.add(VpnAddr(ip, 'ZeroTier', ifc.name));
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Включён ли VPN нужного вида на этом устройстве.
  static Future<bool> hasLocal(String kind) async => (await local()).any((a) => a.kind == kind);

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
