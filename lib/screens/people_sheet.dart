import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

List<RecordModel> _otherUsers({Set<String> exclude = const {}}) {
  final me = Api.I.myId;
  final list = Api.I.users.values.where((u) => u.id != me && !exclude.contains(u.id)).toList()
    ..sort((a, b) => Api.I.nameOfRecord(a).toLowerCase().compareTo(Api.I.nameOfRecord(b).toLowerCase()));
  return list;
}

/// Новый чат: нажми на друга — личный чат; «Создать группу» — выбрать нескольких.
Future<RecordModel?> showNewChat(BuildContext context) async {
  try {
    await Api.I.loadUsers();
  } catch (_) {}
  if (!context.mounted) return null;
  return showModalBottomSheet<RecordModel>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _NewChatSheet(),
  );
}

class _NewChatSheet extends StatefulWidget {
  const _NewChatSheet();

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> {
  bool _group = false;
  bool _busy = false;
  String _query = '';
  final Set<String> _picked = {};
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _openDirect(String userId) async {
    setState(() => _busy = true);
    try {
      final chat = await Store.I.openDirect(userId);
      if (mounted) Navigator.pop(context, chat);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, Api.errorText(e));
      }
    }
  }

  Future<void> _createGroup() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      toast(context, 'Придумай название группы');
      return;
    }
    if (_picked.isEmpty) {
      toast(context, 'Выбери хотя бы одного друга');
      return;
    }
    setState(() => _busy = true);
    try {
      final chat = await Store.I.createGroup(name, _picked.toList());
      if (mounted) Navigator.pop(context, chat);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, Api.errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final users = _otherUsers()
        .where((u) => q.isEmpty || Api.I.nameOfRecord(u).toLowerCase().contains(q) || u.getStringValue('username').toLowerCase().contains(q))
        .toList();
    final h = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: h * 0.8,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: W.border, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(child: Text(_group ? 'Новая группа' : 'Новый чат', style: W.h2)),
                  TextButton.icon(
                    icon: Icon(_group ? Icons.person : Icons.group_add),
                    label: Text(_group ? 'Личный чат' : 'Создать группу'),
                    onPressed: _busy ? null : () => setState(() => _group = !_group),
                  ),
                ],
              ),
            ),
            if (_group)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Название группы', prefixIcon: Icon(Icons.group, color: W.muted)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(hintText: 'Поиск', prefixIcon: Icon(Icons.search, color: W.muted), isDense: true),
              ),
            ),
            Expanded(
              child: users.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Пока тут никого нет. Друзья появятся, когда зарегистрируются на этом сервере с кодом приглашения.',
                          textAlign: TextAlign.center,
                          style: W.small,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: users.length,
                      itemBuilder: (_, i) {
                        final u = users[i];
                        final sel = _picked.contains(u.id);
                        return ListTile(
                          enabled: !_busy,
                          leading: UserAvatar(u.id, size: 40),
                          title: Text(Api.I.nameOfRecord(u)),
                          subtitle: Text('@${u.getStringValue('username')}', style: W.small),
                          trailing: _group
                              ? Checkbox(
                                  value: sel,
                                  onChanged: (_) => setState(() => sel ? _picked.remove(u.id) : _picked.add(u.id)),
                                )
                              : const Icon(Icons.chevron_right, color: W.muted),
                          onTap: () {
                            if (_group) {
                              setState(() => sel ? _picked.remove(u.id) : _picked.add(u.id));
                            } else {
                              _openDirect(u.id);
                            }
                          },
                        );
                      },
                    ),
            ),
            if (_group)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _createGroup,
                      child: Text(_busy ? 'Создаю…' : 'Создать группу (${_picked.length + 1})'),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Выбрать несколько людей (например, добавить в группу).
Future<List<String>?> pickPeople(BuildContext context, {required String title, Set<String> exclude = const {}}) {
  final picked = <String>{};
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final users = _otherUsers(exclude: exclude);
        return SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.7,
          child: Column(
            children: [
              Padding(padding: const EdgeInsets.all(16), child: Text(title, style: W.h2)),
              Expanded(
                child: users.isEmpty
                    ? const Center(child: Text('Все уже здесь', style: W.small))
                    : ListView(
                        children: [
                          for (final u in users)
                            CheckboxListTile(
                              value: picked.contains(u.id),
                              onChanged: (v) => setS(() => v == true ? picked.add(u.id) : picked.remove(u.id)),
                              secondary: UserAvatar(u.id, size: 38),
                              title: Text(Api.I.nameOfRecord(u)),
                              subtitle: Text('@${u.getStringValue('username')}', style: W.small),
                            ),
                        ],
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked.toList()),
                      child: Text('Добавить (${picked.length})'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<void> showMembers(BuildContext context, RecordModel chat) {
  final members = chat.getListValue<String>('members');
  final owner = chat.getStringValue('owner');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.6,
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Text('Участники · ${members.length}', style: W.h2)),
          Expanded(
            child: ListView(
              children: [
                for (final id in members)
                  ListTile(
                    leading: UserAvatar(id, size: 38),
                    title: Text(Api.I.nameOf(id) + (id == Api.I.myId ? ' (ты)' : '')),
                    subtitle: Text('@${Api.I.users[id]?.getStringValue('username') ?? ''}', style: W.small),
                    trailing: id == owner ? const Text('создатель', style: W.small) : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
