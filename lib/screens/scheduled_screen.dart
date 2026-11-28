import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../theme.dart';
import '../util.dart';

/// Отложенные сообщения и напоминания («Напомни всем в 20:00 — катка»).
/// Отправляет сам сервер в нужное время — телефон может быть выключен.

String _when(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (day == today) return 'сегодня в $hm';
  if (day == today.add(const Duration(days: 1))) return 'завтра в $hm';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} в $hm';
}

/// Окно «Отправить позже». true — запланировано.
Future<bool> scheduleMessage(BuildContext context, String chatId, {String text = '', bool remind = false}) async {
  final c = TextEditingController(text: text);
  final now = DateTime.now();
  var at = DateTime(now.year, now.month, now.day, now.hour + 1);
  if (remind && now.hour < 19) at = DateTime(now.year, now.month, now.day, 20);
  var isRemind = remind;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> pickDay() async {
          final d = await showDatePicker(context: ctx, initialDate: at, firstDate: DateTime(now.year, now.month, now.day), lastDate: now.add(const Duration(days: 365)));
          if (d != null) set(() => at = DateTime(d.year, d.month, d.day, at.hour, at.minute));
        }

        Future<void> pickTime() async {
          final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(at));
          if (t != null) set(() => at = DateTime(at.year, at.month, at.day, t.hour, t.minute));
        }

        Widget quick(String label, DateTime t) => ActionChip(label: Text(label), onPressed: () => set(() => at = t));
        final n = DateTime.now();
        return AlertDialog(
          title: Text(isRemind ? '⏰ Напоминание' : 'Отправить позже'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: c,
                    autofocus: text.isEmpty,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: 2000,
                    decoration: InputDecoration(hintText: isRemind ? 'Катка в 20:00 — заходите!' : 'Текст сообщения'),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      quick('Через 15 мин', n.add(const Duration(minutes: 15))),
                      quick('Через час', n.add(const Duration(hours: 1))),
                      if (n.hour < 20) quick('Сегодня в 20:00', DateTime(n.year, n.month, n.day, 20)),
                      quick('Завтра в 10:00', DateTime(n.year, n.month, n.day + 1, 10)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: OutlinedButton.icon(onPressed: pickDay, icon: const Icon(Icons.event, size: 18), label: Text('${at.day.toString().padLeft(2, '0')}.${at.month.toString().padLeft(2, '0')}'))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: pickTime,
                          icon: const Icon(Icons.schedule, size: 18),
                          label: Text('${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Уйдёт ${_when(at)}. Отправит сервер — твой телефон или ПК могут быть выключены.', style: W.small),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: isRemind,
                    onChanged: (v) => set(() => isRemind = v),
                    title: const Text('Напоминание всем'),
                    subtitle: Text('Придёт уведомлением каждому, даже если чат без звука', style: W.small),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(
              onPressed: () {
                if (c.text.trim().isEmpty) {
                  toast(ctx, 'Напиши текст');
                  return;
                }
                if (at.isBefore(DateTime.now())) {
                  toast(ctx, 'Это время уже прошло');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Запланировать'),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) return false;
  try {
    await Api.I.pb.collection('scheduled').create(body: {
      'chat': chatId,
      'text': c.text.trim(),
      'at': at.toUtc().toIso8601String(),
      'remind': isRemind,
    });
    if (context.mounted) toast(context, '${isRemind ? '⏰ Напоминание' : 'Сообщение'} уйдёт ${_when(at)}');
    return true;
  } on ClientException catch (e) {
    if (context.mounted) toast(context, e.statusCode == 404 ? 'Сервер Winter Chat старый — обнови его, чтобы планировать сообщения' : Api.errorText(e, fallback: 'Не запланировалось'));
    return false;
  }
}

/// Список запланированного в чате.
Future<void> showScheduled(BuildContext context, String chatId) {
  return showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => _ScheduledSheet(chatId: chatId));
}

class _ScheduledSheet extends StatefulWidget {
  const _ScheduledSheet({required this.chatId});
  final String chatId;

  @override
  State<_ScheduledSheet> createState() => _ScheduledSheetState();
}

class _ScheduledSheetState extends State<_ScheduledSheet> {
  List<RecordModel>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = await Api.I.pb.collection('scheduled').getFullList(filter: Api.I.pb.filter('chat = {:c}', {'c': widget.chatId}), sort: 'at');
      _error = null;
    } catch (e) {
      _error = Api.errorText(e, fallback: 'Не загрузилось (сервер старый?)');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Text('Запланировано', style: W.h2),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      if (await scheduleMessage(context, widget.chatId)) _load();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Ещё'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _error != null
                  ? Center(child: Text(_error!, style: W.small))
                  : _items == null
                      ? const Center(child: CircularProgressIndicator())
                      : _items!.isEmpty
                          ? Center(child: Text('Ничего не запланировано.\nЗажми кнопку «Отправить» или выбери «Отправить позже» в меню 📎', style: W.small, textAlign: TextAlign.center))
                          : ListView(
                              children: [
                                for (final s in _items!)
                                  ListTile(
                                    leading: Icon(s.getBoolValue('remind') ? Icons.alarm : Icons.schedule_send, color: W.ice),
                                    title: Text(s.getStringValue('text'), maxLines: 2, overflow: TextOverflow.ellipsis),
                                    subtitle: Text(_when((parseDate(s.getStringValue('at')) ?? DateTime.now()).toLocal()), style: W.small),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: 'Отправить сейчас',
                                          icon: const Icon(Icons.send),
                                          onPressed: () async {
                                            try {
                                              await Api.I.pb.collection('scheduled').update(s.id, body: {'at': DateTime.now().toUtc().toIso8601String()});
                                              _load();
                                            } catch (e) {
                                              if (context.mounted) toast(context, Api.errorText(e));
                                            }
                                          },
                                        ),
                                        IconButton(
                                          tooltip: 'Отменить',
                                          icon: Icon(Icons.delete_outline, color: W.bad),
                                          onPressed: () async {
                                            try {
                                              await Api.I.pb.collection('scheduled').delete(s.id);
                                              _load();
                                            } catch (e) {
                                              if (context.mounted) toast(context, Api.errorText(e));
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
