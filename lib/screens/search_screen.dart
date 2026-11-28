import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';
import '../widgets/rich_text.dart';

/// Короткое описание сообщения: текст или что в нём (для цитат, закрепов, поиска).
String messageSnippet(RecordModel m) {
  final text = richPlain(m.getStringValue('text').trim());
  if (text.isNotEmpty) return text.replaceAll('\n', ' ');
  final poll = m.data['poll'];
  if (poll is Map && poll['q'] != null) return '📊 ${poll['q']}';
  if (m.getStringValue('sticker').isNotEmpty) return '🖼 Стикер';
  if (m.data['gif'] is Map) return 'GIF';
  final files = m.getListValue<String>('files');
  if (files.isEmpty) return 'Сообщение';
  final f = files.first;
  return switch (fileKind(f)) {
    FileKind.image => '🖼 Фото',
    FileKind.video => '🎬 Видео',
    FileKind.audio => f.startsWith('voice_') ? '🎤 Голосовое' : '🎵 ${prettyFileName(f)}',
    _ => '📎 ${prettyFileName(f)}',
  };
}

/// Поиск по сообщениям чата.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.chatId});
  final String chatId;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  List<RecordModel> _found = [];
  bool _busy = false;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _search);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) {
      setState(() {
        _found = [];
        _error = null;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final pb = Api.I.pb;
      final res = await pb.collection('messages').getList(
            perPage: 80,
            filter: pb.filter('chat = {:c} && text ~ {:q}', {'c': widget.chatId, 'q': q}),
            sort: '-created',
            skipTotal: true,
          );
      if (!mounted || _q.text.trim() != q) return;
      setState(() {
        _found = res.items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = Api.errorText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toLowerCase();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Найти в чате', border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
          onChanged: _changed,
          onSubmitted: (_) => _search(),
        ),
        actions: [if (_busy) const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))],
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: W.small))
          : _found.isEmpty
              ? Center(
                  child: Text(q.length < 2 ? 'Напиши хотя бы 2 буквы' : (_busy ? '' : 'Ничего не нашлось'), style: W.small),
                )
              : ListView.separated(
                  itemCount: _found.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: W.border, indent: 64),
                  itemBuilder: (_, i) {
                    final m = _found[i];
                    final author = m.getStringValue('author');
                    final d = parseDate(m.getStringValue('created'));
                    return ListTile(
                      leading: UserAvatar(author, size: 38),
                      title: Text(Api.I.nameOf(author), style: TextStyle(color: nameColorFor(author), fontWeight: FontWeight.w700, fontSize: 14)),
                      subtitle: _Highlighted(text: messageSnippet(m), query: q),
                      trailing: Text(d == null ? '' : shortTime(d), style: W.small),
                      onTap: () => showMessageContext(context, widget.chatId, m),
                    );
                  },
                ),
    );
  }
}

class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text, required this.query});
  final String text, query;

  @override
  Widget build(BuildContext context) {
    final lower = text.toLowerCase();
    final i = query.isEmpty ? -1 : lower.indexOf(query);
    if (i < 0 || i + query.length > text.length) return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: W.small);
    // Показываем кусок вокруг совпадения.
    final start = (i - 30).clamp(0, text.length);
    final pre = (start > 0 ? '…' : '') + text.substring(start, i);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: pre),
        TextSpan(text: text.substring(i, i + query.length), style: TextStyle(color: W.ice, fontWeight: FontWeight.w700)),
        TextSpan(text: text.substring(i + query.length)),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: W.small,
    );
  }
}

/// Сообщение с соседними: что писали до и после (для поиска, закрепов, ответов на старые сообщения).
Future<void> showMessageContext(BuildContext context, String chatId, RecordModel target) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.75, child: _ContextView(chatId: chatId, target: target)),
  );
}

class _ContextView extends StatefulWidget {
  const _ContextView({required this.chatId, required this.target});
  final String chatId;
  final RecordModel target;

  @override
  State<_ContextView> createState() => _ContextViewState();
}

