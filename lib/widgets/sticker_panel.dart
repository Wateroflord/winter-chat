import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../theme.dart';

/// Свои стикеры (видны всем друзьям на сервере) и поиск GIF.

class StickerStore extends ChangeNotifier {
  StickerStore._();
  static final StickerStore I = StickerStore._();

  List<RecordModel> stickers = [];
  bool loaded = false;
  bool unsupported = false;
  String? error;
  DateTime _at = DateTime(2000);

  RecordModel? byId(String id) {
    if (id.isEmpty) return null;
    for (final s in stickers) {
      if (s.id == id) return s;
    }
    return null;
  }

  static Uri urlOf(RecordModel st) => Api.I.pb.files.getURL(st, st.getStringValue('file'));

  Future<void>? _inflight;

  Future<void> load({bool force = false}) {
    if (!force && loaded && DateTime.now().difference(_at) < const Duration(minutes: 2)) return Future.value();
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  Future<void> _load() async {
    try {
      stickers = await Api.I.pb.collection('stickers').getFullList(sort: 'pack,created');
      loaded = true;
      unsupported = false;
      error = null;
      _at = DateTime.now();
    } on ClientException catch (e) {
      if (e.statusCode == 404) unsupported = true;
      error = Api.errorText(e, fallback: 'Стикеры не загрузились');
    }
    notifyListeners();
  }

  /// Наборы: «мои» сначала, потом по владельцу и названию.
  List<({String key, String pack, String owner, List<RecordModel> items})> get packs {
    final map = <String, List<RecordModel>>{};
    for (final s in stickers) {
      map.putIfAbsent('${s.getStringValue('owner')}|${s.getStringValue('pack')}', () => []).add(s);
    }
    final out = [
      for (final e in map.entries) (key: e.key, pack: e.value.first.getStringValue('pack'), owner: e.value.first.getStringValue('owner'), items: e.value),
    ];
    final me = Api.I.myId;
    out.sort((a, b) {
      if ((a.owner == me) != (b.owner == me)) return a.owner == me ? -1 : 1;
      final o = Api.I.nameOf(a.owner).compareTo(Api.I.nameOf(b.owner));
      return o != 0 ? o : a.pack.compareTo(b.pack);
    });
    return out;
  }

  List<String> get myPacks => {for (final s in stickers) if (s.getStringValue('owner') == Api.I.myId) s.getStringValue('pack')}.toList();

  // Недавние — на этом устройстве.
  List<String> get recent => Api.I.prefs.getStringList('stickers_recent') ?? const [];

  void used(String id) {
    final r = [id, ...recent.where((x) => x != id)].take(16).toList();
    Api.I.prefs.setStringList('stickers_recent', r);
  }

  Future<void> upload({required String pack, required String name, String? path, Uint8List? bytes, String emoji = ''}) async {
    final f = path != null ? await http.MultipartFile.fromPath('file', path, filename: name) : http.MultipartFile.fromBytes('file', bytes!, filename: name);
    try {
      final r = await Api.I.pb.collection('stickers').create(body: {'pack': pack, 'emoji': emoji}, files: [f]);
      stickers.add(r);
      notifyListeners();
    } catch (e) {
      throw Api.errorText(e, fallback: 'Стикер не загрузился (до 1 МБ: PNG, WebP, GIF, JPG)');
    }
  }

  Future<void> delete(RecordModel st) async {
    await Api.I.pb.collection('stickers').delete(st.id);
    stickers.removeWhere((s) => s.id == st.id);
    notifyListeners();
  }
}

/// Спросить название набора (свой существующий или новый).
Future<String?> askPack(BuildContext context) async {
  final packs = StickerStore.I.myPacks;
  final c = TextEditingController(text: packs.isNotEmpty ? packs.first : 'Мои стикеры');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('В какой набор?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(controller: c, autofocus: true, maxLength: 40, decoration: const InputDecoration(labelText: 'Название набора')),
          if (packs.length > 1)
            Wrap(
              spacing: 6,
              children: [for (final p in packs) ActionChip(label: Text(p), onPressed: () => c.text = p)],
            ),
          const SizedBox(height: 6),
          Text('Твои стикеры увидят и смогут отправлять все друзья на сервере.', style: W.small),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? 'Мои стикеры' : c.text.trim()), child: const Text('Добавить')),
      ],
    ),
  );
}

/// Добавить стикеры из файлов (можно несколько сразу).
Future<void> addStickersFromFiles(BuildContext context) async {
  final res = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: const ['png', 'webp', 'gif', 'jpg', 'jpeg'], withData: kIsWeb);
  if (res == null || res.files.isEmpty || !context.mounted) return;
  final pack = await askPack(context);
  if (pack == null || !context.mounted) return;
  var ok = 0;
  String? err;
  for (final f in res.files) {
    if (f.size > 1 << 20) {
      err = '«${f.name}» больше 1 МБ — уменьши картинку';
      continue;
    }
    try {
      await StickerStore.I.upload(pack: pack, name: f.name, path: f.path, bytes: f.bytes);
      ok++;
    } catch (e) {
      err = '$e';
    }
  }
  if (context.mounted) toast(context, err ?? (ok == 1 ? 'Стикер добавлен ✨' : 'Добавлено стикеров: $ok ✨'));
}

/// «В стикеры» из картинки в чате.
Future<void> saveImageAsSticker(BuildContext context, Uri url, String name) async {
  try {
    final r = await http.get(url).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw 'Картинка не скачалась';
    if (r.bodyBytes.length > 1 << 20) throw 'Картинка больше 1 МБ — стикер должен быть меньше';
    if (!context.mounted) return;
    await StickerStore.I.load();
    if (!context.mounted) return;
    final pack = await askPack(context);
    if (pack == null) return;
    await StickerStore.I.upload(pack: pack, name: name, bytes: r.bodyBytes);
    if (context.mounted) toast(context, 'Добавлено в стикеры ✨');
  } catch (e) {
    if (context.mounted) toast(context, '$e');
  }
}

