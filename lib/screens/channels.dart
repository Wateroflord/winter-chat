import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import 'chat_screen.dart';
import 'home_screen.dart';

/// Каналы в группе (как сервер в Discord): текстовые #игры, #мемы и голосовые комнаты.
/// Канал — это обычный чат с полем parent = группа; состав у него всегда как у группы.

bool isChannel(RecordModel c) => c.getStringValue('parent').isNotEmpty;
bool isVoiceChannel(RecordModel c) => c.getStringValue('kind') == 'voice';

/// Каналы группы по порядку (сначала текстовые, потом голосовые).
List<RecordModel> channelsOf(String groupId) {
  final list = Store.I.chats.where((c) => c.getStringValue('parent') == groupId).toList();
  int pos(RecordModel c) => c.getIntValue('position');
  list.sort((a, b) {
    final va = isVoiceChannel(a) ? 1 : 0, vb = isVoiceChannel(b) ? 1 : 0;
    if (va != vb) return va - vb;
    final p = pos(a).compareTo(pos(b));
    return p != 0 ? p : a.getStringValue('created').compareTo(b.getStringValue('created'));
  });
  return list;
}

RecordModel? parentOf(RecordModel c) {
  final p = c.getStringValue('parent');
  return p.isEmpty ? null : Store.I.chat(p);
}

/// Группа, к которой относится чат (для канала — его группа, иначе сам чат).
RecordModel rootOf(RecordModel c) => parentOf(c) ?? c;

/// Самое свежее место в группе: сама группа или один из её текстовых каналов.
RecordModel latestIn(RecordModel group) {
  var best = group;
  for (final c in channelsOf(group.id)) {
    if (isVoiceChannel(c)) continue;
    if (c.getStringValue('last_at').compareTo(best.getStringValue('last_at')) > 0) best = c;
  }
  return best;
}

bool anyUnread(RecordModel group) => Api.I.isUnread(group) || channelsOf(group.id).any((c) => !isVoiceChannel(c) && Api.I.isUnread(c));
bool anyMention(RecordModel group) => Store.I.isMentioned(group.id) || channelsOf(group.id).any((c) => Store.I.isMentioned(c.id));

/// Кто сейчас в голосовых каналах группы.
List<String> voiceParticipants(RecordModel group) => [
      for (final c in channelsOf(group.id))
        if (isVoiceChannel(c)) ...Store.I.callParticipants(c.id),
    ];

/// Открыть другой канал на месте текущего чата.
final chatNav = ValueNotifier<String?>(null);

void openChannel(BuildContext context, String chatId, {required bool embedded}) {
  if (embedded) {
    chatNav.value = null;
    chatNav.value = chatId;
    return;
  }
  Navigator.of(context).pushReplacement(PageRouteBuilder(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => ChatScreen(chatId: chatId),
  ));
}

Future<void> createChannel(BuildContext context, RecordModel group) async {
  final name = TextEditingController();
  var voice = false;
  final res = await showDialog<(String, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Новый канал'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(hintText: voice ? 'Например: Катка' : 'Например: игры', prefixText: voice ? '🔊 ' : '# '),
              onSubmitted: (_) => Navigator.pop(ctx, (name.text, voice)),
            ),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.tag), label: Text('Текстовый')),
                ButtonSegment(value: true, icon: Icon(Icons.volume_up_outlined), label: Text('Голосовой')),
              ],
              selected: {voice},
              onSelectionChanged: (s) => set(() => voice = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              voice ? 'Голосовой канал — комната, куда можно зайти в любой момент, никому не звоня.' : 'Отдельная переписка внутри группы, например для мемов или одной игры.',
              style: W.small,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, (name.text, voice)), child: const Text('Создать')),
        ],
      ),
    ),
  );
  if (res == null || res.$1.trim().isEmpty) return;
  try {
    final r = await Api.I.pb.collection('chats').create(body: {
      'name': res.$1.trim(),
      'is_group': true,
      'parent': group.id,
      if (res.$2) 'kind': 'voice',
      'members': group.getListValue<String>('members'),
    });
    if (!r.data.containsKey('parent')) {
      if (context.mounted) toast(context, 'Сервер Winter Chat старый — обнови его, чтобы делать каналы');
      try {
        await Api.I.pb.collection('chats').delete(r.id);
      } catch (_) {}
      return;
    }
    Store.I.replaceChat(r);
  } catch (e) {
    if (context.mounted) toast(context, Api.errorText(e, fallback: 'Канал не создался'));
  }
}

