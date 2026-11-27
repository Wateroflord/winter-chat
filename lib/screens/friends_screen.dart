import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../dota.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart' show askText, confirm, openUrl;
import 'friends_logic.dart';

String _pbDate(DateTime d) => d.toUtc().toIso8601String().replaceFirst('T', ' ');

String _err(Object e) {
  if (e is ClientException && e.statusCode == 404) return 'На сервере нет этого раздела — обнови сервер Winter Chat через Winter Hub.';
  return Api.errorText(e);
}

/// Раздел «Друзья»: игровые вечера, статистика Dota, Winter Cloud.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key, this.tab = 0});
  final int tab;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        initialIndex: tab,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Друзья'),
            bottom: const TabBar(tabs: [
              Tab(text: '🎮 Вечера'),
              Tab(text: '📊 Dota'),
              Tab(text: '☁ Облако'),
            ]),
          ),
          body: const TabBarView(children: [NightsTab(), DotaTab(), CloudTab()]),
        ),
      );
}

Widget _errorCard(String text, VoidCallback retry) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(text, style: W.body, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: retry, child: const Text('Повторить')),
      ]),
    );

/// Подписка на изменения коллекции (realtime) — список обновляется сам.
mixin _Live<T extends StatefulWidget> on State<T> {
  UnsubscribeFunc? _unsub;
  Timer? _debounce;

  Future<void> reload();

  Future<void> live(String collection) async {
    try {
      _unsub = await Api.I.pb.collection(collection).subscribe('*', (_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 400), () {
          if (mounted) reload();
        });
      });
    } catch (_) {}
  }

  void stopLive() {
    _debounce?.cancel();
    final u = _unsub;
    _unsub = null;
    if (u != null) unawaited(u().catchError((_) {}));
  }
}

// ───────────────────────────── Игровые вечера ─────────────────────────────

class NightsTab extends StatefulWidget {
  const NightsTab({super.key});

  @override
  State<NightsTab> createState() => _NightsTabState();
}

