import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' show Hardware, MediaDevice;
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../call_controller.dart';
import '../main.dart' show buildNumber;
import '../settings.dart';
import '../sounds.dart';
import '../theme.dart';
import '../util.dart';
import '../vpn.dart';
import '../widgets/avatar.dart';
import '../widgets/chat_background.dart';

Future<void> openSettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
bool get _android => !kIsWeb && Platform.isAndroid;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Settings.I.addListener(_changed);
    Api.I.addListener(_changed);
  }

  @override
  void dispose() {
    Settings.I.removeListener(_changed);
    Api.I.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!Api.I.loggedIn) return const Scaffold(body: SizedBox.shrink());
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
            children: const [
              _AccountSection(),
              _NotifySection(),
              _AppearanceSection(),
              _CallsSection(),
              _NetworkSection(),
              _AboutSection(),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- общие кирпичики ----------

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.children});
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: accent, letterSpacing: 0.3)),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: W.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: W.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: _divided(children)),
          ),
        ],
      ),
    );
  }

  static List<Widget> _divided(List<Widget> items) {
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.add(const Divider(height: 1, thickness: 1, color: W.border, indent: 16, endIndent: 16));
      out.add(items[i]);
    }
    return out;
  }
}

class _Switch extends StatelessWidget {
  const _Switch({required this.title, this.subtitle, required this.value, required this.onChanged, this.icon});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: icon == null ? null : Icon(icon, color: W.muted),
      title: Text(title, style: W.body),
      subtitle: subtitle == null ? null : Text(subtitle!, style: W.small),
      value: value,
      onChanged: onChanged,
    );
  }
}

// ---------- аккаунт ----------

class _AccountSection extends StatefulWidget {
  const _AccountSection();

  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  late final _name = TextEditingController(text: Api.I.nameOf(Api.I.myId));
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save({List<http.MultipartFile> files = const []}) async {
    setState(() => _busy = true);
    try {
      final r = await Api.I.pb.collection('users').update(
            Api.I.myId,
            body: {'name': _name.text.trim()},
            files: files,
          );
      Api.I.users[r.id] = r;
      Api.I.pb.authStore.save(Api.I.pb.authStore.token, r);
      if (mounted) toast(context, 'Сохранено');
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось сохранить'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickAvatar() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    final f = res?.files.firstOrNull;
    if (f == null) return;
    final mp = f.path != null
        ? await http.MultipartFile.fromPath('avatar', f.path!, filename: f.name)
        : http.MultipartFile.fromBytes('avatar', f.bytes!, filename: f.name);
    await _save(files: [mp]);
  }

  Future<void> _removeAvatar() async {
    setState(() => _busy = true);
    try {
      final r = await Api.I.pb.collection('users').update(Api.I.myId, body: {'avatar': null});
      Api.I.users[r.id] = r;
      Api.I.pb.authStore.save(Api.I.pb.authStore.token, r);
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось убрать фото'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _changePassword() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _PasswordDialog());
    if (ok == true && mounted) toast(context, 'Пароль изменён');
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text('Чтобы вернуться, понадобятся логин и пароль.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Выйти', style: TextStyle(color: W.bad))),
        ],
      ),
    );
    if (ok != true) return;
    await CallController.I.leave();
    await Api.I.logout();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final me = api.users[api.myId] ?? api.me;
    final hasAvatar = me.getStringValue('avatar').isNotEmpty;
    return _Section(
      icon: Icons.person_outline,
      title: 'АККАУНТ',
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Stack(
                children: [
                  UserAvatar(api.myId, size: 76),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: Theme.of(context).colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _busy ? null : _pickAvatar,
                        child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.photo_camera, size: 16, color: W.bg)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _name,
                            enabled: !_busy,
                            decoration: const InputDecoration(labelText: 'Имя', isDense: true),
                            onSubmitted: (_) => _save(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: 'Сохранить имя',
                          onPressed: _busy ? null : () => _save(),
                          icon: const Icon(Icons.check),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Логин: @${me.getStringValue('username')}', style: W.small),
                    if (hasAvatar)
                      TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                        onPressed: _busy ? null : _removeAvatar,
                        child: const Text('Убрать фото'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.password, color: W.muted),
          title: const Text('Сменить пароль', style: W.body),
          trailing: const Icon(Icons.chevron_right, color: W.muted),
          onTap: _busy ? null : _changePassword,
        ),
        ListTile(
          leading: const Icon(Icons.logout, color: W.bad),
          title: const Text('Выйти из аккаунта', style: TextStyle(color: W.bad)),
          onTap: _busy ? null : _logout,
        ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _new2 = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _new2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    String? err;
    if (_old.text.isEmpty) {
      err = 'Введи старый пароль';
    } else if (_new.text.length < 8) {
      err = 'Новый пароль — минимум 8 символов';
    } else if (_new.text != _new2.text) {
      err = 'Новые пароли не совпадают';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.I.changePassword(_old.text, _new.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = Api.errorText(e, fallback: 'Не удалось сменить пароль');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          suffixIcon: IconButton(
            icon: Icon(_show ? Icons.visibility_off : Icons.visibility, color: W.muted),
            onPressed: () => setState(() => _show = !_show),
          ),
        );
    return AlertDialog(
      title: const Text('Сменить пароль'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _old, obscureText: !_show, enabled: !_busy, decoration: deco('Старый пароль')),
            const SizedBox(height: 10),
            TextField(controller: _new, obscureText: !_show, enabled: !_busy, decoration: deco('Новый пароль')),
            const SizedBox(height: 10),
            TextField(
              controller: _new2,
              obscureText: !_show,
              enabled: !_busy,
              decoration: deco('Новый пароль ещё раз'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: W.bad)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: W.bg))
              : const Text('Сменить'),
        ),
      ],
    );
  }
}

