import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../settings.dart';
import '../store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';
import '../widgets/color_picker.dart';
import 'appearance_screen.dart';
import 'chat_screen.dart';
import 'home_screen.dart';

// ───────────────────────────── карточка профиля ─────────────────────────────

/// Баннер профиля: своё фото или градиент из цвета профиля.
class ProfileBanner extends StatelessWidget {
  const ProfileBanner(this.userId, {super.key, this.height = 120});
  final String userId;
  final double height;

  @override
  Widget build(BuildContext context) {
    final url = Api.I.bannerUrl(userId);
    final c = colorFor(userId);
    final gradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(c, Colors.black, 0.15)!, Color.lerp(c, W.bg, 0.65)!],
        ),
      ),
    );
    return SizedBox(
      height: height,
      width: double.infinity,
      child: url == null ? gradient : Image.network(url.toString(), fit: BoxFit.cover, errorBuilder: (_, __, ___) => gradient),
    );
  }
}

/// Профиль человека: баннер, аватар, статус, «о себе».
Future<void> showProfile(BuildContext context, String userId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _ProfileView(userId: userId),
  );
}

class _ProfileView extends StatefulWidget {
  const _ProfileView({required this.userId});
  final String userId;

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Store.I.addListener(_changed); // профиль друга обновляется в реальном времени
  }

  @override
  void dispose() {
    Store.I.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _write() async {
    setState(() => _busy = true);
    try {
      final chat = await Store.I.openDirect(widget.userId);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id)));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, Api.errorText(e));
      }
    }
  }

  Future<void> _call(bool video) async {
    setState(() => _busy = true);
    try {
      final chat = await Store.I.openDirect(widget.userId);
      if (!mounted) return;
      final nav = Navigator.of(context);
      final ctx = nav.context;
      nav.pop();
      await startCall(ctx, chat.id, Api.I.nameOf(widget.userId), withCamera: video);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, Api.errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final id = widget.userId;
    final me = id == api.myId;
    final status = api.statusOf(id);
    final bio = api.bioOf(id);
    final u = api.users[id];
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                ProfileBanner(id, height: 130),
                Positioned(
                  left: 18,
                  bottom: -44,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: ShapeDecoration(shape: avatarShape(96), color: W.surface),
                    child: UserAvatar(id, size: 88),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 52),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(api.nameOf(id), style: W.h1.copyWith(color: nameColorFor(id))),
                  Text('@${u?.getStringValue('username') ?? ''}', style: W.small),
                  if (status != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        children: [
                          if (status.emoji.isNotEmpty) Padding(padding: const EdgeInsets.only(right: 8), child: Text(status.emoji, style: const TextStyle(fontSize: 20))),
                          Expanded(child: Text(status.text.isEmpty ? 'Статус' : status.text, style: W.body)),
                        ],
                      ),
                    ),
                  ],
                  if (bio.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text('О СЕБЕ', style: W.small.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                    const SizedBox(height: 4),
                    SelectableText(bio, style: W.body),
                  ],
                  const SizedBox(height: 18),
                  if (me)
                    FilledButton.icon(
                      onPressed: () {
                        final nav = Navigator.of(context);
                        nav.pop();
                        nav.push(MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Изменить профиль'),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _write,
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Написать'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(tooltip: 'Позвонить', onPressed: _busy ? null : () => _call(false), icon: const Icon(Icons.call_outlined)),
                        IconButton.filledTonal(tooltip: 'Видеозвонок', onPressed: _busy ? null : () => _call(true), icon: const Icon(Icons.videocam_outlined)),
                      ],
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── редактор профиля ─────────────────────────────

/// Быстрые статусы.
const statusPresets = <(String, String)>[
  ('🎮', 'Играю'),
  ('💼', 'На работе'),
  ('📚', 'Учусь'),
  ('🏋️', 'В зале'),
  ('🎧', 'Слушаю музыку'),
  ('😴', 'Сплю'),
  ('🍕', 'Ем'),
  ('🚶', 'Не за компом'),
];

const statusEmojis = ['🎮', '💼', '📚', '🏋️', '🎧', '😴', '🍕', '🚶', '🎸', '🎨', '💻', '🔥', '❄️', '🎬', '🏃', '✈️', '🤒', '🎉', '🤫', '😎'];

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final api = Api.I;
  late RecordModel me = api.users[api.myId] ?? api.me;
  late final _name = TextEditingController(text: api.nameOf(api.myId));
  late final _status = TextEditingController(text: me.getStringValue('status'));
  late final _bio = TextEditingController(text: me.getStringValue('bio'));
  late String _emoji = me.getStringValue('status_emoji');
  late Color? _color = parseHexColor(me.getStringValue('color'));

  /// Через сколько очистить статус: null — никогда.
  Duration? _clearAfter;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _status.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save({List<http.MultipartFile> files = const [], Map<String, dynamic> extra = const {}}) async {
    setState(() => _busy = true);
    try {
      final hasStatus = _status.text.trim().isNotEmpty || _emoji.isNotEmpty;
      final r = await api.pb.collection('users').update(
            api.myId,
            body: {
              'name': _name.text.trim(),
              'status': _status.text.trim(),
              'status_emoji': _emoji,
              'status_until': hasStatus && _clearAfter != null ? DateTime.now().add(_clearAfter!).toUtc().toIso8601String() : '',
              'bio': _bio.text.trim(),
              'color': _color == null ? '' : colorToHex(_color!),
              ...extra,
            },
            files: files,
          );
      api.users[r.id] = r;
      api.pb.authStore.save(api.pb.authStore.token, r);
      setState(() => me = r);
      if (!r.data.containsKey('status') && mounted) {
        toast(context, 'Сервер Winter Chat старый — обнови его, чтобы статус и «о себе» сохранялись');
      } else if (mounted) {
        toast(context, 'Сохранено');
      }
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось сохранить'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickFile(String field) async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    final f = res?.files.firstOrNull;
    if (f == null) return;
    final mp = f.path != null
        ? await http.MultipartFile.fromPath(field, f.path!, filename: f.name)
        : http.MultipartFile.fromBytes(field, f.bytes!, filename: f.name);
    await _save(files: [mp]);
  }

  @override
  Widget build(BuildContext context) {
    final id = api.myId;
    final hasBanner = me.getStringValue('banner').isNotEmpty;
    final hasAvatar = me.getStringValue('avatar').isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        actions: [
          TextButton(onPressed: _busy ? null : () => _save(), child: const Text('Сохранить')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              ProfileBanner(id, height: 140),
              Positioned(
                right: 10,
                top: 10,
                child: Row(
                  children: [
                    if (hasBanner)
                      IconButton.filledTonal(
                        tooltip: 'Убрать картинку',
                        onPressed: _busy ? null : () => _save(extra: {'banner': null}),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    IconButton.filledTonal(
                      tooltip: 'Картинка баннера',
                      onPressed: _busy ? null : () => _pickFile('banner'),
                      icon: const Icon(Icons.image_outlined),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 18,
                bottom: -44,
                child: GestureDetector(
                  onTap: _busy ? null : () => _pickFile('avatar'),
                  child: Stack(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: ShapeDecoration(shape: avatarShape(96), color: W.bg),
                        child: UserAvatar(id, size: 88),
                      ),
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: CircleAvatar(radius: 15, backgroundColor: W.ice, child: Icon(Icons.photo_camera, size: 16, color: W.onAccent)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 50),
          if (hasAvatar)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: _busy ? null : () => _save(extra: {'avatar': null}), child: const Text('Убрать фото')),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(controller: _name, maxLength: 40, decoration: const InputDecoration(labelText: 'Имя', counterText: '')),
                const SizedBox(height: 18),
                Text('СТАТУС', style: W.small.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _pickEmoji,
                      child: Container(
                        width: 50,
                        height: 50,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(12), border: Border.all(color: W.border)),
                        child: _emoji.isEmpty ? Icon(Icons.add_reaction_outlined, color: W.muted) : Text(_emoji, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _status,
                        maxLength: 80,
                        decoration: InputDecoration(
                          hintText: 'Что делаешь?',
                          counterText: '',
                          suffixIcon: _status.text.isEmpty && _emoji.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Очистить',
                                  icon: const Icon(Icons.close),
                                  onPressed: () => setState(() {
                                    _status.clear();
                                    _emoji = '';
                                  }),
                                ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in statusPresets)
                      ActionChip(
                        label: Text('${p.$1} ${p.$2}'),
                        onPressed: () => setState(() {
                          _emoji = p.$1;
                          _status.text = p.$2;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('Убрать статус через', style: W.small),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (label, d) in <(String, Duration?)>[
                      ('никогда', null),
                      ('1 час', const Duration(hours: 1)),
                      ('4 часа', const Duration(hours: 4)),
                      ('сутки', const Duration(days: 1)),
                      ('неделю', const Duration(days: 7)),
                    ])
                      ChoiceChip(label: Text(label), selected: _clearAfter == d, onSelected: (_) => setState(() => _clearAfter = d)),
                  ],
                ),
                const SizedBox(height: 18),
                Text('О СЕБЕ', style: W.small.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                const SizedBox(height: 8),
                TextField(
                  controller: _bio,
                  maxLength: 300,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(hintText: 'Пара слов о себе: во что играешь, чем занимаешься…'),
                ),
                const SizedBox(height: 10),
                Text('ЦВЕТ ПРОФИЛЯ', style: W.small.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                const SizedBox(height: 4),
                Text('Им подсвечивается твоё имя в группах, баннер и аватар без фото — его видят все друзья.', style: W.small),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _ColorDot(
                      color: null,
                      selected: _color == null,
                      onTap: () => setState(() => _color = null),
                    ),
                    for (final c in W.avatarColors.followedBy(const [Color(0xFF3DDCC8), Color(0xFF9C8CFF), Color(0xFFC4CCD8)]))
                      _ColorDot(color: c, selected: _color?.toARGB32() == c.toARGB32(), onTap: () => setState(() => _color = c)),
                    _ColorDot(
                      color: _color != null && !W.avatarColors.any((c) => c.toARGB32() == _color!.toARGB32()) ? _color : null,
                      custom: true,
                      selected: false,
                      onTap: () async {
                        final c = await pickColor(context, initial: _color ?? W.ice, title: 'Цвет профиля');
                        if (c != null) setState(() => _color = c);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: _busy ? null : () => _save(), child: const Text('Сохранить профиль')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEmoji() async {
    final e = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in statusEmojis)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Navigator.pop(ctx, e),
                  child: Padding(padding: const EdgeInsets.all(8), child: Text(e, style: const TextStyle(fontSize: 26))),
                ),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.pop(ctx, ''),
                child: Padding(padding: const EdgeInsets.all(12), child: Text('без', style: W.small)),
              ),
            ],
          ),
        ),
      ),
    );
    if (e != null) setState(() => _emoji = e);
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap, this.custom = false});
  final Color? color;
  final bool selected, custom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: custom ? 'Свой цвет' : (color == null ? 'Автоматически' : colorToHex(color!)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color ?? W.surface2,
            gradient: custom && color == null ? const SweepGradient(colors: [Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red]) : null,
            border: Border.all(color: selected ? W.text : W.border, width: selected ? 3 : 1),
          ),
          child: color == null && !custom ? Icon(Icons.auto_awesome, size: 18, color: W.muted) : (custom ? Icon(Icons.colorize, size: 18, color: onColor(color ?? Colors.white)) : null),
        ),
      ),
    );
  }
}

// ───────────────────────────── настройки чата (только у меня) ─────────────────────────────

Future<void> showChatStyle(BuildContext context, RecordModel chat) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ChatStyleSheet(chat: chat),
  );
}

class _ChatStyleSheet extends StatefulWidget {
  const _ChatStyleSheet({required this.chat});
  final RecordModel chat;

  @override
  State<_ChatStyleSheet> createState() => _ChatStyleSheetState();
}

class _ChatStyleSheetState extends State<_ChatStyleSheet> {
  late ChatPrefs p = Settings.I.chatPrefs(widget.chat.id);

  Future<void> _set(ChatPrefs v) async {
    setState(() => p = v);
    await Settings.I.setChatPrefs(widget.chat.id, v);
    Store.I.resort();
  }

  Future<void> _alias() async {
    final api = Api.I;
    final original = widget.chat.getBoolValue('is_group')
        ? widget.chat.getStringValue('name')
        : api.nameOf(api.otherMember(widget.chat) ?? api.myId);
    final c = TextEditingController(text: p.alias);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Имя чата для себя'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(hintText: original, helperText: 'Видишь только ты. Пусто — обычное имя.'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Готово')),
        ],
      ),
    );
    if (v != null) await _set(p.copyWith(alias: v.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final wp = p.wallpaper;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Этот чат', style: W.h2),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Эти настройки только на этом устройстве — друзья их не видят.', style: W.small),
            ),
            SwitchListTile(
              secondary: Icon(Icons.push_pin_outlined, color: W.muted),
              title: const Text('Закрепить наверху списка'),
              value: p.pin,
              onChanged: (v) => _set(p.copyWith(pin: v)),
            ),
            SwitchListTile(
              secondary: Icon(Icons.notifications_off_outlined, color: W.muted),
              title: const Text('Без звука'),
              subtitle: Text('Ни звука, ни уведомлений, ни звонка-рингтона', style: W.small),
              value: p.mute,
              onChanged: (v) => _set(p.copyWith(mute: v)),
            ),
            ListTile(
              leading: Icon(Icons.drive_file_rename_outline, color: W.muted),
              title: const Text('Имя чата для себя'),
              subtitle: Text(p.alias.isEmpty ? 'Как у всех' : p.alias, style: W.small),
              onTap: _alias,
            ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.wallpaper_outlined, color: W.muted),
              title: const Text('Фон этого чата'),
              subtitle: Text(wp == null ? 'Как во всех чатах' : 'Свой', style: W.small),
              trailing: wp == null ? null : TextButton(onPressed: () => _set(p.copyWith(clearWallpaper: true)), child: const Text('Сбросить')),
            ),
            SizedBox(
              height: 112,
              child: WallpaperPicker(
                selected: wp,
                onPick: (w) => _set(p.copyWith(wallpaper: w)),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.chat_bubble_outline, color: W.muted),
              title: const Text('Цвет моих сообщений здесь'),
              subtitle: Text(p.bubble == null ? 'Как во всех чатах' : colorToHex(p.bubble!), style: W.small),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.bubble != null) TextButton(onPressed: () => _set(p.copyWith(clearBubble: true)), child: const Text('Сбросить')),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(color: Settings.I.myBubbleFor(widget.chat.id), borderRadius: BorderRadius.circular(8), border: Border.all(color: W.border)),
                  ),
                ],
              ),
              onTap: () async {
                final c = await pickColor(context, initial: Settings.I.myBubbleFor(widget.chat.id), title: 'Цвет моих сообщений');
                if (c != null) await _set(p.copyWith(bubble: c));
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── фото и описание группы ─────────────────────────────

Future<void> editGroup(BuildContext context, RecordModel chat) async {
  final desc = TextEditingController(text: chat.getStringValue('description'));
  var current = chat;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> save({List<http.MultipartFile> files = const [], Map<String, dynamic> body = const {}}) async {
          set(() => busy = true);
          try {
            final r = await Api.I.pb.collection('chats').update(chat.id, body: body, files: files);
            Store.I.replaceChat(r);
            current = r;
            if (!r.data.containsKey('description') && ctx.mounted) {
              toast(ctx, 'Сервер Winter Chat старый — обнови его, чтобы фото и описание группы сохранялись');
            }
          } catch (e) {
            if (ctx.mounted) toast(ctx, Api.errorText(e));
          }
          if (ctx.mounted) set(() => busy = false);
        }

        return AlertDialog(
          title: const Text('Группа'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ChatAvatar(current, size: 88),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final res = await FilePicker.platform.pickFiles(type: FileType.image);
                              final f = res?.files.firstOrNull;
                              if (f == null) return;
                              final mp = f.path != null
                                  ? await http.MultipartFile.fromPath('avatar', f.path!, filename: f.name)
                                  : http.MultipartFile.fromBytes('avatar', f.bytes!, filename: f.name);
                              await save(files: [mp]);
                            },
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Фото группы'),
                    ),
                    if (current.getStringValue('avatar').isNotEmpty)
                      TextButton(onPressed: busy ? null : () => save(body: {'avatar': null}), child: const Text('Убрать')),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: desc,
                  maxLength: 200,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(labelText: 'Описание', hintText: 'О чём эта группа'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      await save(body: {'description': desc.text.trim()});
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    ),
  );
}

/// Скопировать выбранное фото фона в папку приложения (оригинал из галереи могут удалить).
Future<String?> importWallpaperImage() async {
  final res = await FilePicker.platform.pickFiles(type: FileType.image);
  final f = res?.files.firstOrNull;
  if (f == null) return null;
  final dir = await getApplicationSupportDirectory();
  final ext = (f.extension ?? 'jpg').toLowerCase();
  final dst = File('${dir.path}${Platform.pathSeparator}wallpaper_${DateTime.now().millisecondsSinceEpoch}.$ext');
  if (f.path != null) {
    await File(f.path!).copy(dst.path);
  } else if (f.bytes != null) {
    await dst.writeAsBytes(f.bytes!);
  } else {
    return null;
  }
  return dst.path;
}