class _NightsTabState extends State<NightsTab> with _Live<NightsTab>, AutomaticKeepAliveClientMixin {
  List<RecordModel> nights = [];
  bool loading = true;
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
    live('game_nights');
  }

  @override
  void dispose() {
    stopLive();
    super.dispose();
  }

  @override
  Future<void> reload() async {
    try {
      final from = DateTime.now().subtract(const Duration(hours: 6));
      nights = await Api.I.pb.collection('game_nights').getFullList(sort: 'at', filter: "at >= '${_pbDate(from)}'");
      error = null;
    } catch (e) {
      error = _err(e);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _rsvp(RecordModel n, String choice) async {
    final me = Api.I.myId;
    final cur = myRsvp(
      going: n.getListValue<String>('going'),
      maybe: n.getListValue<String>('maybe'),
      no: n.getListValue<String>('no'),
      me: me,
    );
    try {
      final upd = await Api.I.pb.collection('game_nights').update(n.id, body: rsvpChange(choice, cur, me));
      nights = [for (final x in nights) x.id == n.id ? upd : x];
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) toast(context, _err(e));
    }
  }

  Future<void> _edit([RecordModel? n]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _NightEditor(night: n),
    );
    if (r == null) return;
    try {
      if (n == null) {
        await Api.I.pb.collection('game_nights').create(body: r);
      } else {
        await Api.I.pb.collection('game_nights').update(n.id, body: r);
      }
      await reload();
    } catch (e) {
      if (mounted) toast(context, _err(e));
    }
  }

  Future<void> _delete(RecordModel n) async {
    if (!await confirm(context, 'Отменить вечер?', '«${n.getStringValue('game')}» пропадёт у всех.')) return;
    try {
      await Api.I.pb.collection('game_nights').delete(n.id);
      await reload();
    } catch (e) {
      if (mounted) toast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'night-add',
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Позвать играть'),
      ),
      body: RefreshIndicator(
        onRefresh: reload,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 96), children: [
          if (loading)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (error != null)
            _errorCard(error!, reload)
          else if (nights.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text(
                'Пока никто никого не позвал.\nНажми «Позвать играть» — выбери игру и время, друзья отметятся.',
                style: W.small,
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final n in nights) _card(n),
        ]),
      ),
    );
  }

  Widget _card(RecordModel n) {
    final me = Api.I.myId;
    final at = parseDate(n.getStringValue('at')) ?? DateTime.now();
    final going = n.getListValue<String>('going');
    final maybe = n.getListValue<String>('maybe');
    final no = n.getListValue<String>('no');
    final mine = myRsvp(going: going, maybe: maybe, no: no, me: me);
    final author = n.getStringValue('author');
    final soon = at.difference(DateTime.now()).inMinutes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: W.surface2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: soon >= -180 && soon <= 60 ? W.ice : W.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.getStringValue('game'), style: W.h2),
                Text(
                  '${nightWhen(at, DateTime.now())}${soon > 0 && soon <= 60 ? ' · через $soon мин' : ''}${soon <= 0 && soon >= -180 ? ' · уже идёт' : ''}',
                  style: W.body.copyWith(color: W.ice),
                ),
              ]),
            ),
            if (author == me)
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: W.muted),
                onSelected: (v) => v == 'edit' ? _edit(n) : _delete(n),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Изменить')),
                  PopupMenuItem(value: 'delete', child: Text('Отменить вечер')),
                ],
              ),
          ]),
          if (n.getStringValue('note').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(n.getStringValue('note'), style: W.body),
          ],
          const SizedBox(height: 4),
          Text('Позвал(а): ${author == me ? 'ты' : Api.I.nameOf(author)}', style: W.small),
          const SizedBox(height: 10),
          _people('Идут', going, W.good),
          if (maybe.isNotEmpty) _people('Может быть', maybe, W.warn),
          if (no.isNotEmpty) _people('Не смогут', no, W.bad),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _rsvpButton(n, 'going', '✅ Иду', mine),
            _rsvpButton(n, 'maybe', '🤔 Может быть', mine),
            _rsvpButton(n, 'no', '❌ Не смогу', mine),
          ]),
          if (mine == 'going' && soon > 30)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('🔔 Напомню за 30 минут до начала', style: W.small),
            ),
        ]),
      ),
    );
  }

  Widget _people(String title, List<String> ids, Color c) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(width: 92, child: Text('$title (${ids.length})', style: W.small.copyWith(color: c))),
          Expanded(
            child: ids.isEmpty
                ? Text('пока никого', style: W.small)
                : Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final id in ids)
                      Tooltip(message: Api.I.nameOf(id), child: UserAvatar(id, size: 26)),
                  ]),
          ),
        ]),
      );

  Widget _rsvpButton(RecordModel n, String v, String text, String mine) {
    final on = mine == v;
    return on
        ? FilledButton(onPressed: () => _rsvp(n, v), child: Text(text))
        : OutlinedButton(onPressed: () => _rsvp(n, v), child: Text(text));
  }
}

class _NightEditor extends StatefulWidget {
  const _NightEditor({this.night});
  final RecordModel? night;

  @override
  State<_NightEditor> createState() => _NightEditorState();
}

class _NightEditorState extends State<_NightEditor> {
  late final game = TextEditingController(text: widget.night?.getStringValue('game') ?? '');
  late final note = TextEditingController(text: widget.night?.getStringValue('note') ?? '');
  late DateTime at;

  @override
  void initState() {
    super.initState();
    final saved = parseDate(widget.night?.getStringValue('at') ?? '');
    if (saved != null) {
      at = saved;
    } else {
      // По умолчанию — сегодня в 20:00 (или завтра, если уже поздно).
      final n = DateTime.now();
      at = DateTime(n.year, n.month, n.day, 20);
      if (at.isBefore(n.add(const Duration(minutes: 30)))) at = at.add(const Duration(days: 1));
    }
  }

