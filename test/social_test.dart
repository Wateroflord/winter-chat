import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:winter_chat/screens/search_screen.dart';
import 'package:winter_chat/settings.dart';
import 'package:winter_chat/theme.dart';
import 'package:winter_chat/widgets/chat_background.dart';
import 'package:winter_chat/widgets/voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.I.init();
  });

  test('тема: код → применить у друга → всё совпадает', () async {
    final s = Settings.I;
    s.palette = paletteById('light');
    s.accent = const Color(0xFFFF78AA);
    s.bubbleStyle = 1;
    s.bubbleRadius = 22;
    s.myBubbleColor = const Color(0xFF112233);
    s.myBubbleGradient = true;
    s.squareAvatars = true;
    s.wallpaper = const Wallpaper.gradient(0xFF112233, 0xFF445566, angle: 2, pattern: true);
    final code = s.exportTheme();
    expect(code, startsWith(Settings.themePrefix));
    expect(code.contains(' '), isFalse);

    // «Друг» с чистыми настройками.
    SharedPreferences.setMockInitialValues({});
    await s.init();
    expect(s.palette.id, isNot('light'));
    // Код может прийти внутри текста сообщения.
    expect(await s.importTheme('Лови мою тему: $code 🔥'), isTrue);
    expect(s.palette.id, 'light');
    expect(s.accent, const Color(0xFFFF78AA));
    expect(s.bubbleStyle, 1);
    expect(s.bubbleRadius, 22);
    expect(s.myBubbleColor, const Color(0xFF112233));
    expect(s.myBubbleGradient, isTrue);
    expect(s.otherBubbleColor, isNull);
    expect(s.squareAvatars, isTrue);
    expect(s.wallpaper, const Wallpaper.gradient(0xFF112233, 0xFF445566, angle: 2, pattern: true));
  });

  test('тема: своё фото фона не уходит в код', () async {
    Settings.I.wallpaper = const Wallpaper.image('/sdcard/секрет.jpg');
    final j = Settings.parseTheme(Settings.I.exportTheme())!;
    expect(j['wp'], const Wallpaper.none().toJson());
  });

  test('тема: мусор не применяется', () async {
    for (final bad in ['', 'привет', 'WINTERTHEME:', 'WINTERTHEME:@@@', 'WINTERTHEME:e30', 'WINTERTHEME:bnVsbA']) {
      expect(Settings.parseTheme(bad), isNull, reason: bad);
      expect(await Settings.I.importTheme(bad), isFalse, reason: bad);
    }
  });

  test('подпись сообщения для поиска и закрепов', () {
    RecordModel m(Map<String, dynamic> d) => RecordModel.fromJson({'id': 'x', ...d});
    expect(messageSnippet(m({'text': 'привет\nкак дела'})), 'привет как дела');
    expect(messageSnippet(m({'files': ['voice_1700000000_ab12cd.m4a']})), '🎤 Голосовое');
    expect(messageSnippet(m({'files': ['cat_ab12cd.jpg']})), '🖼 Фото');
    expect(messageSnippet(m({'files': ['clip_ab12cd.mp4']})), '🎬 Видео');
    expect(messageSnippet(m({})), 'Сообщение');
  });

  test('время голосового', () {
    expect(mmss(Duration.zero), '0:00');
    expect(mmss(const Duration(seconds: 65)), '1:05');
    expect(mmss(const Duration(minutes: 12, seconds: 3)), '12:03');
  });
}
