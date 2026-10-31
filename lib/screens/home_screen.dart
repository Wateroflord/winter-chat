import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../call_controller.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
import 'people_sheet.dart';
import 'profile_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _selected;
  StreamSubscription<RecordModel>? _incomingSub;
  final Set<String> _rungFor = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Store.I.addListener(_changed);
    CallController.I.addListener(_changed);
    Store.I.start();
    _incomingSub = Store.I.incomingCalls.listen(_onIncoming);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Store.I.removeListener(_changed);
    CallController.I.removeListener(_changed);
    _incomingSub?.cancel();
    Store.I.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Store.I.refresh(silent: true);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= 760;

  void _openChat(RecordModel chat) {
    if (_wide) {
      setState(() => _selected = chat.id);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id)));
    }
  }

  Future<void> _onIncoming(RecordModel call) async {
    final chatId = call.getStringValue('chat');
    if (_rungFor.contains(call.id) || CallController.I.chatId == chatId) return;
    _rungFor.add(call.id);
    final chat = Store.I.chat(chatId);
    if (chat == null || !mounted) return;
    final caller = call.getListValue<String>('participants').firstOrNull;
    final title = Api.I.chatTitle(chat);
    final accept = await showIncomingCall(context, chatId: chatId, title: title, callerId: caller);
    if (accept == null || !mounted) return;
    await startCall(context, chatId, title, withCamera: accept);
  }

  @override
  Widget build(BuildContext context) {
    final list = _ChatList(onOpen: _openChat, selected: _wide ? _selected : null);
    if (!_wide) return list;
    final sel = _selected == null ? null : Store.I.chat(_selected!);
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 340, child: list),
          const VerticalDivider(width: 1, color: W.border),
          Expanded(
            child: sel == null
                ? const _EmptyPane()
                : ChatScreen(key: ValueKey(sel.id), chatId: sel.id, embedded: true),
          ),
        ],
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: W.bg,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 64, color: W.border),
            SizedBox(height: 12),
            Text('Выбери чат слева', style: W.small),
          ],
        ),
      ),
    );
  }
}

class _ChatList extends StatelessWidget {
  const _ChatList({required this.onOpen, this.selected});
  final void Function(RecordModel) onOpen;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final store = Store.I;
    final api = Api.I;
    return Scaffold(
      backgroundColor: W.surface,
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const Icon(Icons.ac_unit, color: W.ice, size: 20),
            const SizedBox(width: 8),
            const Text('Winter Chat'),
            if (!store.online) ...[
              const SizedBox(width: 10),
              const Tooltip(
                message: 'Нет связи с сервером',
                child: Icon(Icons.cloud_off, size: 18, color: W.warn),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Новый чат',
            icon: const Icon(Icons.edit_square),
            onPressed: () async {
              final chat = await showNewChat(context);
              if (chat != null) onOpen(chat);
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10, left: 2),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => showProfile(context),
              child: UserAvatar(api.myId, size: 34),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const InCallBar(),
          Expanded(child: _body(context, store)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, Store store) {
    if (!store.loaded) return const Center(child: CircularProgressIndicator());
    if (store.error != null && store.chats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: W.warn),
              const SizedBox(height: 10),
              Text(store.error!, textAlign: TextAlign.center, style: W.body),
              const SizedBox(height: 14),
              OutlinedButton(onPressed: () => store.refresh(), child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    if (store.chats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_bubble_outline, size: 52, color: W.border),
              const SizedBox(height: 12),
              const Text('Чатов пока нет', style: W.h2),
              const SizedBox(height: 6),
              const Text('Начни переписку с другом или создай группу.', style: W.small, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Новый чат'),
                onPressed: () async {
                  final chat = await showNewChat(context);
                  if (chat != null) onOpen(chat);
                },
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => store.refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: store.chats.length,
        itemBuilder: (_, i) {
          final c = store.chats[i];
          return _ChatTile(chat: c, selected: c.id == selected, onTap: () => onOpen(c));
        },
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat, required this.selected, required this.onTap});
  final RecordModel chat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final isGroup = chat.getBoolValue('is_group');
    final title = api.chatTitle(chat);
    final unread = api.isUnread(chat);
    final inCall = Store.I.callParticipants(chat.id).isNotEmpty;
    var sub = chat.getStringValue('last_text');
    final lastAuthor = chat.getStringValue('last_author');
    if (sub.isNotEmpty && lastAuthor.isNotEmpty) {
      if (lastAuthor == api.myId) {
        sub = 'Ты: $sub';
      } else if (isGroup) {
        sub = '${api.nameOf(lastAuthor)}: $sub';
      }
    }
    if (sub.isEmpty) sub = isGroup ? '${chat.getListValue<String>('members').length} участников' : 'Нет сообщений';
    final at = parseDate(chat.getStringValue('last_at'));

    final avatar = isGroup
        ? LetterAvatar(name: title, seed: chat.id, size: 46, icon: Icons.group)
        : UserAvatar(api.otherMember(chat) ?? api.myId, size: 46);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? W.surface3 : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    avatar,
                    if (inCall)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(color: W.good, shape: BoxShape.circle, border: Border.all(color: W.surface, width: 2)),
                          child: const Icon(Icons.call, size: 11, color: W.bg),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 15.5, fontWeight: unread ? FontWeight.w800 : FontWeight.w600, color: W.text),
                            ),
                          ),
                          if (at != null)
                            Text(shortTime(at), style: TextStyle(fontSize: 12, color: unread ? W.ice : W.muted)),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              inCall ? 'Идёт звонок' : sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13.5, color: inCall ? W.good : (unread ? W.text : W.muted)),
                            ),
                          ),
                          if (unread)
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(left: 6),
                              decoration: const BoxDecoration(color: W.ice, shape: BoxShape.circle),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Зелёная полоска «ты в звонке» — нажми, чтобы вернуться.