  @override
  void dispose() {
    game.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: at,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 180)),
    );
    if (d != null) setState(() => at = DateTime(d.year, d.month, d.day, at.hour, at.minute));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(at),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t != null) setState(() => at = DateTime(at.year, at.month, at.day, t.hour, t.minute));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.night == null ? 'Позвать играть' : 'Изменить вечер', style: W.h2),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final g in popularGames)
                ChoiceChip(
                  label: Text(g),
                  selected: game.text == g,
                  onSelected: (_) => setState(() => game.text = g),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: game,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Во что играем', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDay,
                  icon: const Icon(Icons.event),
                  label: Text(nightWhen(at, DateTime.now()).split(' в ').first),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(onPressed: _pickTime, icon: const Icon(Icons.schedule), label: Text(hhmm(at))),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Подробности (необязательно)',
                hintText: 'Турбо, пати из 5, заходим в войс',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: game.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, {'game': game.text.trim(), 'note': note.text.trim(), 'at': _pbDate(at)}),
              child: Text(widget.night == null ? 'Позвать всех' : 'Сохранить'),
            ),
          ]),
        ),
      );
}

// ───────────────────────────── Dota ─────────────────────────────

class DotaTab extends StatefulWidget {
  const DotaTab({super.key});

  @override
  State<DotaTab> createState() => _DotaTabState();
}

class _DotaTabState extends State<DotaTab> with AutomaticKeepAliveClientMixin {
  final od = OpenDota.I;
  bool loading = true;
  String? error;
  final players = <String, DotaPlayer>{}; // userId → игрок
  final failed = <String, String>{}; // userId → ошибка

  @override
  bool get wantKeepAlive => true;

