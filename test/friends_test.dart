import 'package:flutter_test/flutter_test.dart';
import 'package:winter_chat/dota.dart';
import 'package:winter_chat/screens/friends_logic.dart';

DotaMatch m(bool win, {int k = 5, int d = 5, int a = 5, int start = 0}) =>
    DotaMatch(id: 1, heroId: 1, kills: k, deaths: d, assists: a, win: win, start: start);

void main() {
  group('Dota', () {
    test('номер аккаунта из ссылки или Steam64', () {
      expect(parseDotaId('123456789'), '123456789');
      expect(parseDotaId('76561198083722517'), '123456789');
      expect(parseDotaId('https://www.dotabuff.com/players/123456789/matches'), '123456789');
      expect(parseDotaId('https://steamcommunity.com/profiles/76561198083722517/'), '123456789');
      expect(parseDotaId('https://steamcommunity.com/id/nickname'), isNull);
      expect(parseDotaId(''), isNull);
    });

    test('ранги', () {
      expect(rankName(54), 'Легенда 4');
      expect(rankName(80), 'Титан');
      expect(rankName(null), 'Без ранга');
    });

    test('победа: сторона Сил Света или Тьмы', () {
      expect(DotaMatch.fromJson({'player_slot': 1, 'radiant_win': true}).win, isTrue);
      expect(DotaMatch.fromJson({'player_slot': 130, 'radiant_win': true}).win, isFalse);
      expect(DotaMatch.fromJson({'player_slot': 130, 'radiant_win': false}).win, isTrue);
    });

    test('сводка и серия', () {
      final s = summarize([m(true), m(true), m(false), m(true)]);
      expect(s.games, 4);
      expect(s.wins, 3);
      expect(s.streak, 2);
      expect(summarize([m(false), m(false), m(true)]).streak, -2);
      expect(s.kda, 2);
    });

    test('награды недели', () {
      final aw = weeklyAwards({
        'a': [m(true, k: 12, d: 2), m(true, k: 10, d: 3), m(true, k: 9, d: 1)],
        'b': [m(false, k: 1, d: 12, a: 20), m(false, d: 10, a: 15), m(true, d: 9, a: 18), m(false)],
        'c': [m(true)], // мало игр — не участвует
      });
      String who(String t) => aw.firstWhere((x) => x.title == t).userId;
      expect(who('Король недели'), 'a');
      expect(who('Мясник'), 'a');
      expect(who('Лучший саппорт'), 'b');
      expect(who('Кормилец'), 'b');
      expect(who('Не вылезает из доты'), 'b');
      expect(who('На серии'), 'a');
    });

    test('матчи за неделю', () {
      final now = DateTime(2026, 11, 28);
      final recent = now.subtract(const Duration(days: 2)).millisecondsSinceEpoch ~/ 1000;
      final old = now.subtract(const Duration(days: 9)).millisecondsSinceEpoch ~/ 1000;
      expect(lastDays([m(true, start: recent), m(true, start: old)], now).length, 1);
    });
  });

  group('Игровые вечера', () {
    test('подпись времени', () {
      final now = DateTime(2026, 11, 28, 15);
      expect(nightWhen(DateTime(2026, 11, 28, 20, 30), now), 'Сегодня в 20:30');
      expect(nightWhen(DateTime(2026, 11, 29, 19), now), 'Завтра в 19:00');
      expect(nightWhen(DateTime(2026, 12, 3, 21), now), 'Чт, 3 декабря в 21:00');
    });

    test('моя отметка', () {
      expect(myRsvp(going: ['a', 'me'], maybe: [], no: [], me: 'me'), 'going');
      expect(myRsvp(going: [], maybe: [], no: ['me'], me: 'me'), 'no');
      expect(myRsvp(going: [], maybe: [], no: [], me: 'me'), '');
    });

    test('смена отметки: убрать из других списков', () {
      final ch = rsvpChange('maybe', 'going', 'me');
      expect(ch, {'maybe+': 'me', 'going-': 'me', 'no-': 'me'});
      expect(rsvpChange('', 'going', 'me'), {'going-': 'me', 'maybe-': 'me', 'no-': 'me'});
    });
  });
}
