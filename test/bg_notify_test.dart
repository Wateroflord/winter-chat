import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/bg_notify.dart';

void main() {
  test('дата в формате PocketBase', () {
    expect(BgNotify.pbDate(DateTime.utc(2026, 11, 6, 7, 5, 9)), '2026-11-06 07:05:09.000Z');
  });

  test('запрос: только чужие сообщения после нужного времени', () {
    final u = BgNotify.query('http://1.2.3.4:8090', 'me123', '2026-11-06 07:00:00.000Z');
    expect(u.path, '/api/collections/messages/records');
    expect(u.queryParameters['filter'], "created > '2026-11-06 07:00:00.000Z' && author != 'me123'");
    expect(u.queryParameters['expand'], 'author,chat');
  });

  test('текст уведомлений: имя, группа, файлы, старые сверху', () {
    final list = BgNotify.format({
      'items': [
        {
          'text': 'привет',
          'expand': {
            'author': {'name': 'Вова', 'username': 'vova'},
            'chat': {'name': 'Друзья', 'is_group': true},
          },
        },
        {
          'text': '',
          'files': ['a.jpg'],
          'expand': {
            'author': {'name': '', 'username': 'petya'},
            'chat': {'is_group': false},
          },
        },
      ],
    });
    expect(list.length, 2);
    expect(list[0].title, 'petya');
    expect(list[0].body, '📎 Файл');
    expect(list[1].title, 'Вова · Друзья');
    expect(list[1].body, 'привет');
  });
}