// ---------- уведомления и звуки ----------

class _NotifySection extends StatelessWidget {
  const _NotifySection();

  String _dndText(Settings s) {
    if (!s.dnd) return 'Выключено';
    if (s.dndForever) return 'Включено, пока не выключишь';
    final u = s.dndUntil;
    if (u == null) return 'Включено';
    final today = sameDay(u, DateTime.now());
    return 'Включено до ${today ? '' : '${two(u.day)}.${two(u.month)} '}${hhmm(u)}';
  }

  Future<void> _pickDnd(BuildContext context) async {
    final now = DateTime.now();
    var morning = DateTime(now.year, now.month, now.day, 8);
    if (!morning.isAfter(now)) morning = morning.add(const Duration(days: 1));
    final options = <(String, Duration?)>[
      ('На 1 час', const Duration(hours: 1)),
      ('На 3 часа', const Duration(hours: 3)),
      ('До 8 утра', morning.difference(now)),
      ('Пока не выключу', Duration.zero),
      ('Выключить', null),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text('Не беспокоить: без уведомлений и звуков', style: W.h2),
            ),
            for (var i = 0; i < options.length; i++)
              ListTile(
                leading: Icon(options[i].$2 == null ? Icons.notifications_active_outlined : Icons.bedtime_outlined, color: W.muted),
                title: Text(options[i].$1),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await Settings.I.setDnd(options[picked].$2);
  }

  // Разделы в списке настроек — const и не перестраиваются вместе с экраном,
  // поэтому каждый сам слушает настройки (иначе переключатели «не переключаются»).
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Settings.I, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = Settings.I;
    return _Section(
      icon: Icons.notifications_none,
      title: 'УВЕДОМЛЕНИЯ И ЗВУКИ',
      children: [
        ListTile(
          leading: Icon(s.dnd ? Icons.bedtime : Icons.bedtime_outlined, color: s.dnd ? W.warn : W.muted),
          title: const Text('Не беспокоить', style: W.body),
          subtitle: Text(_dndText(s), style: W.small),
          trailing: const Icon(Icons.chevron_right, color: W.muted),
          onTap: () => _pickDnd(context),
        ),
        if (_android) ...[
          _Switch(
            icon: Icons.notifications_outlined,
            title: 'Уведомления о сообщениях',
            subtitle: 'Когда приложение свёрнуто (Android проверяет примерно раз в 15 минут)',
            value: s.notify,
            onChanged: (v) => s.notify = v,
          ),
          _Switch(
            icon: Icons.volume_up_outlined,
            title: 'Звук уведомлений',
            value: s.notifySound,
            onChanged: s.notify ? (v) => s.notifySound = v : (_) {},
          ),
        ],
        _Switch(
          icon: Icons.music_note_outlined,
          title: 'Звук нового сообщения',
          subtitle: 'Пока приложение открыто, а сообщение пришло в другой чат',
          value: s.inAppSound,
          onChanged: (v) {
            s.inAppSound = v;
            if (v) Sounds.message(force: true);
          },
        ),
        _Switch(
          icon: Icons.ring_volume_outlined,
          title: 'Звук входящего звонка',
          value: s.ringSound,
          onChanged: (v) => s.ringSound = v,
        ),
      ],
    );
  }
}

