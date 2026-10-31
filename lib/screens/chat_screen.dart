import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../call_controller.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';
import 'home_screen.dart';
import 'people_sheet.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.embedded = false});
  final String chatId;
  final bool embedded;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<RecordModel> _msgs = []; // от новых к старым
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  UnsubscribeFunc? _unsub;
  Timer? _poll;

  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final List<PlatformFile> _pending = [];
  bool _sending = false;
  RecordModel? _editing;

  PocketBase get _pb => Api.I.pb;
  RecordModel? get _chat => Store.I.chat(widget.chatId);
  bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    Store.I.addListener(_changed);
    CallController.I.addListener(_changed);
    _scroll.addListener(_onScroll);
    _load();
    _subscribe();
    _poll = Timer.periodic(const Duration(seconds: 25), (_) => _fetchNewest());
  }

  @override
  void dispose() {
    Store.I.removeListener(_changed);
    CallController.I.removeListener(_changed);
    _poll?.cancel();
    _unsub?.call();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _markRead();
  }

  void _markRead() {
    final c = _chat;
    if (c != null && Api.I.markRead(c)) {
      Future.microtask(Store.I.ping);
    }
  }

  String get _filter => _pb.filter('chat = {:c}', {'c': widget.chatId});

  Future<void> _load() async {
    try {
      final res = await _pb.collection('messages').getList(page: 1, perPage: 50, filter: _filter, sort: '-created', skipTotal: true);
      _msgs
        ..clear()
        ..addAll(res.items);
      _hasMore = res.items.length == 50;
      _error = null;
    } catch (e) {
      _error = Api.errorText(e, fallback: 'Не удалось загрузить сообщения');
    }
    _loading = false;
    if (mounted) setState(() {});
    _markRead();
  }

  Future<void> _fetchNewest() async {
    if (_loading) return;
    try {
      final res = await _pb.collection('messages').getList(page: 1, perPage: 30, filter: _filter, sort: '-created', skipTotal: true);
      var changed = false;
      for (final m in res.items) {
        if (_upsert(m)) changed = true;
      }
      if (changed && mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _msgs.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final oldest = _msgs.last.getStringValue('created');
      final res = await _pb.collection('messages').getList(
            page: 1,
            perPage: 50,
            filter: _pb.filter('chat = {:c} && created < {:t}', {'c': widget.chatId, 't': oldest}),
            sort: '-created',
            skipTotal: true,
          );
      _msgs.addAll(res.items.where((m) => !_msgs.any((x) => x.id == m.id)));
      _hasMore = res.items.length == 50;
    } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _subscribe() async {
    try {
      _unsub = await _pb.collection('messages').subscribe('*', (e) {
        final r = e.record;
        if (r == null || r.getStringValue('chat') != widget.chatId) return;
        if (e.action == 'delete') {
          _msgs.removeWhere((m) => m.id == r.id);
        } else {
          _upsert(r);
        }
        if (mounted) setState(() {});
      }, filter: _filter);
    } catch (_) {}
  }

  /// Добавить или заменить сообщение, сохраняя порядок от новых к старым.
  bool _upsert(RecordModel m) {
    final i = _msgs.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      if (_msgs[i].getStringValue('updated') == m.getStringValue('updated')) return false;
      _msgs[i] = m;
      return true;
    }
    final created = m.getStringValue('created');
    var pos = _msgs.indexWhere((x) => x.getStringValue('created').compareTo(created) < 0);
    if (pos < 0) pos = _msgs.length;
    _msgs.insert(pos, m);
    return true;
  }

  // ---------- отправка ----------

  Future<void> _pickFiles({FileType type = FileType.any}) async {
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true, type: type);
      if (res == null) return;
      setState(() => _pending.addAll(res.files.where((f) => f.path != null || f.bytes != null)));
    } catch (e) {
      if (mounted) toast(context, 'Не удалось выбрать файл: $e');
    }
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _text.text.trim();
    if (_editing != null) {
      await _saveEdit(text);
      return;
    }
    if (text.isEmpty && _pending.isEmpty) return;
    setState(() => _sending = true);
    final files = List<PlatformFile>.from(_pending);
    try {
      // не больше 10 файлов в одном сообщении
      var first = true;
      var rest = files;
      do {
        final batch = rest.take(10).toList();
        rest = rest.skip(10).toList();
        final multipart = <http.MultipartFile>[];
        for (final f in batch) {
          if (f.path != null) {
            multipart.add(await http.MultipartFile.fromPath('files', f.path!, filename: f.name));
          } else if (f.bytes != null) {
            multipart.add(http.MultipartFile.fromBytes('files', f.bytes!, filename: f.name));
          }
        }
        final rec = await _pb.collection('messages').create(
          body: {'chat': widget.chatId, 'text': first ? text : ''},
          files: multipart,
        );
        _upsert(rec);
        first = false;
      } while (rest.isNotEmpty);
      _text.clear();
      _pending.clear();
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось отправить'));
    }
    if (mounted) {
      setState(() => _sending = false);
      _focus.requestFocus();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  Future<void> _saveEdit(String text) async {
    final m = _editing!;
    setState(() => _sending = true);
    try {
      final rec = await _pb.collection('messages').update(m.id, body: {'text': text});
      _upsert(rec);
      _editing = null;
      _text.clear();
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось изменить'));
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _delete(RecordModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщение?'),
        content: const Text('Оно пропадёт у всех.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить', style: TextStyle(color: W.bad))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _pb.collection('messages').delete(m.id);
      setState(() => _msgs.removeWhere((x) => x.id == m.id));
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось удалить'));
    }
  }

  Future<void> _messageMenu(RecordModel m, Offset? at) async {
    final mine = m.getStringValue('author') == Api.I.myId;
    final text = m.getStringValue('text');
    final files = m.getListValue<String>('files');
    final items = <(String, IconData, String)>[
      if (text.isNotEmpty) ('copy', Icons.copy, 'Копировать текст'),
      for (final f in files) ('save:$f', Icons.download, 'Скачать ${prettyFileName(f)}'),
      if (mine && text.isNotEmpty) ('edit', Icons.edit, 'Изменить'),
      if (mine) ('delete', Icons.delete_outline, 'Удалить'),
    ];
    if (items.isEmpty) return;
    String? choice;
    if (at != null) {
      choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
        items: [
          for (final it in items)
            PopupMenuItem(
              value: it.$1,
              child: Row(children: [Icon(it.$2, size: 18, color: it.$1 == 'delete' ? W.bad : W.muted), const SizedBox(width: 10), Text(it.$3)]),
            ),
        ],
      );
    } else {
      choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              for (final it in items)
                ListTile(
                  leading: Icon(it.$2, color: it.$1 == 'delete' ? W.bad : W.muted),
                  title: Text(it.$3),
                  onTap: () => Navigator.pop(ctx, it.$1),
                ),
            ],
          ),
        ),
      );
    }
    if (choice == null || !mounted) return;
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) toast(context, 'Скопировано');
    } else if (choice == 'edit') {
      setState(() {
        _editing = m;
        _text.text = text;
      });
      _focus.requestFocus();
    } else if (choice == 'delete') {
      await _delete(m);
    } else if (choice.startsWith('save:')) {
      await openUrl(context, Api.I.fileUrl(m, choice.substring(5), download: true));
    }
  }

  // ---------- группа ----------

  Future<void> _chatMenu(String action) async {
    final chat = _chat;
    if (chat == null) return;
    final members = chat.getListValue<String>('members');
    try {
      switch (action) {
        case 'members':
          await showMembers(context, chat);
        case 'add':
          final picked = await pickPeople(context, title: 'Добавить в группу', exclude: members.toSet());
          if (picked == null || picked.isEmpty) return;
          final added = await _pb.collection('chats').update(chat.id, body: {'members+': picked});
          Store.I.replaceChat(added);
        case 'rename':
          final newName = await askText(context, 'Название группы', initial: chat.getStringValue('name'));
          if (newName == null || newName.trim().isEmpty) return;
          final renamed = await _pb.collection('chats').update(chat.id, body: {'name': newName.trim()});
          Store.I.replaceChat(renamed);
        case 'leave':
          if (!await confirm(context, 'Выйти из группы?', 'Ты перестанешь получать сообщения этой группы.')) return;
          await _pb.collection('chats').update(chat.id, body: {'members-': Api.I.myId});
          Store.I.removeChat(chat.id);
          if (mounted && !widget.embedded) Navigator.of(context).pop();
        case 'delete':
          if (!await confirm(context, 'Удалить чат?', 'Чат и вся переписка удалятся у всех участников.')) return;
          await _pb.collection('chats').delete(chat.id);
          Store.I.removeChat(chat.id);
          if (mounted && !widget.embedded) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(automaticallyImplyLeading: !widget.embedded),
        body: Center(child: Store.I.loaded ? const Text('Чат не найден', style: W.small) : const CircularProgressIndicator()),
      );
    }
    final api = Api.I;
    final isGroup = chat.getBoolValue('is_group');
    final title = api.chatTitle(chat);
    final members = chat.getListValue<String>('members');
    final inCall = Store.I.callParticipants(chat.id);
    final iAmInCall = CallController.I.chatId == chat.id && CallController.I.active;
    final isOwner = chat.getStringValue('owner') == api.myId;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: InkWell(
          onTap: isGroup ? () => showMembers(context, chat) : null,
          child: Row(
            children: [
              isGroup
                  ? LetterAvatar(name: title, seed: chat.id, size: 36, icon: Icons.group)
                  : UserAvatar(api.otherMember(chat) ?? api.myId, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (isGroup)
                      Text('${members.length} участников', style: const TextStyle(fontSize: 12, color: W.muted, fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Аудиозвонок',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => startCall(context, chat.id, title),
          ),
          IconButton(
            tooltip: 'Видеозвонок',
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => startCall(context, chat.id, title, withCamera: true),
          ),
          PopupMenuButton<String>(
            onSelected: _chatMenu,
            itemBuilder: (_) => [
              if (isGroup) const PopupMenuItem(value: 'members', child: Text('Участники')),
              if (isGroup) const PopupMenuItem(value: 'add', child: Text('Добавить участников')),
              if (isGroup) const PopupMenuItem(value: 'rename', child: Text('Переименовать')),
              if (isGroup) const PopupMenuItem(value: 'leave', child: Text('Выйти из группы')),
              if (isOwner) const PopupMenuItem(value: 'delete', child: Text('Удалить чат', style: TextStyle(color: W.bad))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!widget.embedded) const InCallBar(),
          if (inCall.isNotEmpty && !iAmInCall) _callBanner(chat, title, inCall),
          Expanded(child: _messagesView(isGroup)),
          _composer(),
        ],
      ),
    );
  }

  Widget _callBanner(RecordModel chat, String title, List<String> people) {
    final names = people.map(Api.I.nameOf).join(', ');
    return Material(
      color: W.good.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.call, color: W.good, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Идёт звонок: $names', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: W.good)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: W.good, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
              onPressed: () => startCall(context, chat.id, title),
              child: const Text('Войти'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messagesView(bool isGroup) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: W.small),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: () {
              setState(() => _loading = true);
              _load();
            }, child: const Text('Повторить')),
          ],
        ),
      );
    }
    if (_msgs.isEmpty) {
      return const Center(child: Text('Напиши первое сообщение 👋', style: W.small));
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      itemCount: _msgs.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == _msgs.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final m = _msgs[i];
        final older = i + 1 < _msgs.length ? _msgs[i + 1] : null;
        final d = parseDate(m.getStringValue('created')) ?? DateTime.now();
        final od = older == null ? null : parseDate(older.getStringValue('created'));
        final newDay = od == null || !sameDay(d, od);
        final author = m.getStringValue('author');
        final grouped = !newDay &&
            older != null &&
            older.getStringValue('author') == author &&
            d.difference(od).inMinutes < 5;
        return Column(
          children: [
            if (newDay) _DayChip(dayLabel(d)),
            MessageBubble(
              message: m,
              showAuthor: isGroup && !grouped,
              compact: grouped,
              onMenu: (at) => _messageMenu(m, at),
            ),
          ],
        );
      },
    );
  }

  Widget _composer() {
    final canSend = _text.text.trim().isNotEmpty || _pending.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: W.surface,
        border: Border(top: BorderSide(color: W.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_editing != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, left: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.edit, size: 16, color: W.ice),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Изменение сообщения', style: TextStyle(color: W.ice, fontSize: 13))),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          _editing = null;
                          _text.clear();
                        }),
                      ),
                    ],
                  ),
                ),
              if (_pending.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final f in _pending)
                        Padding(
                          padding: const EdgeInsets.only(right: 6, bottom: 6),
                          child: InputChip(
                            avatar: Icon(_iconFor(f.name), size: 18, color: W.ice),
                            label: Text('${f.name} · ${humanSize(f.size)}', style: const TextStyle(fontSize: 12.5)),
                            onDeleted: _sending ? null : () => setState(() => _pending.remove(f)),
                            backgroundColor: W.surface2,
                            side: const BorderSide(color: W.border),
                          ),
                        ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_editing == null)
                    PopupMenuButton<FileType>(
                      tooltip: 'Прикрепить',
                      icon: const Icon(Icons.attach_file, color: W.muted),
                      enabled: !_sending,
                      onSelected: (t) => _pickFiles(type: t),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: FileType.media, child: Row(children: [Icon(Icons.photo_library_outlined, size: 18), SizedBox(width: 10), Text('Фото или видео')])),
                        PopupMenuItem(value: FileType.any, child: Row(children: [Icon(Icons.insert_drive_file_outlined, size: 18), SizedBox(width: 10), Text('Файл')])),
                      ],
                    ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (_desktop &&
                            event is KeyDownEvent &&
                            (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _send();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        autofocus: _desktop,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: _desktop ? 'Сообщение (Enter — отправить, Shift+Enter — новая строка)' : 'Сообщение',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: W.border)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: W.border)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: W.ice)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _sending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
                        )
                      : IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: canSend ? W.ice : W.surface2, foregroundColor: canSend ? W.bg : W.muted),
                          icon: Icon(_editing != null ? Icons.check : Icons.send_rounded),
                          onPressed: canSend || _editing != null ? _send : null,
                        ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String name) => switch (fileKind(name)) {
        FileKind.image => Icons.image_outlined,
        FileKind.video => Icons.movie_outlined,
        FileKind.audio => Icons.audiotrack,
        FileKind.other => Icons.insert_drive_file_outlined,
      };
}

