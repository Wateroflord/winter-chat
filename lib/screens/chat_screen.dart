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
import '../instant.dart';
import '../settings.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';
import '../widgets/chat_background.dart';
import '../widgets/video_message.dart';
import '../widgets/voice.dart';
import 'home_screen.dart';
import 'people_sheet.dart';
import 'profile_sheet.dart';
import 'search_screen.dart';

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
  RecordModel? _replyTo;
  final _voice = VoiceRecorder();
  Timer? _voiceTick;
  bool _recording = false;
  final Map<String, GlobalKey> _keys = {};
  String? _highlight;
  List<RecordModel> _pinned = [];
  String _pinsSig = '';

  PocketBase get _pb => Api.I.pb;
  RecordModel? get _chat => Store.I.chat(widget.chatId);
  bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    Store.I.addListener(_changed);
    CallController.I.addListener(_changed);
    Settings.I.addListener(_changed);
    Api.I.addListener(_serverMaybeChanged);
    _server = Api.I.serverUrl;
    _scroll.addListener(_onScroll);
    _load();
    _subscribe();
    _poll = Timer.periodic(const Duration(seconds: 25), (_) => _fetchNewest());
  }

  @override
  void dispose() {
    Store.I.removeListener(_changed);
    CallController.I.removeListener(_changed);
    Settings.I.removeListener(_changed);
    Api.I.removeListener(_serverMaybeChanged);
    _poll?.cancel();
    _voiceTick?.cancel();
    _voice.dispose();
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
    _refreshPins();
  }

  /// Закреплённые изменились — подгрузить их тексты.
  Future<void> _refreshPins() async {
    final ids = _chat?.getListValue<String>('pins') ?? const [];
    final sig = ids.join(',');
    if (sig == _pinsSig) return;
    _pinsSig = sig;
    final list = await loadMessagesByIds(ids);
    if (mounted && sig == _pinsSig) setState(() => _pinned = list);
  }

  String _server = '';

  /// Переключились на запасной адрес сервера (Winter VPN) — переподписаться на сообщения.
  void _serverMaybeChanged() {
    if (!mounted || Api.I.serverUrl == _server || !Api.I.loggedIn) return;
    _server = Api.I.serverUrl;
    _unsub = null;
    _subscribe();
    _fetchNewest();
  }

  void _markRead() {
    final c = _chat;
    if (c != null && Api.I.markRead(c)) {
      Future.microtask(Store.I.ping);
    }
    // Друзья увидят ✓✓, только если я действительно смотрю на чат.
    if (c != null && !Instant.background) Api.I.readOnServer(c);
  }

  String get _filter => _pb.filter('chat = {:c}', {'c': widget.chatId});

  Future<void> _load() async {
    try {
      final res = await _pb.collection('messages').getList(page: 1, perPage: 50, filter: _filter, sort: '-created', skipTotal: true, expand: 'reply_to');
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
    _refreshPins();
  }

  Future<void> _fetchNewest() async {
    if (_loading) return;
    try {
      final res = await _pb.collection('messages').getList(page: 1, perPage: 30, filter: _filter, sort: '-created', skipTotal: true, expand: 'reply_to');
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
            expand: 'reply_to',
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
      }, filter: _filter, expand: 'reply_to');
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
          body: {'chat': widget.chatId, 'text': first ? text : '', if (first && _replyTo != null) 'reply_to': _replyTo!.id},
          files: multipart,
          expand: 'reply_to',
        );
        _upsert(rec);
        first = false;
      } while (rest.isNotEmpty);
      _text.clear();
      _pending.clear();
      _replyTo = null;
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось отправить'));
    }
    if (mounted) {
      setState(() => _sending = false);
      _focus.requestFocus();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  // ---------- голосовые ----------

  Future<void> _startVoice() async {
    final err = await _voice.start();
    if (err != null) {
      if (mounted) toast(context, err);
      return;
    }
    setState(() => _recording = true);
    _voiceTick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
      if (_voice.elapsed > const Duration(minutes: 10)) _stopVoice(send: true);
    });
  }

  Future<void> _stopVoice({required bool send}) async {
    _voiceTick?.cancel();
    _voiceTick = null;
    setState(() => _recording = false);
    if (!send) {
      await _voice.cancel();
      return;
    }
    final path = await _voice.stop();
    if (path == null) {
      if (mounted) toast(context, 'Слишком коротко — держи запись хотя бы секунду');
      return;
    }
    setState(() => _sending = true);
    try {
      final ext = path.split('.').last;
      final rec = await _pb.collection('messages').create(
        body: {'chat': widget.chatId, 'text': '', if (_replyTo != null) 'reply_to': _replyTo!.id},
        files: [await http.MultipartFile.fromPath('files', path, filename: 'voice_${DateTime.now().millisecondsSinceEpoch}.$ext')],
        expand: 'reply_to',
      );
      _upsert(rec);
      _replyTo = null;
      try {
        File(path).deleteSync();
      } catch (_) {}
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Голосовое не отправилось'));
    }
    if (mounted) setState(() => _sending = false);
  }

  // ---------- реакции, ответы, закрепы ----------

  Future<void> _react(RecordModel m, String emoji) async {
    try {
      await Api.I.react(m.id, emoji);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  void _reply(RecordModel m) {
    setState(() {
      _replyTo = m;
      _editing = null;
    });
    _focus.requestFocus();
  }

  Future<void> _togglePin(RecordModel m) async {
    final chat = _chat;
    if (chat == null) return;
    final pinned = chat.getListValue<String>('pins').contains(m.id);
    try {
      final r = await _pb.collection('chats').update(chat.id, body: {pinned ? 'pins-' : 'pins+': m.id});
      if (!r.data.containsKey('pins')) {
        if (mounted) toast(context, 'Сервер Winter Chat старый — обнови его, чтобы закреплять сообщения');
        return;
      }
      Store.I.replaceChat(r);
      if (mounted) toast(context, pinned ? 'Откреплено' : 'Закреплено 📌');
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e));
    }
  }

  /// Показать сообщение: прокрутить к нему, если оно загружено, иначе — открыть с соседними.
  void _jumpTo(RecordModel m) {
    final key = _keys[m.id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 300));
      setState(() => _highlight = m.id);
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted && _highlight == m.id) setState(() => _highlight = null);
      });
    } else {
      showMessageContext(context, widget.chatId, m);
    }
  }

  RecordModel? _replyOf(RecordModel m) {
    final id = m.getStringValue('reply_to');
    if (id.isEmpty) return null;
    for (final x in _msgs) {
      if (x.id == id) return x;
    }
    final ex = m.expand['reply_to'];
    return ex == null || ex.isEmpty ? null : ex.first;
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
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Удалить', style: TextStyle(color: W.bad))),
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
    final pinned = _chat?.getListValue<String>('pins').contains(m.id) ?? false;
    final items = <(String, IconData, String)>[
      ('reply', Icons.reply, 'Ответить'),
      if (text.isNotEmpty) ('copy', Icons.copy, 'Копировать текст'),
      (pinned ? 'unpin' : 'pin', Icons.push_pin_outlined, pinned ? 'Открепить' : 'Закрепить'),
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
          PopupMenuItem<String>(
            enabled: false,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _ReactionRow(compact: true, onPick: (e) => Navigator.of(context).pop('react:$e')),
          ),
          const PopupMenuDivider(),
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: _ReactionRow(onPick: (e) => Navigator.pop(ctx, 'react:$e')),
              ),
              Divider(color: W.border),
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
    if (choice.startsWith('react:')) {
      await _react(m, choice.substring(6));
    } else if (choice == 'reply') {
      _reply(m);
    } else if (choice == 'pin' || choice == 'unpin') {
      await _togglePin(m);
    } else if (choice == 'copy') {
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
        case 'search':
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(chatId: chat.id)));
        case 'pins':
          await showPins(context, chat);
        case 'style':
          await showChatStyle(context, chat);
        case 'group':
          await editGroup(context, chat);
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
        body: Center(child: Store.I.loaded ? Text('Чат не найден', style: W.small) : const CircularProgressIndicator()),
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
          onTap: isGroup ? () => showMembers(context, chat) : () => showProfile(context, api.otherMember(chat) ?? api.myId),
          child: Row(
            children: [
              ChatAvatar(chat, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (isGroup && _typingText(chat).isNotEmpty)
                      Text(_typingText(chat), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: W.ice, fontWeight: FontWeight.w400))
                    else if (isGroup)
                      Text(
                        [
                          '${members.length} участников',
                          if (chat.getStringValue('description').trim().isNotEmpty) chat.getStringValue('description').trim(),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: W.muted, fontWeight: FontWeight.w400),
                      )
                    else if (_subtitle(chat).isNotEmpty)
                      Text(
                        _subtitle(chat),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: _typingText(chat).isNotEmpty || api.isOnline(api.otherMember(chat) ?? '') ? W.ice : W.muted, fontWeight: FontWeight.w400),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (isGroup)
            IconButton(
              tooltip: 'Голосовая комната: зайти без звонка остальным',
              icon: const Icon(Icons.headset_mic_outlined),
              onPressed: () => startCall(context, chat.id, title, quiet: true),
            ),
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
              const PopupMenuItem(value: 'search', child: Text('Поиск по чату')),
              if (chat.getListValue<String>('pins').isNotEmpty) const PopupMenuItem(value: 'pins', child: Text('Закреплённые сообщения')),
              const PopupMenuItem(value: 'style', child: Text('Оформление и настройки чата')),
              if (isGroup) const PopupMenuItem(value: 'group', child: Text('Фото и описание группы')),
              if (isGroup) const PopupMenuItem(value: 'members', child: Text('Участники')),
              if (isGroup) const PopupMenuItem(value: 'add', child: Text('Добавить участников')),
              if (isGroup) const PopupMenuItem(value: 'rename', child: Text('Переименовать')),
              if (isGroup) const PopupMenuItem(value: 'leave', child: Text('Выйти из группы')),
              if (isOwner) PopupMenuItem(value: 'delete', child: Text('Удалить чат', style: TextStyle(color: W.bad))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!widget.embedded) const InCallBar(),
          if (inCall.isNotEmpty && !iAmInCall) _callBanner(chat, title, inCall),
          if (_pinned.isNotEmpty) _pinsBar(chat),
          Expanded(child: ChatBackground(wallpaper: Settings.I.wallpaperFor(chat.id), child: _messagesView(isGroup))),
          _composer(),
        ],
      ),
    );
  }

  Widget _pinsBar(RecordModel chat) {
    final last = _pinned.first;
    return Material(
      color: W.surface,
      child: InkWell(
        onTap: () => _pinned.length == 1 ? _jumpTo(last) : showPins(context, chat),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: W.border))),
          child: Row(
            children: [
              Icon(Icons.push_pin, size: 18, color: W.ice),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_pinned.length == 1 ? 'Закреплено' : 'Закреплено · ${_pinned.length}', style: TextStyle(fontSize: 12, color: W.ice, fontWeight: FontWeight.w700)),
                    Text(messageSnippet(last), maxLines: 1, overflow: TextOverflow.ellipsis, style: W.small.copyWith(color: W.text)),
                  ],
                ),
              ),
              if (_pinned.length > 1) Icon(Icons.chevron_right, color: W.muted),
            ],
          ),
        ),
      ),
    );
  }

  /// «печатает…» / «Вова печатает…» / «Вова и Стас печатают…».
  String _typingText(RecordModel chat) {
    final who = Store.I.typingIn(chat.id);
    if (who.isEmpty) return '';
    if (!chat.getBoolValue('is_group')) return 'печатает…';
    final names = who.map(Api.I.nameOf).toList();
    return names.length == 1 ? '${names.first} печатает…' : '${names.take(2).join(' и ')} печатают…';
  }

  /// Под именем в личном чате: печатает / в сети / был(а) … и статус.
  String _subtitle(RecordModel chat) {
    final t = _typingText(chat);
    if (t.isNotEmpty) return t;
    final other = Api.I.otherMember(chat);
    if (other == null) return '';
    return [Api.I.lastSeenText(other), Api.I.statusText(other)].where((x) => x.isNotEmpty).join(' · ');
  }

  Widget _callBanner(RecordModel chat, String title, List<String> people) {
    final names = people.map(Api.I.nameOf).join(', ');
    final quiet = Store.I.calls[chat.id]?.getBoolValue('quiet') ?? false;
    return Material(
      color: W.good.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Icon(quiet ? Icons.headset_mic : Icons.call, color: W.good, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(quiet ? 'В голосовой комнате: $names' : 'Идёт звонок: $names', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: W.good)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: W.good, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
              onPressed: () => startCall(context, chat.id, title, quiet: quiet),
              child: Text(quiet ? 'Зайти' : 'Войти'),
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
      return Center(child: Text('Напиши первое сообщение 👋', style: W.small));
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
              key: _keys.putIfAbsent(m.id, () => GlobalKey()),
              message: m,
              showAuthor: isGroup && !grouped,
              compact: grouped,
              onMenu: (at) => _messageMenu(m, at),
              chatId: widget.chatId,
              isGroup: isGroup,
              reply: _replyOf(m),
              onReplyTap: _jumpTo,
              onReact: (e) => _react(m, e),
              onSwipeReply: () => _reply(m),
              read: _chat == null ? false : Api.I.readByOthers(_chat!, m.getStringValue('created')),
              highlight: _highlight == m.id,
            ),
          ],
        );
      },
    );
  }

  Widget _composer() {
    final canSend = _text.text.trim().isNotEmpty || _pending.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
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
                      Icon(Icons.edit, size: 16, color: W.ice),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Изменение сообщения', style: TextStyle(color: W.ice, fontSize: 13))),
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
              if (_replyTo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, left: 6),
                  child: Row(
                    children: [
                      Icon(Icons.reply, size: 18, color: W.ice),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Ответ ${Api.I.nameOf(_replyTo!.getStringValue('author'))}', style: TextStyle(color: W.ice, fontSize: 12.5, fontWeight: FontWeight.w700)),
                            Text(messageSnippet(_replyTo!), maxLines: 1, overflow: TextOverflow.ellipsis, style: W.small),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _replyTo = null),
                      ),
                    ],
                  ),
                ),
              if (_recording)
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Отменить',
                      onPressed: () => _stopVoice(send: false),
                      icon: Icon(Icons.delete_outline, color: W.bad),
                    ),
                    const SizedBox(width: 6),
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: W.bad, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(mmss(_voice.elapsed), style: W.body.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Идёт запись голосового…', style: W.small)),
                    IconButton.filled(
                      tooltip: 'Отправить',
                      style: IconButton.styleFrom(backgroundColor: W.ice, foregroundColor: W.onAccent),
                      onPressed: () => _stopVoice(send: true),
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
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
                            side: BorderSide(color: W.border),
                          ),
                        ),
                    ],
                  ),
                ),
              if (!_recording)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_editing == null)
                    PopupMenuButton<FileType>(
                      tooltip: 'Прикрепить',
                      icon: Icon(Icons.attach_file, color: W.muted),
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
                            (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
                          final kb = HardwareKeyboard.instance;
                          final send = Settings.I.enterSends ? !kb.isShiftPressed : kb.isControlPressed;
                          if (send) {
                            _send();
                            return KeyEventResult.handled;
                          }
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
                        onChanged: (v) {
                          setState(() {});
                          if (v.trim().isNotEmpty) Api.I.typing(widget.chatId);
                        },
                        decoration: InputDecoration(
                          hintText: _desktop
                              ? (Settings.I.enterSends ? 'Сообщение (Enter — отправить, Shift+Enter — новая строка)' : 'Сообщение (Ctrl+Enter — отправить)')
                              : 'Сообщение',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: W.border)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: W.border)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: W.ice)),
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
                      : !canSend && _editing == null
                          ? IconButton.filled(
                              tooltip: 'Голосовое сообщение',
                              style: IconButton.styleFrom(backgroundColor: W.surface2, foregroundColor: W.text),
                              icon: const Icon(Icons.mic_none),
                              onPressed: _startVoice,
                            )
                          : IconButton.filled(
                              style: IconButton.styleFrom(backgroundColor: canSend ? W.ice : W.surface2, foregroundColor: canSend ? W.onAccent : W.muted),
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
        child: Text(text, style: TextStyle(fontSize: 12, color: W.muted, fontWeight: FontWeight.w600)),
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
    this.chatId,
    this.isGroup = false,
    this.reply,
    this.onReplyTap,
    this.onReact,
    this.onSwipeReply,
    this.read = false,
    this.highlight = false,
  });
  final RecordModel message;
  final bool showAuthor;
  final bool compact;
  final void Function(Offset? at) onMenu;
  final String? chatId;
  final bool isGroup;

  /// Сообщение, на которое это — ответ.
  final RecordModel? reply;
  final void Function(RecordModel m)? onReplyTap;
  final void Function(String emoji)? onReact;
  final VoidCallback? onSwipeReply;

  /// Моё сообщение уже прочитал кто-то из друзей (✓✓).
  final bool read;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final author = message.getStringValue('author');
    final mine = author == api.myId;
    final text = message.getStringValue('text');
    final files = message.getListValue<String>('files');
    final images = files.where((f) => fileKind(f) == FileKind.image).toList();
    final videos = files.where((f) => fileKind(f) == FileKind.video).toList();
    final audios = files.where((f) => fileKind(f) == FileKind.audio).toList();
    final others = files.where((f) => fileKind(f) == FileKind.other).toList();
    final settings = Settings.I;
    final d = parseDate(message.getStringValue('created'));
    final reactions = _reactions(message);
    final themeCode = Settings.parseTheme(text) == null ? null : text;
    final edited = message.getBoolValue('edited');
    final style = settings.bubbleStyle;
    final list = style == 3;
    final maxW = list
        ? (MediaQuery.sizeOf(context).width - 70).clamp(200.0, 760.0).toDouble()
        : (MediaQuery.sizeOf(context).width * 0.72).clamp(200.0, 560.0).toDouble();
    final time = '${edited ? 'изменено · ' : ''}${d == null ? '' : hhmm(d)}';

    // Цвета пузыря и текста.
    final bg = list ? Colors.transparent : (mine ? settings.myBubbleFor(chatId) : settings.otherBubble);
    final fg = list ? W.text : onColor(bg);
    final sub = list ? W.muted : fg.withValues(alpha: 0.62);
    final gradient = !list && mine && settings.myBubbleGradient
        ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(bg, Colors.white, 0.12)!, Color.lerp(bg, Colors.black, 0.18)!])
        : null;

    final r = switch (style) {
      2 => 4.0,
      _ => settings.bubbleRadius,
    };
    final tail = style == 0 ? (r * 0.3).clamp(3.0, 6.0) : r;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(r),
      topRight: Radius.circular(r),
      bottomLeft: Radius.circular(mine ? r : tail),
      bottomRight: Radius.circular(mine ? tail : r),
    );

    final content = DefaultTextStyle.merge(
      style: TextStyle(color: fg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (list && !compact)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: () => showProfile(context, author),
                      child: Text(
                        api.nameOf(author),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: nameColorFor(author)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(time, style: TextStyle(fontSize: 11.5, color: W.muted)),
                  if (mine) ...[
                    const SizedBox(width: 4),
                    Icon(read ? Icons.done_all : Icons.done, size: 14, color: read ? W.ice : W.muted),
                  ],
                ],
              ),
            ),
          if (!list && showAuthor && !mine)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: GestureDetector(
                onTap: () => showProfile(context, author),
                child: Text(api.nameOf(author), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: nameColorFor(author))),
              ),
            ),
          if (reply != null)
            GestureDetector(
              onTap: onReplyTap == null ? null : () => onReplyTap!(reply!),
              child: Container(
                margin: const EdgeInsets.only(bottom: 5, top: 1),
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                decoration: BoxDecoration(
                  color: (list ? W.surface2 : fg.withValues(alpha: 0.08)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border(left: BorderSide(color: nameColorFor(reply!.getStringValue('author')), width: 3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(api.nameOf(reply!.getStringValue('author')),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: nameColorFor(reply!.getStringValue('author')))),
                    Text(messageSnippet(reply!), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: fg.withValues(alpha: 0.8))),
                  ],
                ),
              ),
            )
          else if (message.getStringValue('reply_to').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('↩ ответ на удалённое сообщение', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: fg.withValues(alpha: 0.6))),
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
                      size: (images.length == 1 ? maxW - 20 : (maxW - 24) / 2).clamp(80.0, list ? 360.0 : 560.0).toDouble(),
                    ),
                ],
              ),
            ),
          for (final f in videos) VideoMessage(key: ValueKey('${message.id}/$f'), message: message, file: f, width: (maxW - 20).clamp(160.0, 480.0).toDouble()),
          for (final f in audios) VoiceMessage(key: ValueKey('${message.id}/$f'), message: message, file: f, width: maxW - 20, color: fg),
          for (final f in others) _FileTile(message: message, file: f),
          if (themeCode != null)
            _ThemeCard(code: themeCode, color: fg)
          else if (text.isNotEmpty)
            _LinkText(text, color: fg),
          if (reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final r in reactions.entries)
                    _ReactionChip(
                      emoji: r.key,
                      users: r.value,
                      mine: r.value.contains(api.myId),
                      onTap: onReact == null ? null : () => onReact!(r.key),
                      fg: fg,
                    ),
                ],
              ),
            ),
          if (!list)
            Align(
              alignment: Alignment.bottomRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: TextStyle(fontSize: 11, color: sub)),
                  if (mine) ...[
                    const SizedBox(width: 3),
                    Icon(read ? Icons.done_all : Icons.done, size: 14, color: read ? (onColor(bg) == Colors.white ? W.iceLight : W.ice) : sub),
                  ],
                ],
              ),
            ),
        ],
      ),
    );

    final bubble = list
        ? Container(constraints: BoxConstraints(maxWidth: maxW), padding: const EdgeInsets.symmetric(vertical: 1), child: content)
        : Container(
            constraints: BoxConstraints(maxWidth: maxW),
            padding: settings.compact ? const EdgeInsets.fromLTRB(9, 5, 9, 4) : const EdgeInsets.fromLTRB(10, 7, 10, 6),
            decoration: BoxDecoration(
              color: gradient == null ? bg : null,
              gradient: gradient,
              borderRadius: radius,
              border: W.light && !mine && settings.otherBubbleColor == null ? Border.all(color: W.border) : null,
            ),
            child: content,
          );

    // Аватар: в группах (если включено) и всегда в виде «список».
    final avatarSlot = list || (isGroup && settings.showAvatars);
    final avatarSize = list ? 38.0 : 32.0;
    final avatar = SizedBox(
      width: avatarSize,
      child: compact
          ? null
          : GestureDetector(onTap: () => showProfile(context, author), child: UserAvatar(author, size: avatarSize)),
    );

    return Padding(
      padding: EdgeInsets.only(top: compact ? (list ? 0 : 2) : (settings.compact ? 5 : (list ? 10 : 8))),
      child: Row(
        mainAxisAlignment: mine && !list ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: list ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          if ((!mine || list) && avatarSlot) ...[
            avatar,
            SizedBox(width: list ? 10 : 6),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () => onMenu(null),
              onSecondaryTapDown: (det) => onMenu(det.globalPosition),
              onDoubleTap: onReact == null ? null : () => onReact!('❤️'),
              // Смахнуть вправо — ответить.
              onHorizontalDragEnd: onSwipeReply == null
                  ? null
                  : (det) {
                      if ((det.primaryVelocity ?? 0) > 350) onSwipeReply!();
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(r + 4),
                  boxShadow: highlight ? [BoxShadow(color: W.ice.withValues(alpha: 0.55), blurRadius: 14, spreadRadius: 1)] : null,
                ),
                child: bubble,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Реакции из сообщения: эмодзи → кто поставил.
  static Map<String, List<String>> _reactions(RecordModel m) {
    final r = m.data['reactions'];
    if (r is! Map) return const {};
    return {
      for (final e in r.entries)
        if (e.value is List && (e.value as List).isNotEmpty) '${e.key}': [for (final u in e.value as List) '$u'],
    };
  }
}

/// Быстрые реакции в меню сообщения.
class _ReactionRow extends StatelessWidget {
  const _ReactionRow({required this.onPick, this.compact = false});
  final void Function(String emoji) onPick;
  // В узком меню по правой кнопке — помельче, чтобы все влезли в одну строку.
  final bool compact;
  static const quick = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👏', '🎉'];

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: compact ? 0 : 2,
        children: [
          for (final e in quick)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => onPick(e),
              child: Padding(
                padding: EdgeInsets.all(compact ? 4 : 6),
                child: Text(e, style: TextStyle(fontSize: compact ? 20 : 22)),
              ),
            ),
        ],
      );
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.emoji, required this.users, required this.mine, required this.onTap, required this.fg});
  final String emoji;
  final List<String> users;
  final bool mine;
  final VoidCallback? onTap;
  final Color fg;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: users.map(Api.I.nameOf).join(', '),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: mine ? W.ice.withValues(alpha: 0.25) : fg.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: mine ? W.ice : Colors.transparent),
            ),
            child: Text('$emoji ${users.length}', style: TextStyle(fontSize: 13, color: fg)),
          ),
        ),
      );
}

