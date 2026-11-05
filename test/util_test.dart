import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/util.dart';

void main() {
  test('дата из PocketBase', () {
    final d = parseDate('2026-11-05 12:30:00.000Z')!;
    expect(d.toUtc(), DateTime.utc(2026, 11, 5, 12, 30));
    expect(parseDate(''), isNull);
    expect(parseDate('ерунда'), isNull);
  });

  test('подписи времени и дня', () {
    final now = DateTime.now();
    expect(dayLabel(now), 'Сегодня');
    expect(dayLabel(now.subtract(const Duration(days: 1))), 'Вчера');
    expect(shortTime(DateTime(now.year, now.month, now.day, 7, 5)), '07:05');
    expect(dayLabel(DateTime(2001, 3, 8)), '8 марта 2001');
    expect(shortTime(DateTime(2001, 3, 8)), '08.03.01');
  });

  test('тип файла по расширению', () {
    expect(fileKind('Фото.JPG'), FileKind.image);
    expect(fileKind('clip.mp4'), FileKind.video);
    expect(fileKind('voice.opus'), FileKind.audio);
    expect(fileKind('doc.pdf'), FileKind.other);
    expect(fileKind('без_расширения'), FileKind.other);
  });

  test('имя файла без случайного хвоста PocketBase', () {
    expect(prettyFileName('photo_ab12cd34ef.jpg'), 'photo.jpg');
    expect(prettyFileName('notes_0123456789'), 'notes');
    expect(prettyFileName('short_ab.jpg'), 'short_ab.jpg');
  });

  test('размер файла', () {
    expect(humanSize(500), '500 Б');
    expect(humanSize(2048), '2 КБ');
    expect(humanSize(5 * 1024 * 1024), '5.0 МБ');
    expect(humanSize(3 * 1024 * 1024 * 1024), '3.00 ГБ');
  });

  test('ссылки в тексте', () {
    final m = urlRegex.allMatches('Смотри https://example.com/a?b=1 и http://x.y').map((e) => e.group(0)).toList();
    expect(m, ['https://example.com/a?b=1', 'http://x.y']);
  });
}