class _DayChip extends StatelessWidget {
  const _DayChip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: const TextStyle(fontSize: 12, color: W.muted, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.showAuthor,
    required this.compact,
    required this.onMenu,
  });
  final RecordModel message;
  final bool showAuthor;
  final bool compact;
  final void Function(Offset? at) onMenu;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final author = message.getStringValue('author');
    final mine = author == api.myId;
    final text = message.getStringValue('text');
    final files = message.getListValue<String>('files');
    final images = files.where((f) => fileKind(f) == FileKind.image).toList();
    final others = files.where((f) => fileKind(f) != FileKind.image).toList();
    final d = parseDate(message.getStringValue('created'));
    final edited = message.getBoolValue('edited');
    final maxW = (MediaQuery.sizeOf(context).width * 0.72).clamp(200.0, 560.0).toDouble();

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
      decoration: BoxDecoration(
        color: mine ? W.iceDeep : W.surface2,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 5),
          bottomRight: Radius.circular(mine ? 5 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showAuthor && !mine)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(api.nameOf(author), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colorFor(author))),
            ),
          if (images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, top: 2),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final f in images)
                    _ImageThumb(
                      message: message,
                      file: f,
                      size: images.length == 1 ? maxW - 20 : (maxW - 24) / 2,
                    ),
                ],
              ),
            ),
          for (final f in others) _FileTile(message: message, file: f),
          if (text.isNotEmpty) _LinkText(text),
          Align(
            alignment: Alignment.bottomRight,
            child: Text(
              '${edited ? 'изменено · ' : ''}${d == null ? '' : hhmm(d)}',
              style: TextStyle(fontSize: 11, color: mine ? W.iceLight.withValues(alpha: 0.7) : W.muted),
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.only(top: compact ? 2 : 8),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            SizedBox(width: 32, child: compact ? null : UserAvatar(author, size: 32)),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () => onMenu(null),
              onSecondaryTapDown: (det) => onMenu(det.globalPosition),
              child: bubble,
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  const _LinkText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in urlRegex.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: const TextStyle(color: W.ice, decoration: TextDecoration.underline, decorationColor: W.ice),
        recognizer: TapGestureRecognizer()..onTap = () => openUrl(context, Uri.parse(url)),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    final big = text.runes.length <= 3 && !RegExp(r'[a-zA-Zа-яА-Я0-9]').hasMatch(text);
    return Text.rich(
      TextSpan(children: spans),
      style: big ? const TextStyle(fontSize: 34) : W.body,
    );
  }
}