  String get myDota => Api.I.me.getStringValue('dota_id');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    if (fresh) od.clear();
    loading = true;
    if (fresh && mounted) setState(() {});
    try {
      await Api.I.loadUsers();
      await od.loadHeroes();
      error = null;
    } catch (e) {
      error = e is DotaError ? e.message : _err(e);
    }
    final withId = {
      for (final u in Api.I.users.values)
        if (u.getStringValue('dota_id').isNotEmpty) u.id: u.getStringValue('dota_id'),
    };
    players.removeWhere((k, _) => !withId.containsKey(k));
    await Future.wait([
      for (final e in withId.entries)
        od.player(e.value).then((p) {
          players[e.key] = p;
          failed.remove(e.key);
        }).catchError((Object err) {
          failed[e.key] = '$err';
        }),
    ]);
    if (mounted) setState(() => loading = false);
  }

  Future<void> _setMyId() async {
    final s = await askText(context, 'Номер аккаунта Dota 2 (Friend ID) или ссылка на Dotabuff', initial: myDota);
    if (s == null) return;
    final id = s.trim().isEmpty ? '' : parseDotaId(s);
    if (id == null) {
      if (mounted) toast(context, 'Не понял номер. Вставь Friend ID из Доты (цифры) или ссылку dotabuff.com/players/…');
      return;
    }
    try {
      final r = await Api.I.pb.collection('users').update(Api.I.myId, body: {'dota_id': id});
      Api.I.pb.authStore.save(Api.I.pb.authStore.token, r);
      Api.I.users[r.id] = r;
      await _load();
    } catch (e) {
      if (mounted) toast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final now = DateTime.now();
    final week = {for (final e in players.entries) e.key: lastDays(e.value.recent, now)};
    final awards = weeklyAwards(week);
    final order = players.keys.toList()
      ..sort((a, b) {
        final sa = summarize(week[a] ?? const []), sb = summarize(week[b] ?? const []);
        final c = sb.winrate.compareTo(sa.winrate);
        return c != 0 ? c : sb.games.compareTo(sa.games);
      });
    return RefreshIndicator(
      onRefresh: () => _load(fresh: true),
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 32), children: [
        if (myDota.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(16), border: Border.all(color: W.ice)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Добавь свой аккаунт Dota 2', style: W.h2),
              const SizedBox(height: 4),
              Text(
                'В Доте: Профиль → номер под ником (Friend ID). Или ссылка на Dotabuff. '
                'Чтобы матчи было видно, в настройках Доты включи «Общедоступные данные матчей».',
                style: W.small,
              ),
              const SizedBox(height: 10),
              FilledButton(onPressed: _setMyId, child: const Text('Указать номер')),
            ]),
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(onPressed: _setMyId, icon: const Icon(Icons.edit, size: 16), label: Text('Мой номер: $myDota')),
          ),
        if (error != null) _errorCard(error!, () => _load(fresh: true)),
        if (loading && players.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (awards.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Награды недели', style: W.h2),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in awards)
              Container(
                width: 170,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(14), border: Border.all(color: W.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${a.emoji} ${a.title}', style: W.small.copyWith(color: W.ice, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Row(children: [
                    UserAvatar(a.userId, size: 22),
                    const SizedBox(width: 6),
                    Expanded(child: Text(Api.I.nameOf(a.userId), style: W.body, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                  Text(a.value, style: W.small),
                ]),
              ),
          ]),
        ],
        if (players.isNotEmpty || failed.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('За 7 дней', style: W.h2),
          const SizedBox(height: 8),
        ],
        for (final id in order) _playerCard(id, players[id]!, week[id] ?? const []),
        for (final e in failed.entries)
          ListTile(
            leading: UserAvatar(e.key, size: 36),
            title: Text(Api.I.nameOf(e.key)),
            subtitle: Text(e.value, style: W.small),
          ),
        if (!loading && players.isEmpty && failed.isEmpty && myDota.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text('Пусть друзья тоже укажут свои номера здесь — появится общий рейтинг и награды.', style: W.small, textAlign: TextAlign.center),
          ),
        const SizedBox(height: 16),
        Text('Данные — OpenDota. Обновляются раз в 10 минут, потяни вниз.', style: W.small, textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _playerCard(String userId, DotaPlayer p, List<DotaMatch> week) {
    final s = summarize(week);
    final last = p.recent.isEmpty ? null : p.recent.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _matches(userId, p),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(16), border: Border.all(color: W.border)),
          child: Row(children: [
            UserAvatar(userId, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(Api.I.nameOf(userId), style: W.h2.copyWith(fontSize: 16)),
                Text(
                  [rankName(p.rankTier), if (p.name.isNotEmpty) p.name].join(' · '),
                  style: W.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (last != null)
                  Text(
                    'Последняя: ${od.hero(last.heroId)} ${last.kda} ${last.win ? '✅' : '❌'}',
                    style: W.small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (p.recent.isEmpty) Text('Матчей не видно — профиль скрыт в настройках Доты', style: W.small.copyWith(color: W.warn)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(s.games == 0 ? '—' : '${(s.winrate * 100).round()}%', style: W.h2.copyWith(color: s.winrate >= 0.5 ? W.good : W.bad)),
              Text(s.games == 0 ? 'не играл' : '${s.wins}–${s.losses}', style: W.small),
              if (s.games > 0) Text('KDA ${s.kda.toStringAsFixed(1).replaceAll('.', ',')}', style: W.small),
            ]),
          ]),
        ),
      ),
    );
  }

  void _matches(String userId, DotaPlayer p) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
          Text('${Api.I.nameOf(userId)} — последние матчи', style: W.h2),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => openUrl(context, Uri.parse('https://www.opendota.com/players/${p.accountId}')),
            child: const Text('Открыть на OpenDota'),
          ),
          for (final m in p.recent)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Text(m.win ? '✅' : '❌', style: const TextStyle(fontSize: 18)),
              title: Text(od.hero(m.heroId)),
              subtitle: Text('${dayLabel(m.date)} · ${m.duration ~/ 60} мин', style: W.small),
              trailing: Text(m.kda, style: W.body),
              onTap: () => openUrl(context, Uri.parse('https://www.opendota.com/matches/${m.id}')),
            ),
        ]),
      ),
    );
  }
}

