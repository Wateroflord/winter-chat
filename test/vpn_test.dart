import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/util.dart';
import 'package:winter_chat/vpn.dart';

void main() {
  test('адреса Winter VPN и Radmin', () {
    expect(Vpn.isWinter('100.64.0.1'), isTrue);
    expect(Vpn.isWinter('100.101.7.9'), isTrue);
    expect(Vpn.isWinter('100.128.0.1'), isFalse);
    expect(Vpn.isWinter('192.168.1.5'), isFalse);
    expect(Vpn.isRadmin('26.12.3.4'), isTrue);
    expect(Vpn.kindOfUrl('http://100.88.1.2:8090'), 'Winter VPN');
    expect(Vpn.kindOfUrl('http://26.1.2.3:8090'), 'Radmin VPN');
    expect(Vpn.kindOfUrl('http://192.168.1.5:8090'), '');
  });

  test('ссылка-приглашение Winter VPN в сообщении кликабельна', () {
    final m = urlRegex
        .allMatches('Заходи: wintervpn://join?key=tskey-auth-abc-123 и https://example.com')
        .map((e) => e.group(0))
        .toList();
    expect(m, ['wintervpn://join?key=tskey-auth-abc-123', 'https://example.com']);
  });
}
