import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/settings.dart';
import 'package:winter_chat/sounds.dart';
import 'package:winter_chat/theme.dart';
import 'package:winter_chat/util.dart';
import 'package:winter_chat/widgets/chat_background.dart';

void main() {
  test('темы: текст читается на фоне, id не повторяются', () {
    final ids = <String>{};
    for (final p in palettes) {
      expect(ids.add(p.id), isTrue, reason: p.id);
      final contrast = (p.text.computeLuminance() + 0.05) / (p.bg.computeLuminance() + 0.05);
      final ratio = contrast < 1 ? 1 / contrast : contrast;
      expect(ratio, greaterThan(7), reason: '${p.name}: текст на фоне');
      expect(p.light, p.bg.computeLuminance() > 0.5, reason: p.name);
    }
    expect(paletteById('нет такой').id, 'winter');
  });

  test('тема применяется, на светлой теме светлый акцент затемняется', () {
    W.apply(paletteById('light'), const Color(0xFF7FD8FF));
    expect(W.light, isTrue);
    expect(W.ice.computeLuminance(), lessThan(const Color(0xFF7FD8FF).computeLuminance()));
    expect(W.onAccent, onColor(W.ice));
    W.apply(paletteById('winter'), const Color(0xFF7FD8FF));
    expect(W.ice, const Color(0xFF7FD8FF));
    expect(W.bg, const Color(0xFF0A1020));
  });

  test('цвет текста на пузыре', () {
    expect(onColor(const Color(0xFFFFFFFF)).computeLuminance(), lessThan(0.1));
    expect(onColor(const Color(0xFF0A1020)), const Color(0xFFFFFFFF));
  });

  test('цвет в #RRGGBB и обратно', () {
    expect(parseHexColor('#ff78aa'), const Color(0xFFFF78AA));
    expect(parseHexColor('FF78AA'), const Color(0xFFFF78AA));
    expect(parseHexColor('красный'), isNull);
    expect(parseHexColor(''), isNull);
    expect(colorToHex(const Color(0xFF0A1020)), '#0A1020');
  });

  test('фон: сохраняется и читается, мусор не ломает', () {
    const items = [
      Wallpaper.none(),
      Wallpaper.preset(3),
      Wallpaper.gradient(0xFF112233, 0xFF445566, angle: 3, pattern: true),
      Wallpaper.image('/tmp/x.jpg', dim: 0.5, blur: 7),
    ];
    for (final w in items) {
      expect(Wallpaper.decode(w.encode()), w);
    }
    expect(Wallpaper.decode('ерунда'), isNull);
    expect(Wallpaper.decode('{"k":1,"p":999}')!.preset, Wallpaper.presets.length);
    expect(Wallpaper.decode('{"k":3}')!.kind, 0); // фото без пути — без фона
    expect(Wallpaper.decode('{"k":3,"path":"a","dim":5,"blur":-1}')!.dim, 0.85);
  });

  test('настройки чата: сохраняются и пустые не хранятся', () {
    const p = ChatPrefs(alias: 'Мама', pin: true, mute: true, wallpaper: Wallpaper.preset(2), bubble: Color(0xFF123456));
    final back = ChatPrefs.fromJson(p.toJson());
    expect(back.alias, 'Мама');
    expect(back.pin && back.mute, isTrue);
    expect(back.wallpaper, const Wallpaper.preset(2));
    expect(back.bubble, const Color(0xFF123456));
    expect(const ChatPrefs().isEmpty, isTrue);
    expect(p.copyWith(clearWallpaper: true, clearBubble: true, alias: '', pin: false, mute: false).isEmpty, isTrue);
  });

  test('звуки: настоящие WAV и разные', () {
    final seen = <int>{};
    for (var n = 1; n < Sounds.messageSounds.length; n++) {
      final w = messageWav(n);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
      seen.add(Object.hashAll(w.sublist(44, 2044)));
    }
    expect(seen.length, Sounds.messageSounds.length - 1);
    for (var n = 1; n < Sounds.ringSounds.length; n++) {
      expect(ringWav(n).length, greaterThan(44 + 22050 * 2 * 2));
    }
  });
}