// ───────────────────────────── Winter Cloud ─────────────────────────────

class CloudTab extends StatefulWidget {
  const CloudTab({super.key});

  @override
  State<CloudTab> createState() => _CloudTabState();
}

class _CloudTabState extends State<CloudTab> with _Live<CloudTab>, AutomaticKeepAliveClientMixin {
  List<RecordModel> files = [];
  bool loading = true;
  String? error;
  String filter = 'all'; // all | mine | media | other
  String? uploading;
  int used = 0, limit = 0, fileMax = 500 << 20;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
    live('cloud_files');
  }

  @override
  void dispose() {
    stopLive();
    super.dispose();
  }

  @override
  Future<void> reload() async {
    try {
      files = await Api.I.pb.collection('cloud_files').getFullList(sort: '-created');
      error = null;
      try {
        final j = await Api.I.pb.send('/api/wc/cloud');
        if (j is Map) {
          used = (j['used'] as num?)?.toInt() ?? 0;
          limit = (j['limit'] as num?)?.toInt() ?? 0;
          fileMax = (j['fileMax'] as num?)?.toInt() ?? fileMax;
        }
      } catch (_) {
        // Старый сервер без лимитов — просто не показываем место.
      }
    } catch (e) {
      error = _err(e);
    }
    if (mounted) setState(() => loading = false);
  }

  String _name(RecordModel r) {
    final n = r.getStringValue('name');
    return n.isNotEmpty ? n : prettyFileName(r.getStringValue('file'));
  }

  Future<void> _upload() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(allowMultiple: true);
    } catch (e) {
      if (mounted) toast(context, 'Не удалось выбрать файл: $e');
      return;
    }
    final picked = res?.files.where((f) => f.path != null || f.bytes != null).toList() ?? [];
    final big = picked.where((f) => f.size > fileMax).toList();
    final list = picked.where((f) => f.size <= fileMax).toList();
    if (big.isNotEmpty && mounted) {
      toast(context, 'Больше ${humanSize(fileMax)} в облако нельзя: ${big.map((f) => f.name).join(', ')}');
    }
    if (list.isEmpty) return;
    final need = list.fold<int>(0, (s, f) => s + f.size);
    if (limit > 0 && used + need > limit) {
      if (mounted) toast(context, 'Не хватит места: свободно ${humanSize(limit - used)}, а файлы весят ${humanSize(need)}');
      return;
    }
    var done = 0;
    for (final f in list) {
      setState(() => uploading = 'Загружаю ${done + 1} из ${list.length}: ${f.name}');
      try {
        final mp = f.path != null
            ? await http.MultipartFile.fromPath('file', f.path!, filename: f.name)
            : http.MultipartFile.fromBytes('file', f.bytes!, filename: f.name);
        await Api.I.pb.collection('cloud_files').create(body: {'name': f.name}, files: [mp]);
        done++;
      } catch (e) {
        if (mounted) toast(context, '${f.name}: ${_err(e)}');
      }
    }
    if (!mounted) return;
    setState(() => uploading = null);
    if (done > 0) toast(context, done == 1 ? 'Файл в облаке' : 'Загружено файлов: $done');
    await reload();
  }

  Future<void> _menu(RecordModel r) async {
    final mine = r.getStringValue('owner') == Api.I.myId;
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(_name(r), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ListTile(leading: const Icon(Icons.download), title: const Text('Скачать'), onTap: () => Navigator.pop(c, 'get')),
          if (mine) ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Переименовать'), onTap: () => Navigator.pop(c, 'rename')),
          if (mine)
            ListTile(leading: Icon(Icons.delete_outline, color: W.bad), title: const Text('Удалить из облака'), onTap: () => Navigator.pop(c, 'delete')),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    try {
      switch (a) {
        case 'get':
          await openUrl(context, Api.I.fileUrl(r, r.getStringValue('file'), download: true));
        case 'rename':
          final n = await askText(context, 'Название', initial: _name(r));
          if (n == null || n.trim().isEmpty) return;
          await Api.I.pb.collection('cloud_files').update(r.id, body: {'name': n.trim()});
          await reload();
        case 'delete':
          if (!await confirm(context, 'Удалить файл?', '«${_name(r)}» пропадёт у всех.')) return;
          await Api.I.pb.collection('cloud_files').delete(r.id);
          await reload();
      }
    } catch (e) {
      if (mounted) toast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final me = Api.I.myId;
    final shown = files.where((r) {
      final k = fileKind(r.getStringValue('file'));
      return switch (filter) {
        'mine' => r.getStringValue('owner') == me,
        'media' => k == FileKind.image || k == FileKind.video,
        'other' => k == FileKind.other || k == FileKind.audio,
        _ => true,
      };
    }).toList();
    final total = files.fold<int>(0, (s, r) => s + r.getIntValue('size'));
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'cloud-add',
        onPressed: uploading == null ? _upload : null,
        icon: const Icon(Icons.upload_file),
        label: const Text('Загрузить'),
      ),
      body: RefreshIndicator(
        onRefresh: reload,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 96), children: [
          Wrap(spacing: 6, children: [
            for (final f in const [('all', 'Все'), ('mine', 'Мои'), ('media', 'Фото и видео'), ('other', 'Файлы')])
              ChoiceChip(label: Text(f.$2), selected: filter == f.$1, onSelected: (_) => setState(() => filter = f.$1)),
          ]),
          const SizedBox(height: 6),
          Text('Файлы видят и качают все на сервере. Всего: ${files.length} · ${humanSize(total)}', style: W.small),
          if (limit > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (used / limit).clamp(0, 1).toDouble(),
                minHeight: 6,
                backgroundColor: W.border,
                color: used > limit * 0.9 ? W.bad : W.ice,
              ),
            ),
            const SizedBox(height: 4),
            Text('Занято ${humanSize(used)} из ${humanSize(limit)} · один файл — до ${humanSize(fileMax)}', style: W.small),
          ],
          if (uploading != null) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            const SizedBox(height: 4),
            Text(uploading!, style: W.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 8),
          if (loading)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (error != null)
            _errorCard(error!, reload)
          else if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text('Тут пусто. Закинь сюда скрины, моды, сохранения, видео с катки — друзья скачают.',
                  style: W.small, textAlign: TextAlign.center),
            )
          else
            for (final r in shown) _tile(r),
        ]),
      ),
    );
  }

  Widget _tile(RecordModel r) {
    final file = r.getStringValue('file');
    final k = fileKind(file);
    final owner = r.getStringValue('owner');
    final when = parseDate(r.getStringValue('created'));
    final icon = switch (k) {
      FileKind.video => Icons.movie_outlined,
      FileKind.audio => Icons.audiotrack,
      FileKind.image => Icons.image_outlined,
      FileKind.other => Icons.insert_drive_file_outlined,
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 48,
          height: 48,
          child: k == FileKind.image
              ? Image.network(
                  Api.I.fileUrl(r, file, thumb: '480x0').toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(icon, color: W.ice),
                )
              : Container(color: W.surface2, child: Icon(icon, color: W.ice)),
        ),
      ),
      title: Text(_name(r), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${humanSize(r.getIntValue('size'))} · ${owner == Api.I.myId ? 'ты' : Api.I.nameOf(owner)}${when != null ? ' · ${shortTime(when)}' : ''}',
        style: W.small,
      ),
      trailing: IconButton(
        tooltip: 'Скачать',
        icon: const Icon(Icons.download),
        onPressed: () => openUrl(context, Api.I.fileUrl(r, file, download: true)),
      ),
      onTap: () => _menu(r),
    );
  }
}
