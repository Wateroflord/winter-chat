import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/links.dart';
import 'package:winter_chat/util.dart';
import 'package:winter_chat/vpn.dart';

void main() {
  test('адреса Winter VPN', () {
    expect(Vpn.isWinter('100.64.0.1'), isTrue);
    expect(Vpn.isWinter('100.104.115.8'), isTrue);
    expect(Vpn.isWinter('100.128.0.1'), isFalse);
    expect(Vpn.isWinter('192.168.1.5'), isFalse);
    expect(Vpn.isWinter('26.141.174.79'), isFalse);
    expect(Vpn.isWinterUrl('http://100.88.1.2:8090'), isTrue);
    expect(Vpn.isWinterUrl('http://192.168.1.5:8090'), isFalse);
  });

  test('ссылка-приглашение Winter VPN в сообщении кликабельна', () {
    final m = urlRegex
        .allMatches('Заходи: wintervpn://join?key=tskey-auth-abc-123 и https://example.com')
        .map((e) => e.group(0))
        .toList();
    expect(m, ['wintervpn://join?key=tskey-auth-abc-123', 'https://example.com']);
  });

  test('приглашение в чат winterchat://join', () {
    final l = JoinLink.parse('winterchat://join?server=100.104.115.8:8090&code=SNOW-7K3P-9QXA')!;
    expect(l.server, '100.104.115.8:8090');
    expect(l.code, 'SNOW-7K3P-9QXA');
    expect(JoinLink.parse('winterchat://join?code=X'), isNull);
    expect(JoinLink.parse('привет'), isNull);
    expect(JoinLink.parse('winterchat://join?server=1.2.3.4:8090'), const JoinLink(server: '1.2.3.4:8090'));
  });
}