/// Панель стикеров и GIF под полем ввода.
class StickerPanel extends StatefulWidget {
  const StickerPanel({super.key, required this.onSticker, required this.onGif});
  final void Function(RecordModel sticker) onSticker;
  final void Function(Map<String, dynamic> gif) onGif;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  int _tab = 0; // 0 — стикеры, 1 — GIF
  String? _pack; // ключ набора, null — «недавние/все»
  final _q = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _gifs = [];
  bool? _gifsOn;
  bool _gifBusy = false;
  String? _gifError;

  @override
  void initState() {
    super.initState();
    StickerStore.I.addListener(_changed);
    StickerStore.I.load();
  }

  @override
  void dispose() {
    StickerStore.I.removeListener(_changed);
    _debounce?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _searchGifs() async {
    setState(() {
      _gifBusy = true;
      _gifError = null;
    });
    try {
      final r = await Api.I.searchGifs(_q.text.trim());
      _gifsOn = r != null;
      _gifs = r ?? [];
    } catch (e) {
      _gifError = '$e';
    }
    if (mounted) setState(() => _gifBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      decoration: BoxDecoration(color: W.surface, border: Border(top: BorderSide(color: W.border))),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              ChoiceChip(label: const Text('Стикеры'), selected: _tab == 0, onSelected: (_) => setState(() => _tab = 0)),
              const SizedBox(width: 6),
              ChoiceChip(
                label: const Text('GIF'),
                selected: _tab == 1,
                onSelected: (_) {
                  setState(() => _tab = 1);
                  if (_gifsOn == null) _searchGifs();
                },
              ),
              const Spacer(),
              if (_tab == 0)
                TextButton.icon(onPressed: () => addStickersFromFiles(context), icon: const Icon(Icons.add_photo_alternate_outlined, size: 18), label: const Text('Свой стикер')),
              const SizedBox(width: 4),
            ],
          ),
          Expanded(child: _tab == 0 ? _stickers() : _gifTab()),
        ],
      ),
    );
  }

  Widget _stickers() {
    final st = StickerStore.I;
    if (st.unsupported) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text('Сервер Winter Chat старый — обнови его, чтобы были стикеры.', style: W.small, textAlign: TextAlign.center)));
    if (!st.loaded) return Center(child: st.error != null ? Text(st.error!, style: W.small) : const CircularProgressIndicator());
    final packs = st.packs;
    if (packs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Стикеров пока нет. Нарисуй свои — PNG с прозрачным фоном до 1 МБ, можно GIF.', style: W.small, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              FilledButton.icon(onPressed: () => addStickersFromFiles(context), icon: const Icon(Icons.add), label: const Text('Добавить стикеры')),
            ],
          ),
        ),
      );
    }
    final recent = [for (final id in st.recent) if (st.byId(id) != null) st.byId(id)!];
    final selected = _pack == null ? null : packs.where((p) => p.key == _pack).firstOrNull;
    final items = selected?.items ?? (recent.isNotEmpty ? recent : packs.first.items);
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (recent.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: const Text('🕘 Недавние'), selected: _pack == null, onSelected: (_) => setState(() => _pack = null)),
                ),
              for (final p in packs)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(p.owner == Api.I.myId ? p.pack : '${p.pack} · ${Api.I.nameOf(p.owner)}'),
                    selected: _pack == p.key || (_pack == null && recent.isEmpty && p == packs.first),
                    onSelected: (_) => setState(() => _pack = p.key),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 86, mainAxisSpacing: 6, crossAxisSpacing: 6),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final s = items[i];
              final mine = s.getStringValue('owner') == Api.I.myId;
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  st.used(s.id);
                  widget.onSticker(s);
                },
                onLongPress: !mine
                    ? null
                    : () async {
                        if (!await _confirmDelete()) return;
                        try {
                          await st.delete(s);
                        } catch (e) {
                          if (mounted) toast(context, Api.errorText(e));
                        }
                      },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.network(StickerStore.urlOf(s).toString(), fit: BoxFit.contain, errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, color: W.muted)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<bool> _confirmDelete() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Удалить стикер?'),
          content: const Text('Он пропадёт из набора у всех. В старых сообщениях будет «стикер удалён».'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Удалить', style: TextStyle(color: W.bad))),
          ],
        ),
      ) ==
      true;

  Widget _gifTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: TextField(
            controller: _q,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Найти GIF',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 450), _searchGifs);
            },
            onSubmitted: (_) => _searchGifs(),
          ),
        ),
        Expanded(
          child: _gifsOn == false
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Поиск GIF на сервере выключен. Хозяин сервера может включить его: панель сервера → «Поиск GIF» (нужен бесплатный ключ Giphy).\n\nА пока — отправляй GIF файлом или добавь их в свои стикеры.',
                      style: W.small,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _gifBusy && _gifs.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _gifError != null
                      ? Center(child: Text(_gifError!, style: W.small, textAlign: TextAlign.center))
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 6, crossAxisSpacing: 6),
                          itemCount: _gifs.length,
                          itemBuilder: (_, i) {
                            final g = _gifs[i];
                            return InkWell(
                              onTap: () => widget.onGif({'url': g['url'], 'w': g['w'], 'h': g['h']}),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network('${g['preview'] ?? g['url']}', fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: W.surface2)),
                              ),
                            );
                          },
                        ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('GIF — Giphy', style: TextStyle(fontSize: 10.5, color: W.muted)),
        ),
      ],
    );
  }
}
