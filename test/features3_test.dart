import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/bg_notify.dart';
import 'package:winter_chat/outbox.dart';
import 'package:winter_chat/widgets/rich_text.dart';

void main() {
  group('форматирование', () {
    test('жирный, курсив, зачёркнутый, код', () {
      final s = parseRich('**жир** и _кур_ и *тоже* ~~нет~~ `код`');
      RichSeg find(String t) => s.firstWhere((x) => x.text == t);
      expect(find('жир').has(fBold), isTrue);
      expect(find('кур').has(fItalic), isTrue);
      expect(find('тоже').has(fItalic), isTrue);
      expect(find('нет').has(fStrike), isTrue);
      expect(find('код').has(fCode), isTrue);
      expect(richPlain('**жир** и _кур_'), 'жир и кур');
    });

    test('спойлер прячется в превью', () {
      final s = parseRich('Концовка: ||все умерли|| ахах');
      expect(s.firstWhere((x) => x.text == 'все умерли').spoiler, 1);
      expect(richPlain('Концовка: ||все умерли|| ахах'), 'Концовка: ▒▒▒ ахах');
    });

    test('блок кода не трогает звёздочки внутри', () {
      final s = parseRich('смотри:\n```dart\nfinal a = 2 * 3 * 4;\n```');
      final block = s.firstWhere((x) => x.has(fBlock));
      expect(block.text, 'final a = 2 * 3 * 4;');
    });

    test('подчёркивания в ссылках и именах файлов — не курсив', () {
      final s = parseRich('https://ex.com/a_b_c и voice_123_ab');
      expect(s.any((x) => x.has(fItalic)), isFalse);
      expect(s.firstWhere((x) => x.url != null).url, 'https://ex.com/a_b_c');
    });

    test('2 * 3 * 4 — не курсив', () {
      expect(parseRich('2 * 3 * 4').any((x) => x.has(fItalic)), isFalse);
    });

    test('ссылка без точки в конце', () {
      final s = parseRich('Глянь https://youtu.be/abc.');
      expect(s.firstWhere((x) => x.url != null).url, 'https://youtu.be/abc');
    });
  });

  group('упоминания', () {
    test('ник, @все и почта', () {
      expect(mentionsIn('@Vova го в доту, @все сюда'), {'vova', 'all'});
      expect(mentionsIn('пиши на me@mail.ru'), isEmpty);
      expect(mentionsIn('@stas.'), {'stas'});
      expect(mentionsIn('`@vova` в коде'), isEmpty);
    });
  });

  test('обернуть выделенное', () {
    final c = TextEditingController(text: 'привет мир');
    c.selection = const TextSelection(baseOffset: 7, extentOffset: 10);
    wrapSelection(c, '**');
    expect(c.text, 'привет **мир**');
    expect(c.selection.textInside(c.text), 'мир');
  });

  test('очередь отправки: сохраняется и восстанавливается', () {
    final it = OutItem(
      id: 'out_1',
      chatId: 'c1',
      text: 'привет',
      replyTo: 'm1',
      extra: const {'poll': {'q': '?', 'o': ['a', 'b']}},
      files: [OutFile(name: 'a.jpg', size: 10, path: '/tmp/a.jpg')],
      created: DateTime(2026, 11, 28),
    );
    it.state = OutState.failed;
    it.error = 'Нет доступа';
    final back = OutItem.fromJson(it.toJson())!;
    expect(back.chatId, 'c1');
    expect(back.replyTo, 'm1');
    expect(back.files.single.path, '/tmp/a.jpg');
    expect((back.extra['poll'] as Map)['q'], '?');
    expect(back.state, OutState.failed);
    expect(back.error, 'Нет доступа');
  });

  group('фоновые уведомления', () {
    Map item(String text, {String chat = 'c1', Map? extra}) => {
          'chat': chat,
          'text': text,
          'expand': {
            'author': {'name': 'Вова'},
            'chat': {'name': 'Банда', 'is_group': true},
          },
          ...?extra,
        };

    test('опрос, стикер, напоминание', () {
      final out = BgNotify.format({
        'items': [
          item('', extra: {'poll': {'q': 'Во сколько?', 'o': ['19', '20']}}),
          item('', extra: {'sticker': 'abc'}),
          item('Катка!', extra: {'remind': true}),
        ],
      });
      // В ответе сервера новые сверху — в уведомлениях по порядку.
      expect(out.map((e) => e.body).toList(), ['⏰ Катка!', '🖼 Стикер', '📊 Во сколько?']);
    });

    test('чат без звука молчит, но не когда позвали лично', () {
      final res = {
        'items': [item('@stas иди сюда'), item('просто болтаем')],
      };
      final out = BgNotify.format(res, muted: {'c1'}, myUsername: 'Stas');
      expect(out.single.body, '📣 @stas иди сюда');
      expect(BgNotify.format(res, muted: {'c1'}), isEmpty);
    });

    test('спойлер не виден в уведомлении', () {
      final out = BgNotify.format({'items': [item('||секрет||')]});
      expect(out.single.body, '▒▒▒');
    });
  });
}
