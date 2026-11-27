/// Раздел «Друзья» — чистая логика (проверяется тестами).
library;

const _monthsGen = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const _wd = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// «Сегодня в 20:30», «Завтра в 19:00», «Чт, 3 декабря в 21:00».
String nightWhen(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  if (diff == 0) return 'Сегодня в ${_hm(at)}';
  if (diff == 1) return 'Завтра в ${_hm(at)}';
  if (diff == -1) return 'Вчера в ${_hm(at)}';
  return '${_wd[at.weekday - 1]}, ${at.day} ${_monthsGen[at.month - 1]}${at.year != now.year ? ' ${at.year}' : ''} в ${_hm(at)}';
}

/// Моя отметка: going / maybe / no / '' (не отметился).
String myRsvp({required List<String> going, required List<String> maybe, required List<String> no, required String me}) {
  if (going.contains(me)) return 'going';
  if (maybe.contains(me)) return 'maybe';
  if (no.contains(me)) return 'no';
  return '';
}

/// Тело запроса PocketBase, чтобы поставить отметку [choice] (повторное нажатие — снять).
Map<String, String> rsvpChange(String choice, String current, String me) {
  final set = choice == current ? '' : choice;
  return {
    for (final f in const ['going', 'maybe', 'no']) '$f${f == set ? '+' : '-'}': me,
  };
}

const popularGames = ['Dota 2', 'CS2', 'Minecraft', 'Roblox', "Garry's Mod", 'Fortnite', 'Valorant', 'GTA V'];