Future<void> channelMenu(BuildContext context, RecordModel channel, {Offset? at}) async {
  final group = parentOf(channel);
  final me = Api.I.myId;
  final canDelete = channel.getStringValue('owner') == me || group?.getStringValue('owner') == me;
  final items = <PopupMenuEntry<String>>[
    const PopupMenuItem(value: 'rename', child: Text('Переименовать')),
    if (canDelete) PopupMenuItem(value: 'delete', child: Text('Удалить канал', style: TextStyle(color: W.bad))),
  ];
  final box = context.findRenderObject() as RenderBox?;
  final pos = at ?? (box == null ? Offset.zero : box.localToGlobal(box.size.bottomLeft(Offset.zero)));
  final choice = await showMenu<String>(context: context, position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy), items: items);
  if (choice == null || !context.mounted) return;
  try {
    if (choice == 'rename') {
      final n = await askText(context, 'Название канала', initial: channel.getStringValue('name'));
      if (n == null || n.trim().isEmpty) return;
      Store.I.replaceChat(await Api.I.pb.collection('chats').update(channel.id, body: {'name': n.trim()}));
    } else if (choice == 'delete') {
      if (!await confirm(context, 'Удалить канал «${channel.getStringValue('name')}»?', 'Переписка канала удалится у всех.')) return;
      await Api.I.pb.collection('chats').delete(channel.id);
      Store.I.removeChat(channel.id);
    }
  } catch (e) {
    if (context.mounted) toast(context, Api.errorText(e));
  }
}

/// Полоска каналов над перепиской группы.
class ChannelBar extends StatelessWidget {
  const ChannelBar({super.key, required this.chat, required this.embedded});
  final RecordModel chat;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final group = rootOf(chat);
    final channels = channelsOf(group.id);
    final current = chat.id;

    Widget chip({required String label, required IconData icon, required bool selected, bool unread = false, bool mention = false, int people = 0, VoidCallback? onTap, void Function(Offset)? onMenu}) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onLongPressStart: onMenu == null ? null : (d) => onMenu(d.globalPosition),
          onSecondaryTapDown: onMenu == null ? null : (d) => onMenu(d.globalPosition),
          child: Material(
            color: selected ? W.ice.withValues(alpha: 0.18) : W.surface2,
            shape: StadiumBorder(side: BorderSide(color: selected ? W.ice : W.border)),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: selected ? W.ice : (people > 0 ? W.good : W.muted)),
                    const SizedBox(width: 4),
                    Text(label, style: TextStyle(fontSize: 13, fontWeight: unread || selected ? FontWeight.w700 : FontWeight.w500, color: selected ? W.ice : W.text)),
                    if (people > 0) ...[
                      const SizedBox(width: 5),
                      Text('$people', style: TextStyle(fontSize: 12, color: W.good, fontWeight: FontWeight.w700)),
                    ],
                    if (mention)
                      Padding(padding: const EdgeInsets.only(left: 5), child: Text('@', style: TextStyle(color: W.ice, fontWeight: FontWeight.w900, fontSize: 13)))
                    else if (unread && !selected)
                      Container(width: 7, height: 7, margin: const EdgeInsets.only(left: 5), decoration: BoxDecoration(color: W.ice, shape: BoxShape.circle)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 46,
      decoration: BoxDecoration(color: W.surface, border: Border(bottom: BorderSide(color: W.border))),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        children: [
          chip(
            label: 'общий',
            icon: Icons.tag,
            selected: current == group.id,
            unread: Api.I.isUnread(group),
            mention: Store.I.isMentioned(group.id),
            onTap: current == group.id ? null : () => openChannel(context, group.id, embedded: embedded),
          ),
          for (final c in channels)
            if (isVoiceChannel(c))
              chip(
                label: c.getStringValue('name'),
                icon: Icons.volume_up,
                selected: false,
                people: Store.I.callParticipants(c.id).length,
                onTap: () => startCall(context, c.id, '🔊 ${c.getStringValue('name')} · ${Api.I.chatTitle(group)}', quiet: true),
                onMenu: (at) => channelMenu(context, c, at: at),
              )
            else
              chip(
                label: c.getStringValue('name'),
                icon: Icons.tag,
                selected: current == c.id,
                unread: Api.I.isUnread(c),
                mention: Store.I.isMentioned(c.id),
                onTap: current == c.id ? null : () => openChannel(context, c.id, embedded: embedded),
                onMenu: (at) => channelMenu(context, c, at: at),
              ),
          Tooltip(
            message: 'Новый канал',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.add, size: 20, color: W.muted),
              onPressed: () => createChannel(context, group),
            ),
          ),
        ],
      ),
    );
  }
}