class InCallBar extends StatelessWidget {
  const InCallBar({super.key});

  @override
  Widget build(BuildContext context) {
    final call = CallController.I;
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        if (!call.active) return const SizedBox.shrink();
        return Material(
          color: W.good.withValues(alpha: 0.16),
          child: InkWell(
            onTap: () => openCallScreen(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.call, color: W.good, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      call.connecting ? 'Подключение к звонку…' : 'Звонок: ${call.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: W.good, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Text('вернуться', style: TextStyle(color: W.good, fontSize: 12.5)),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => call.leave(),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.call_end, color: W.bad, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Окно входящего звонка. Возвращает null — отклонить, false — без видео, true — с видео.
Future<bool?> showIncomingCall(
  BuildContext context, {
  required String chatId,
  required String title,
  String? callerId,
}) {
  final ring = Timer.periodic(const Duration(seconds: 2), (_) => SystemSound.play(SystemSoundType.alert));
  SystemSound.play(SystemSoundType.alert);
  final callerName = callerId == null ? title : Api.I.nameOf(callerId);
  var closed = false;
  BuildContext? dialogCtx;
  Timer? auto;

  void close([bool? value]) {
    if (closed) return;
    closed = true;
    auto?.cancel();
    final c = dialogCtx;
    if (c != null && c.mounted) Navigator.of(c).pop(value);
  }

  void onStore() {
    if (Store.I.callParticipants(chatId).isEmpty) close();
  }

  Store.I.addListener(onStore);
  auto = Timer(const Duration(seconds: 40), close);

  final future = showDialog<bool?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogCtx = ctx;
      return AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (callerId != null) UserAvatar(callerId, size: 84, ring: true),
            const SizedBox(height: 16),
            Text(callerName, style: W.h2, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              callerName == title ? 'звонит тебе' : 'звонит в «$title»',
              style: W.small,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          _roundBtn(Icons.call_end, W.bad, 'Отклонить', () => close()),
          _roundBtn(Icons.videocam, W.ice, 'С видео', () => close(true)),
          _roundBtn(Icons.call, W.good, 'Ответить', () => close(false)),
        ],
      );
    },
  );
  return future.whenComplete(() {
    closed = true;
    ring.cancel();
    auto?.cancel();
    Store.I.removeListener(onStore);
  });
}

Widget _roundBtn(IconData icon, Color color, String label, VoidCallback onTap) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(14), child: Icon(icon, color: W.bg, size: 26)),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: W.small),
    ],
  );
}

/// Начать или присоединиться к звонку в чате и открыть экран звонка.
Future<void> startCall(BuildContext context, String chatId, String title, {bool withCamera = false}) async {
  final call = CallController.I;
  if (call.chatId == chatId && call.active) {
    openCallScreen(context);
    return;
  }
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final joining = call.join(chatId, title, withCamera: withCamera);
  nav.push(MaterialPageRoute(builder: (_) => const CallScreen()));
  try {
    await joining;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(Api.errorText(e, fallback: 'Не удалось подключиться к звонку'))));
  }
}

void openCallScreen(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CallScreen()));
}
