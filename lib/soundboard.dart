import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:pocketbase/pocketbase.dart';

import 'api.dart';
import 'call_controller.dart';
import 'settings.dart';
import 'theme.dart';

/// Саундборд: короткие звуки в звонке. Звук не идёт через микрофон —
/// всем участникам приходит сигнал «сыграй звук N», и каждый проигрывает файл у себя.

const soundTopic = 'wc_sound';

class Soundboard extends ChangeNotifier {
  Soundboard._();
  static final Soundboard I = Soundboard._();

  List<RecordModel> sounds = [];
  bool loaded = false;
  bool unsupported = false;
  String? error;

  /// Последний сыгранный звук: кто и какой (для подписи в звонке).
  ({String user, String name, DateTime at})? last;

  final List<Player> _players = [];
  int _next = 0;
  DateTime _lastSent = DateTime(2000);

  RecordModel? byId(String id) {
    for (final s in sounds) {
      if (s.id == id) return s;
    }
    return null;
  }

  static Uri urlOf(RecordModel s) => Api.I.pb.files.getURL(s, s.getStringValue('file'));

  Future<void> load({bool force = false}) async {
    if (loaded && !force) return;
    try {
      sounds = await Api.I.pb.collection('sounds').getFullList(sort: 'created');
      loaded = true;
      unsupported = false;
      error = null;
    } on ClientException catch (e) {
      if (e.statusCode == 404) unsupported = true;
      error = Api.errorText(e, fallback: 'Звуки не загрузились');
    }
    notifyListeners();
  }

  Future<void> _play(RecordModel s) async {
    try {
      if (_players.length < 3) _players.add(Player());
      final p = _players[_next % _players.length];
      _next++;
      await p.setVolume(Settings.I.soundboardVolume.toDouble());
      await p.open(Media(urlOf(s).toString()));
    } catch (e) {
      debugPrint('soundboard: $e');
    }
  }

  /// Сыграть звук всем в звонке.
  Future<String?> send(RecordModel s) async {
    final room = CallController.I.room;
    if (room == null) return 'Сначала зайди в звонок';
    final now = DateTime.now();
    if (now.difference(_lastSent) < const Duration(milliseconds: 1200)) return 'Не так часто 🙂';
    _lastSent = now;
    try {
      await room.localParticipant?.publishData(utf8.encode(jsonEncode({'id': s.id})), reliable: true, topic: soundTopic);
    } catch (e) {
      return 'Звук не отправился: $e';
    }
    last = (user: Api.I.myId, name: '${s.getStringValue('emoji')} ${s.getStringValue('name')}'.trim(), at: now);
    notifyListeners();
    await _play(s);
    return null;
  }

  /// Пришёл сигнал от друга.
  Future<void> onData(String from, List<int> data) async {
    if (!Settings.I.soundboardOn) return;
    String id;
    try {
      final j = jsonDecode(utf8.decode(data));
      id = '${(j as Map)['id']}';
    } catch (_) {
      return;
    }
    var s = byId(id);
    if (s == null) {
      await load(force: true);
      s = byId(id);
    }
    if (s == null) return;
    last = (user: from, name: '${s.getStringValue('emoji')} ${s.getStringValue('name')}'.trim(), at: DateTime.now());
    notifyListeners();
    await _play(s);
  }

  Future<void> add(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['mp3', 'ogg', 'wav', 'm4a', 'opus', 'aac', 'webm', 'flac'], withData: kIsWeb);
    final f = res?.files.firstOrNull;
    if (f == null || !context.mounted) return;
    if (f.size > 1 << 20) {
      toast(context, 'Звук больше 1 МБ — обрежь его до пары секунд');
      return;
    }
    final name = TextEditingController(text: f.name.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' '));
    final emoji = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый звук'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, autofocus: true, maxLength: 30, decoration: const InputDecoration(labelText: 'Название')),
            TextField(controller: emoji, maxLength: 4, decoration: const InputDecoration(labelText: 'Эмодзи (необязательно)', hintText: '💥')),
            Text('Звук увидят все друзья на сервере.', style: W.small),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      final file = f.path != null ? await http.MultipartFile.fromPath('file', f.path!, filename: f.name) : http.MultipartFile.fromBytes('file', f.bytes!, filename: f.name);
      final r = await Api.I.pb.collection('sounds').create(body: {'name': name.text.trim(), 'emoji': emoji.text.trim()}, files: [file]);
      sounds.add(r);
      notifyListeners();
      if (context.mounted) toast(context, 'Звук добавлен 🔊');
    } catch (e) {
      if (context.mounted) toast(context, Api.errorText(e, fallback: 'Звук не загрузился (mp3, ogg, wav, m4a до 1 МБ)'));
    }
  }

  Future<void> delete(RecordModel s) async {
    await Api.I.pb.collection('sounds').delete(s.id);
    sounds.removeWhere((x) => x.id == s.id);
    notifyListeners();
  }
}

/// Панель саундборда (в звонке).
class SoundboardPanel extends StatefulWidget {
  const SoundboardPanel({super.key});

  @override
  State<SoundboardPanel> createState() => _SoundboardPanelState();
}

class _SoundboardPanelState extends State<SoundboardPanel> {
  @override
  void initState() {
    super.initState();
    Soundboard.I.addListener(_changed);
    Settings.I.addListener(_changed);
    Soundboard.I.load(force: true);
  }

  @override
  void dispose() {
    Soundboard.I.removeListener(_changed);
    Settings.I.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sb = Soundboard.I;
    final s = Settings.I;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Саундборд', style: W.h2),
                const Spacer(),
                TextButton.icon(onPressed: () => sb.add(context), icon: const Icon(Icons.add), label: const Text('Свой звук')),
              ],
            ),
            const SizedBox(height: 6),
            if (sb.unsupported)
              Text('Сервер Winter Chat старый — обнови его, чтобы был саундборд.', style: W.small)
            else if (!sb.loaded)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else if (sb.sounds.isEmpty)
              Text('Звуков пока нет. Добавь короткий звук (mp3, ogg, wav до 1 МБ) — его смогут включать все друзья в звонке.', style: W.small)
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final x in sb.sounds)
                        GestureDetector(
                          onLongPress: x.getStringValue('owner') != Api.I.myId
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text('Удалить «${x.getStringValue('name')}»?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Удалить', style: TextStyle(color: W.bad))),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    try {
                                      await sb.delete(x);
                                    } catch (e) {
                                      if (context.mounted) toast(context, Api.errorText(e));
                                    }
                                  }
                                },
                          child: ActionChip(
                            avatar: Text(x.getStringValue('emoji').isEmpty ? '🔊' : x.getStringValue('emoji')),
                            label: Text(x.getStringValue('name')),
                            onPressed: () async {
                              final err = await sb.send(x);
                              if (err != null && context.mounted) toast(context, err);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.volume_down, color: W.muted, size: 20),
                Expanded(
                  child: Slider(value: s.soundboardVolume.toDouble(), min: 0, max: 100, onChanged: (v) => s.soundboardVolume = v.round()),
                ),
                Text('${s.soundboardVolume}%', style: W.small),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Слышать звуки друзей'),
              value: s.soundboardOn,
              onChanged: (v) => s.soundboardOn = v,
            ),
            Text('Зажми свой звук, чтобы удалить его.', style: W.small),
          ],
        ),
      ),
    );
  }
}