// ---------- внешний вид ----------

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  // Разделы в списке настроек — const и не перестраиваются вместе с экраном,
  // поэтому каждый сам слушает настройки (иначе переключатели «не переключаются»).
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Settings.I, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = Settings.I;
    final scales = Settings.textScales;
    var idx = scales.indexWhere((v) => (v - s.textScale).abs() < 0.01);
    if (idx < 0) idx = 1;
    return _Section(
      icon: Icons.palette_outlined,
      title: 'ВНЕШНИЙ ВИД',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.format_size, color: W.muted),
                  const SizedBox(width: 16),
                  const Expanded(child: Text('Размер текста', style: W.body)),
                  Text('${(scales[idx] * 100).round()}%', style: W.small),
                ],
              ),
              Slider(
                value: idx.toDouble(),
                min: 0,
                max: (scales.length - 1).toDouble(),
                divisions: scales.length - 1,
                onChanged: (v) => s.textScale = scales[v.round()],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.color_lens_outlined, color: W.muted),
                  SizedBox(width: 16),
                  Text('Цвет акцента', style: W.body),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < Settings.accents.length; i++)
                    Tooltip(
                      message: Settings.accents[i].$1,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => s.accentIndex = i,
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Settings.accents[i].$2,
                            shape: BoxShape.circle,
                            border: Border.all(color: s.accentIndex == i ? W.text : Colors.transparent, width: 3),
                          ),
                          child: s.accentIndex == i ? const Icon(Icons.check, color: W.bg, size: 20) : null,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.wallpaper_outlined, color: W.muted),
                  SizedBox(width: 16),
                  Text('Фон чата', style: W.body),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 104,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: Settings.backgrounds.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final selected = s.chatBackground == i;
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => s.chatBackground = i,
                      child: Column(
                        children: [
                          Container(
                            width: 72,
                            height: 76,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected ? Theme.of(context).colorScheme.primary : W.border,
                                width: selected ? 2.5 : 1,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                i == 0 ? const ColoredBox(color: W.bg) : ChatBackgroundPreview(style: i),
                                Align(
                                  alignment: const Alignment(0.6, 0.5),
                                  child: Container(
                                    width: 30,
                                    height: 12,
                                    decoration: BoxDecoration(color: s.myBubble, borderRadius: BorderRadius.circular(6)),
                                  ),
                                ),
                                Align(
                                  alignment: const Alignment(-0.6, -0.2),
                                  child: Container(
                                    width: 34,
                                    height: 12,
                                    decoration: BoxDecoration(color: W.surface2, borderRadius: BorderRadius.circular(6)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(Settings.backgrounds[i], style: const TextStyle(fontSize: 11, color: W.muted)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        _Switch(
          icon: Icons.density_small,
          title: 'Компактные сообщения',
          subtitle: 'Меньше отступов — больше сообщений на экране',
          value: s.compact,
          onChanged: (v) => s.compact = v,
        ),
      ],
    );
  }
}

// ---------- звонки и медиа ----------

class _CallsSection extends StatefulWidget {
  const _CallsSection();

  @override
  State<_CallsSection> createState() => _CallsSectionState();
}

class _CallsSectionState extends State<_CallsSection> {
  List<MediaDevice> _mics = [];
  List<MediaDevice> _cams = [];
  List<MediaDevice> _speakers = [];
  String? _cacheSize;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _measureCache();
  }

  Future<void> _loadDevices() async {
    try {
      final mics = await Hardware.instance.audioInputs();
      final cams = _desktop ? await Hardware.instance.videoInputs() : <MediaDevice>[];
      final spk = _desktop ? await Hardware.instance.audioOutputs() : <MediaDevice>[];
      if (!mounted) return;
      setState(() {
        _mics = mics.where((d) => d.deviceId.isNotEmpty).toList();
        _cams = cams.where((d) => d.deviceId.isNotEmpty).toList();
        _speakers = spk.where((d) => d.deviceId.isNotEmpty).toList();
      });
    } catch (_) {}
  }

  Future<int> _dirSize(Directory d) async {
    var total = 0;
    try {
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  Future<void> _measureCache() async {
    try {
      final tmp = await getTemporaryDirectory();
      final size = await _dirSize(tmp);
      if (mounted) setState(() => _cacheSize = humanSize(size));
    } catch (_) {
      if (mounted) setState(() => _cacheSize = null);
    }
  }

  Future<void> _clearCache() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      final tmp = await getTemporaryDirectory();
      await for (final e in tmp.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    await _measureCache();
    if (mounted) toast(context, 'Кэш очищен');
  }

  Widget _devicePicker({
    required IconData icon,
    required String title,
    required List<MediaDevice> devices,
    required String selected,
    required ValueChanged<String> onChanged,
  }) {
    final ids = devices.map((d) => d.deviceId).toSet();
    final value = ids.contains(selected) ? selected : '';
    return ListTile(
      leading: Icon(icon, color: W.muted),
      title: Text(title, style: W.body),
      subtitle: DropdownButton<String>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: W.surface2,
        style: W.small.copyWith(color: W.text),
        items: [
          const DropdownMenuItem(value: '', child: Text('По умолчанию')),
          for (final d in devices)
            DropdownMenuItem(
              value: d.deviceId,
              child: Text(d.label.isEmpty ? 'Устройство ${d.deviceId.length > 6 ? d.deviceId.substring(0, 6) : d.deviceId}' : d.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => onChanged(v ?? ''),
      ),
    );
  }

  // Разделы в списке настроек — const и не перестраиваются вместе с экраном,
  // поэтому каждый сам слушает настройки (иначе переключатели «не переключаются»).
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Settings.I, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = Settings.I;
    return _Section(
      icon: Icons.call_outlined,
      title: 'ЗВОНКИ И МЕДИА',
      children: [
        if (_mics.isNotEmpty)
          _devicePicker(
            icon: Icons.mic_none,
            title: 'Микрофон',
            devices: _mics,
            selected: s.micId,
            onChanged: (v) => s.micId = v,
          ),
        if (_desktop && _speakers.isNotEmpty)
          _devicePicker(
            icon: Icons.headphones_outlined,
            title: 'Динамики / наушники',
            devices: _speakers,
            selected: s.speakerId,
            onChanged: (v) => s.speakerId = v,
          ),
        if (_desktop && _cams.isNotEmpty)
          _devicePicker(
            icon: Icons.videocam_outlined,
            title: 'Камера',
            devices: _cams,
            selected: s.cameraId,
            onChanged: (v) => s.cameraId = v,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              const Icon(Icons.hd_outlined, color: W.muted),
              const SizedBox(width: 16),
              const Expanded(child: Text('Качество камеры', style: W.body)),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 0, label: Text('540p')),
                  ButtonSegment(value: 1, label: Text('720p')),
                  ButtonSegment(value: 2, label: Text('1080p')),
                ],
                selected: {s.cameraQuality},
                onSelectionChanged: (v) => s.cameraQuality = v.first,
              ),
            ],
          ),
        ),
        _Switch(
          icon: Icons.noise_aware,
          title: 'Шумоподавление',
          subtitle: 'Убирает шум вентилятора, клавиатуры, улицы',
          value: s.noiseSuppression,
          onChanged: (v) => s.noiseSuppression = v,
        ),
        _Switch(
          icon: Icons.surround_sound_outlined,
          title: 'Подавление эха',
          subtitle: 'Нужно, если говоришь без наушников',
          value: s.echoCancellation,
          onChanged: (v) => s.echoCancellation = v,
        ),
        _Switch(
          icon: Icons.graphic_eq,
          title: 'Автогромкость микрофона',
          value: s.autoGain,
          onChanged: (v) => s.autoGain = v,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 2, 16, 10),
          child: Text('Микрофон, камера и звук применяются к следующему звонку.', style: W.small),
        ),
        _Switch(
          icon: Icons.image_outlined,
          title: 'Показывать фото сразу',
          subtitle: 'Выключи, чтобы экономить мобильный интернет: фото откроется по нажатию',
          value: s.autoloadImages,
          onChanged: (v) => s.autoloadImages = v,
        ),
        _Switch(
          icon: Icons.volume_off_outlined,
          title: 'Видео без звука',
          subtitle: 'Видео в чате начинает играть беззвучно (звук включается в плеере)',
          value: s.videoMuted,
          onChanged: (v) => s.videoMuted = v,
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined, color: W.muted),
          title: const Text('Очистить кэш', style: W.body),
          subtitle: Text(_cacheSize == null ? 'Временные файлы и картинки' : 'Временные файлы: $_cacheSize', style: W.small),
          onTap: _clearCache,
        ),
      ],
    );
  }
}

