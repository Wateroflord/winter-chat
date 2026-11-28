import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';

/// Переслать сообщение в другие чаты (до 10 сразу).
Future<void> showForward(BuildContext context, RecordModel message) async {
  final chosen = await showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ForwardSheet(fromChat: message.getStringValue('chat')),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;
  try {
    final n = await Api.I.forward(message.id, chosen);
    if (context.mounted) toast(context, n == 1 ? 'Переслано ✓' : 'Переслано в $n чата ✓');
  } catch (e) {
    if (context.mounted) toast(context, '$e');
  }
}

class _ForwardSheet extends StatefulWidget {
  const _ForwardSheet({required this.fromChat});
  final String fromChat;

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  final _q = TextEditingController();
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final q = _q.text.trim().toLowerCase();
    final chats = [
      for (final c in Store.I.chats)
        if (c.getStringValue('kind') != 'voice' && (q.isEmpty || api.chatTitleFull(c).toLowerCase().contains(q))) c,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    Text('Переслать', style: W.h2),
                    const Spacer(),
                    FilledButton(
                      onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
                      child: Text(_picked.length > 1 ? 'Отправить (${_picked.length})' : 'Отправить'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _q,
                  decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Найти чат'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final c in chats)
                      CheckboxListTile(
                        value: _picked.contains(c.id),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            if (_picked.length >= 10) {
                              toast(context, 'Максимум 10 чатов сразу');
                              return;
                            }
                            _picked.add(c.id);
                          } else {
                            _picked.remove(c.id);
                          }
                        }),
                        secondary: ChatAvatar(c.getStringValue('parent').isNotEmpty ? (Store.I.chat(c.getStringValue('parent')) ?? c) : c, size: 38),
                        title: Text(api.chatTitleFull(c), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: c.id == widget.fromChat ? Text('этот чат', style: W.small) : null,
                      ),
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