class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.message, required this.file, required this.size});
  final RecordModel message;
  final String file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final gif = file.toLowerCase().endsWith('.gif');
    final thumb = api.fileUrl(message, file, thumb: gif ? null : '480x0').toString();
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageViewer(message: message, file: file))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: size, maxHeight: size * 1.2, minWidth: 80, minHeight: 60),
          child: Image.network(
            thumb,
            fit: BoxFit.cover,
            width: size,
            loadingBuilder: (_, child, p) => p == null
                ? child
                : Container(width: size, height: size * 0.7, color: W.surface3, child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
            errorBuilder: (_, __, ___) => Container(
              width: size,
              height: 90,
              color: W.surface3,
              child: const Icon(Icons.broken_image_outlined, color: W.muted),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.message, required this.file});
  final RecordModel message;
  final String file;

  @override
  Widget build(BuildContext context) {
    final kind = fileKind(file);
    final name = prettyFileName(file);
    final icon = switch (kind) {
      FileKind.video => Icons.play_circle_fill,
      FileKind.audio => Icons.audiotrack,
      _ => Icons.insert_drive_file,
    };
    final hint = switch (kind) {
      FileKind.video => 'Видео — нажми, чтобы открыть',
      FileKind.audio => 'Аудио — нажми, чтобы открыть',
      _ => 'Файл — нажми, чтобы скачать',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openUrl(
          context,
          Api.I.fileUrl(message, file, download: kind == FileKind.other),
        ),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: W.bg.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(12)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: W.ice),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, color: W.text)),
                    Text(hint, style: W.small),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.message, required this.file});
  final RecordModel message;
  final String file;

  @override
  Widget build(BuildContext context) {
    final url = Api.I.fileUrl(message, file).toString();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(prettyFileName(file), style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: 'Скачать',
            icon: const Icon(Icons.download),
            onPressed: () => openUrl(context, Api.I.fileUrl(message, file, download: true)),
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.network(
            url,
            loadingBuilder: (_, child, p) => p == null ? child : const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }
}

Future<void> openUrl(BuildContext context, Uri uri) async {
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) toast(context, 'Не удалось открыть');
  } catch (_) {
    if (context.mounted) toast(context, 'Не удалось открыть');
  }
}

Future<bool> confirm(BuildContext context, String title, String text) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Да')),
      ],
    ),
  );
  return ok == true;
}

Future<String?> askText(BuildContext context, String title, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Сохранить')),
      ],
    ),
  );
}