// ---------- сеть и Winter VPN ----------

class _NetworkSection extends StatefulWidget {
  const _NetworkSection();

  @override
  State<_NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<_NetworkSection> {
  List<VpnAddr>? _local;
  String? _checking;

  @override
  void initState() {
    super.initState();
    // Список адресов приходит с сервера чуть позже — перерисоваться, когда придёт.
    Api.I.addListener(_apiChanged);
    _scan();
    Api.I.refreshInfo();
  }

  @override
  void dispose() {
    Api.I.removeListener(_apiChanged);
    super.dispose();
  }

  void _apiChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    final l = await Vpn.local();
    if (mounted) setState(() => _local = l);
  }

  Future<void> _connect(String url) async {
    setState(() => _checking = url);
    final ok = await Api.I.isSameServer(url);
    if (!mounted) return;
    setState(() => _checking = null);
    if (!ok) {
      toast(
        context,
        Vpn.isWinterUrl(url)
            ? 'Не отвечает. Включи Winter VPN на этом устройстве и проверь, что он включён на компьютере-сервере.'
            : 'Этот адрес сейчас не отвечает',
      );
      return;
    }
    await Api.I.switchTo(url);
    if (mounted) toast(context, 'Подключено: ${url.replaceFirst('http://', '')}');
  }

  bool _enabling = false;

  Future<void> _enable() async {
    setState(() => _enabling = true);
    final ok = await Vpn.connect();
    if (!ok) {
      final opened = await Vpn.open();
      if (!opened && mounted) toast(context, 'Winter VPN не установлен — поставь его через Winter Hub');
    }
    // VPN поднимается пару секунд.
    for (var i = 0; i < 8 && mounted; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await _scan();
      if (_local?.isNotEmpty ?? false) break;
    }
    if (mounted) setState(() => _enabling = false);
  }

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final local = _local;
    final on = local?.isNotEmpty ?? false;
    final urls = api.knownUrls;
    return _Section(
      icon: Icons.hub_outlined,
      title: 'СЕТЬ И WINTER VPN',
      children: [
        ListTile(
          leading: Icon(on ? Icons.shield : Icons.shield_outlined, color: on ? W.good : W.muted),
          title: Text(on ? 'Winter VPN включён' : 'Winter VPN выключен', style: W.body),
          subtitle: Text(
            local == null
                ? 'Проверяю…'
                : on
                    ? 'Твой адрес в сети: ${local.first.ip}'
                    : 'Нужен, чтобы попасть на сервер друзей',
            style: W.small,
          ),
          trailing: IconButton(tooltip: 'Обновить', icon: const Icon(Icons.refresh, color: W.muted), onPressed: _scan),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (!on && local != null)
                FilledButton.icon(
                  onPressed: _enabling ? null : _enable,
                  icon: _enabling
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: W.bg))
                      : const Icon(Icons.power_settings_new, size: 18),
                  label: const Text('Включить Winter VPN'),
                ),
              OutlinedButton.icon(
                onPressed: () async {
                  final opened = await Vpn.open();
                  if (!opened && context.mounted) {
                    toast(context, 'Winter VPN не установлен — открыл страницу загрузки (или поставь его через Winter Hub)');
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Открыть Winter VPN'),
              ),
            ],
          ),
        ),
        for (final u in urls)
          ListTile(
            leading: Icon(
              u == api.serverUrl ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: u == api.serverUrl ? Theme.of(context).colorScheme.primary : W.muted,
            ),
            title: Text(u.replaceFirst('http://', ''), style: W.body.copyWith(fontFamily: 'monospace')),
            subtitle: Text(
              [
                if (u == api.primaryUrl) 'основной адрес',
                if (Vpn.isWinterUrl(u)) 'через Winter VPN',
                if (u == api.serverUrl) 'сейчас используется',
              ].join(' · '),
              style: W.small,
            ),
            trailing: _checking == u
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : u == api.serverUrl
                    ? IconButton(
                        tooltip: 'Копировать',
                        icon: const Icon(Icons.copy, size: 18, color: W.muted),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: u.replaceFirst('http://', '')));
                          toast(context, 'Скопировано');
                        },
                      )
                    : TextButton(onPressed: () => _connect(u), child: const Text('Подключиться')),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Text(
            'Если адрес не отвечает, приложение само попробует другие адреса этого сервера. '
            'На ПК Winter VPN включается сам при запуске чата.',
            style: W.small,
          ),
        ),
      ],
    );
  }
}