class _ContextViewState extends State<_ContextView> {
  List<RecordModel> _items = [];
  bool _loading = true;
  final _targetKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pb = Api.I.pb;
    final t = widget.target.getStringValue('created');
    try {
      final before = await pb.collection('messages').getList(
            perPage: 8,
            filter: pb.filter('chat = {:c} && created < {:t}', {'c': widget.chatId, 't': t}),
            sort: '-created',
            skipTotal: true,
          );
      final after = await pb.collection('messages').getList(
            perPage: 8,
            filter: pb.filter('chat = {:c} && created > {:t}', {'c': widget.chatId, 't': t}),
            sort: 'created',
            skipTotal: true,
          );
      _items = [...before.items.reversed, widget.target, ...after.items];
    } catch (_) {
      _items = [widget.target];
    }
    if (!mounted) return;
    setState(() => _loading = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _targetKey.currentContext;
      if (c != null) Scrollable.ensureVisible(c, alignment: 0.4, duration: const Duration(milliseconds: 250));
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = Store.I.chat(widget.chatId);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
          child: Row(
            children: [
              Expanded(child: Text(chat == null ? 'Переписка' : Api.I.chatTitle(chat), style: W.h2)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  child: Column(
                    children: [
                      for (final m in _items)
                        Container(
                          key: m.id == widget.target.id ? _targetKey : null,
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: m.id == widget.target.id ? W.iceDeep : W.surface2,
                            borderRadius: BorderRadius.circular(12),
                            border: m.id == widget.target.id ? Border.all(color: W.ice) : null,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              UserAvatar(m.getStringValue('author'), size: 30),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            Api.I.nameOf(m.getStringValue('author')),
                                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: nameColorFor(m.getStringValue('author'))),
                                          ),
                                        ),
                                        Text(_when(m), style: W.small),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    SelectableText(messageSnippet(m), style: W.body),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  String _when(RecordModel m) {
    final d = parseDate(m.getStringValue('created'));
    if (d == null) return '';
    return '${dayLabel(d)}, ${hhmm(d)}';
  }
}

/// Закреплённые сообщения чата.
Future<void> showPins(BuildContext context, RecordModel chat) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.6, child: _PinsView(chatId: chat.id)),
  );
}

class _PinsView extends StatefulWidget {
  const _PinsView({required this.chatId});
  final String chatId;

  @override
  State<_PinsView> createState() => _PinsViewState();
}

class _PinsViewState extends State<_PinsView> {
  List<RecordModel> _pins = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = Store.I.chat(widget.chatId)?.getListValue<String>('pins') ?? const [];
    _pins = await loadMessagesByIds(ids);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _unpin(RecordModel m) async {
    try {
      final r = await Api.I.pb.collection('chats').update(widget.chatId, body: {'pins-': m.id});
      Store.I.replaceChat(r);
      setState(() => _pins.removeWhere((x) => x.id == m.id));
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
          child: Row(
            children: [
              Expanded(child: Text('📌 Закреплённые · ${_pins.length}', style: W.h2)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _pins.isEmpty
                  ? Center(child: Text('Нет закреплённых сообщений', style: W.small))
                  : ListView(
                      children: [
                        for (final m in _pins)
                          ListTile(
                            leading: UserAvatar(m.getStringValue('author'), size: 36),
                            title: Text(messageSnippet(m), maxLines: 3, overflow: TextOverflow.ellipsis, style: W.body),
                            subtitle: Text(Api.I.nameOf(m.getStringValue('author')), style: W.small),
                            trailing: IconButton(tooltip: 'Открепить', icon: Icon(Icons.push_pin_outlined, color: W.muted), onPressed: () => _unpin(m)),
                            onTap: () => showMessageContext(context, widget.chatId, m),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }
}

/// Загрузить сообщения по списку id (новые — первыми в порядке списка с конца).
Future<List<RecordModel>> loadMessagesByIds(List<String> ids) async {
  if (ids.isEmpty) return [];
  final pb = Api.I.pb;
  try {
    final filter = ids.map((id) => pb.filter('id = {:i}', {'i': id})).join(' || ');
    final list = await pb.collection('messages').getFullList(filter: filter);
    final byId = {for (final m in list) m.id: m};
    return [for (final id in ids.reversed) if (byId[id] != null) byId[id]!];
  } catch (_) {
    return [];
  }
}