/// Код темы оформления в сообщении: кнопка «Применить».
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.code, required this.color});
  final String code;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final j = Settings.parseTheme(code)!;
    final p = paletteById(j['p'] as String);
    final accent = Color(j['a'] as int);
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: accent.withValues(alpha: 0.6))),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 28, height: 28, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('🎨 Тема оформления', style: TextStyle(color: p.text, fontWeight: FontWeight.w700)),
              Text('${p.name} · ${Settings.bubbleStyles[((j['bs'] as int?) ?? 0).clamp(0, 3)].toLowerCase()}', style: TextStyle(color: p.muted, fontSize: 12)),
            ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: onColor(accent), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
            onPressed: () async {
              final ok = await Settings.I.importTheme(code);
              if (context.mounted) toast(context, ok ? 'Тема применена ✨' : 'Код темы не подошёл');
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  const _LinkText(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in urlRegex.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(color: color == null || color == W.text ? W.ice : color, decoration: TextDecoration.underline, decorationColor: color ?? W.ice),
        recognizer: TapGestureRecognizer()..onTap = () => openUrl(context, Uri.parse(url)),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    final big = Settings.I.bigEmoji && text.runes.length <= 3 && !RegExp(r'[a-zA-Zа-яА-Я0-9]').hasMatch(text);
    return Text.rich(
      TextSpan(children: spans),
      style: big ? const TextStyle(fontSize: 34) : W.body.copyWith(color: color),
    );
  }
}

class _ImageThumb extends StatefulWidget {
  const _ImageThumb({required this.message, required this.file, required this.size});
  final RecordModel message;
  final String file;
  final double size;

  @override
  State<_ImageThumb> createState() => _ImageThumbState();
}

class _ImageThumbState extends State<_ImageThumb> {
  /// Фото по нажатию (если в настройках выключена автозагрузка).
  bool _show = Settings.I.autoloadImages;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final size = widget.size;
    final file = widget.file;
    final message = widget.message;
    if (!_show && !Settings.I.autoloadImages) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _show = true),
        child: Container(
          width: size,
          height: size * 0.6,
          decoration: BoxDecoration(color: W.surface3, borderRadius: BorderRadius.circular(12)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.image_outlined, color: W.muted, size: 32),
              SizedBox(height: 4),
              Text('Нажми, чтобы показать фото', style: W.small),
            ],
          ),
        ),
      );
    }
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
              child: Icon(Icons.broken_image_outlined, color: W.muted),
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
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: W.text)),
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