/// Подсказка про Winter VPN — на экране входа и когда нет связи с сервером.
class VpnHint extends StatefulWidget {
  const VpnHint({super.key, this.serverText, this.onEnabled});

  /// Адрес, который ввели на экране входа (чтобы понять, нужен ли VPN).
  final String? serverText;

  /// VPN включили — можно пробовать подключиться снова.
  final VoidCallback? onEnabled;

  @override
  State<VpnHint> createState() => _VpnHintState();
}

class _VpnHintState extends State<VpnHint> {
  bool? _on;
  bool _enabling = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final on = await Vpn.isOn();
    if (mounted) setState(() => _on = on);
  }

  Future<void> _enable() async {
    setState(() => _enabling = true);
    final ok = await Vpn.connect();
    if (!ok) {
      final opened = await Vpn.open();
      if (!opened && mounted) toast(context, 'Winter VPN не установлен — поставь его через Winter Hub');
    }
    for (var i = 0; i < 8 && mounted; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await _scan();
      if (_on == true) break;
    }
    if (!mounted) return;
    setState(() => _enabling = false);
    if (_on == true) widget.onEnabled?.call();
  }

  @override
  Widget build(BuildContext context) {
    final on = _on ?? false;
    final typed = widget.serverText ?? Api.I.serverUrl;
    final vpnAddr = Vpn.isWinterUrl(Api.normalizeUrl(typed));
    final text = vpnAddr
        ? (on
            ? 'Winter VPN включён. Если всё равно не подключается — проверь, что Winter VPN включён и на компьютере-сервере.'
            : 'Сервер — в Winter VPN. Включи Winter VPN, и всё заработает.')
        : 'Сервер друзей доступен через Winter VPN: попроси у владельца ссылку-приглашение — '
            'она сама включит VPN и заполнит адрес (100.x.x.x:8090).';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: W.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: W.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(on ? Icons.shield : Icons.shield_outlined, size: 18, color: on ? W.good : W.ice),
              const SizedBox(width: 8),
              Text(on ? 'Winter VPN включён' : 'Winter VPN выключен', style: const TextStyle(fontWeight: FontWeight.w700, color: W.text)),
            ],
          ),
          const SizedBox(height: 6),
          Text(text, style: W.small),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (!on)
                FilledButton.icon(
                  onPressed: _enabling ? null : _enable,
                  icon: _enabling
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: W.bg))
                      : const Icon(Icons.power_settings_new, size: 16),
                  label: const Text('Включить Winter VPN'),
                ),
              OutlinedButton.icon(
                onPressed: () async {
                  final opened = await Vpn.open();
                  if (!opened && context.mounted) toast(context, 'Открыл страницу загрузки Winter VPN');
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Открыть Winter VPN'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------- о приложении ----------

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return _Section(
      icon: Icons.info_outline,
      title: 'О ПРИЛОЖЕНИИ',
      children: [
        ListTile(
          leading: const Icon(Icons.ac_unit, color: W.muted),
          title: const Text('Winter Chat', style: W.body),
          subtitle: Text('Сборка $buildNumber', style: W.small),
        ),
      ],
    );
  }
}
