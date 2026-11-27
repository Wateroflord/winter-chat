/// Статистика Dota 2 друзей через OpenDota (бесплатно, без ключа).
/// Чистая логика — в тестах; запросы — в [OpenDota].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const _steam64Base = 76561197960265728;

/// Номер аккаунта Dota (Steam32) из того, что вставил человек:
/// число, Steam64, ссылка Dotabuff / OpenDota / Stratz / steamcommunity.com/profiles/…
String? parseDotaId(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'(?:dotabuff\.com/players|opendota\.com/players|stratz\.com/players|steamcommunity\.com/profiles)/(\d+)').firstMatch(s);
  final digits = m?.group(1) ?? (RegExp(r'^\d+$').hasMatch(s) ? s : null);
  if (digits == null) return null;
  final n = int.tryParse(digits);
  if (n == null || n <= 0) return null;
  if (n >= _steam64Base) return '${n - _steam64Base}';
  return '$n';
}

const _medals = ['Рекрут', 'Страж', 'Рыцарь', 'Герой', 'Легенда', 'Властелин', 'Божество', 'Титан'];

/// rank_tier OpenDota: 54 → «Легенда 4», 80 → «Титан».
String rankName(int? tier) {
  if (tier == null || tier < 10) return 'Без ранга';
  final medal = tier ~/ 10, star = tier % 10;
  if (medal < 1 || medal > 8) return 'Без ранга';
  final name = _medals[medal - 1];
  return medal == 8 || star == 0 ? name : '$name $star';
}

class DotaMatch {
  final int id, heroId, kills, deaths, assists, duration, start;
  final bool win;
  const DotaMatch({
    required this.id,
    required this.heroId,
    required this.kills,
    required this.deaths,
    required this.assists,
    required this.win,
    this.duration = 0,
    this.start = 0,
  });

  factory DotaMatch.fromJson(Map j) {
    final slot = (j['player_slot'] as num?)?.toInt() ?? 0;
    final radiant = slot < 128;
    return DotaMatch(
      id: (j['match_id'] as num?)?.toInt() ?? 0,
      heroId: (j['hero_id'] as num?)?.toInt() ?? 0,
      kills: (j['kills'] as num?)?.toInt() ?? 0,
      deaths: (j['deaths'] as num?)?.toInt() ?? 0,
      assists: (j['assists'] as num?)?.toInt() ?? 0,
      win: radiant == (j['radiant_win'] == true),
      duration: (j['duration'] as num?)?.toInt() ?? 0,
      start: (j['start_time'] as num?)?.toInt() ?? 0,
    );
  }

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(start * 1000);
  String get kda => '$kills/$deaths/$assists';
}

/// Сводка игрока по списку матчей.
class DotaSummary {
  final int games, wins;
  final double kills, deaths, assists; // в среднем
  final int streak; // + серия побед, − серия поражений (с последнего матча)
  const DotaSummary({this.games = 0, this.wins = 0, this.kills = 0, this.deaths = 0, this.assists = 0, this.streak = 0});

  int get losses => games - wins;
  double get winrate => games == 0 ? 0 : wins / games;
  double get kda => (kills + assists) / (deaths < 1 ? 1 : deaths);
}

/// [matches] — новые первыми (как отдаёт OpenDota).
DotaSummary summarize(List<DotaMatch> matches) {
  if (matches.isEmpty) return const DotaSummary();
  var w = 0, k = 0, d = 0, a = 0;
  for (final m in matches) {
    if (m.win) w++;
    k += m.kills;
    d += m.deaths;
    a += m.assists;
  }
  var streak = 0;
  for (final m in matches) {
    if (streak == 0) {
      streak = m.win ? 1 : -1;
    } else if (m.win == (streak > 0)) {
      streak += streak > 0 ? 1 : -1;
    } else {
      break;
    }
  }
  final n = matches.length;
  return DotaSummary(games: n, wins: w, kills: k / n, deaths: d / n, assists: a / n, streak: streak);
}

/// Матчи за последние [days] дней до [now].
List<DotaMatch> lastDays(List<DotaMatch> matches, DateTime now, {int days = 7}) {
  final from = now.subtract(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;
  return matches.where((m) => m.start >= from).toList();
}

class DotaAward {
  final String emoji, title, userId, value;
  const DotaAward(this.emoji, this.title, this.userId, this.value);
}

String _f1(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Шуточные награды недели среди друзей (нужно хотя бы 3 матча за неделю).
List<DotaAward> weeklyAwards(Map<String, List<DotaMatch>> week) {
  final s = {
    for (final e in week.entries)
      if (e.value.length >= 3) e.key: summarize(e.value),
  };
  if (s.isEmpty) return const [];
  MapEntry<String, DotaSummary> best(num Function(DotaSummary) f) => s.entries.reduce((a, b) => f(b.value) > f(a.value) ? b : a);
  final out = <DotaAward>[];
  final wr = best((x) => x.winrate);
  out.add(DotaAward('👑', 'Король недели', wr.key, '${(wr.value.winrate * 100).round()}% побед'));
  final k = best((x) => x.kills);
  out.add(DotaAward('🔪', 'Мясник', k.key, '${_f1(k.value.kills)} убийств за игру'));
  final a = best((x) => x.assists);
  out.add(DotaAward('🤝', 'Лучший саппорт', a.key, '${_f1(a.value.assists)} помощи за игру'));
  final d = best((x) => x.deaths);
  out.add(DotaAward('💀', 'Кормилец', d.key, '${_f1(d.value.deaths)} смертей за игру'));
  final g = best((x) => x.games);
  out.add(DotaAward('🎮', 'Не вылезает из доты', g.key, '${g.value.games} игр'));
  final st = best((x) => x.streak);
  if (st.value.streak >= 3) out.add(DotaAward('🔥', 'На серии', st.key, '${st.value.streak} побед подряд'));
  return out;
}

/// Профиль игрока для экрана.
class DotaPlayer {
  final String accountId, name, avatar;
  final int? rankTier;
  final List<DotaMatch> recent;
  const DotaPlayer({required this.accountId, this.name = '', this.avatar = '', this.rankTier, this.recent = const []});
}

class DotaError implements Exception {
  final String message;
  const DotaError(this.message);
  @override
  String toString() => message;
}

/// Запросы к api.opendota.com с кешем на 10 минут (бесплатный лимит — 60 запросов в минуту).
class OpenDota {
  OpenDota._();
  static final I = OpenDota._();

  static const _base = 'https://api.opendota.com/api';
  final _cache = <String, (DateTime, Object?)>{};
  Map<int, String> heroes = {};

  Future<Object?> _get(String path) async {
    final c = _cache[path];
    if (c != null && DateTime.now().difference(c.$1) < const Duration(minutes: 10)) return c.$2;
    try {
      final r = await http.get(Uri.parse('$_base$path')).timeout(const Duration(seconds: 20));
      if (r.statusCode == 429) throw const DotaError('OpenDota просит подождать минуту (лимит запросов)');
      if (r.statusCode >= 400) throw DotaError('OpenDota: ошибка ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      _cache[path] = (DateTime.now(), j);
      return j;
    } on TimeoutException {
      throw const DotaError('OpenDota не отвечает');
    } on DotaError {
      rethrow;
    } catch (_) {
      throw const DotaError('Нет связи с OpenDota');
    }
  }

  Future<void> loadHeroes() async {
    if (heroes.isNotEmpty) return;
    final j = await _get('/constants/heroes');
    if (j is Map) {
      heroes = {
        for (final v in j.values)
          if (v is Map && v['id'] is num) (v['id'] as num).toInt(): '${v['localized_name'] ?? ''}',
      };
    }
  }

  String hero(int id) => heroes[id] ?? 'Герой #$id';

  Future<DotaPlayer> player(String accountId) async {
    final p = await _get('/players/$accountId');
    final recent = await _get('/players/$accountId/recentMatches');
    final prof = p is Map ? (p['profile'] as Map?) : null;
    return DotaPlayer(
      accountId: accountId,
      name: '${prof?['personaname'] ?? ''}',
      avatar: '${prof?['avatarmedium'] ?? ''}',
      rankTier: p is Map ? (p['rank_tier'] as num?)?.toInt() : null,
      recent: recent is List ? [for (final m in recent) if (m is Map) DotaMatch.fromJson(m)] : const [],
    );
  }

  void clear() => _cache.clear();
}
