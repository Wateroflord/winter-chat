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
import '../instant.dart';
import '../main.dart' show buildNumber;
import '../settings.dart';
import '../sounds.dart';
import '../theme.dart';
import '../util.dart';
import '../vpn.dart';
import '../widgets/avatar.dart';
import '../widgets/chat_background.dart';
import 'appearance_screen.dart';
import 'profile_sheet.dart';

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
      if (i > 0) out.add(Divider(height: 1, thickness: 1, color: W.border, indent: 16, endIndent: 16));
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
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Выйти', style: TextStyle(color: W.bad))),
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
                        child: Padding(padding: EdgeInsets.all(6), child: Icon(Icons.photo_camera, size: 16, color: W.bg)),
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
          leading: Icon(Icons.badge_outlined, color: W.muted),
          title: Text('Профиль: статус, о себе, цвет, баннер', style: W.body),
          subtitle: Text(Api.I.statusText(Api.I.myId).isEmpty ? 'Это видят друзья' : Api.I.statusText(Api.I.myId), style: W.small),
          trailing: Icon(Icons.chevron_right, color: W.muted),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileEditScreen())),
        ),
        _Switch(
          icon: Icons.circle_outlined,
          title: 'Показывать, что я в сети',
          subtitle: 'Друзья видят «в сети» и «был(а) 5 мин назад»',
          value: Settings.I.showOnline,
          onChanged: (v) {
            Settings.I.showOnline = v;
            if (v) Api.I.ping();
          },
        ),
        ListTile(
          leading: Icon(Icons.password, color: W.muted),
          title: Text('Сменить пароль', style: W.body),
          trailing: Icon(Icons.chevron_right, color: W.muted),
          onTap: _busy ? null : _changePassword,
        ),
        ListTile(
          leading: Icon(Icons.logout, color: W.bad),
          title: Text('Выйти из аккаунта', style: TextStyle(color: W.bad)),
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
              Text(_error!, style: TextStyle(color: W.bad)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: W.bg))
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
            Padding(
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

  @override
  Widget build(BuildContext context) {
    final s = Settings.I;
    return _Section(
      icon: Icons.notifications_none,
      title: 'УВЕДОМЛЕНИЯ И ЗВУКИ',
      children: [
        ListTile(
          leading: Icon(s.dnd ? Icons.bedtime : Icons.bedtime_outlined, color: s.dnd ? W.warn : W.muted),
          title: Text('Не беспокоить', style: W.body),
          subtitle: Text(_dndText(s), style: W.small),
          trailing: Icon(Icons.chevron_right, color: W.muted),
          onTap: () => _pickDnd(context),
        ),
        _Switch(
          icon: Icons.notifications_outlined,
          title: 'Уведомления о сообщениях',
          subtitle: !_android
              ? 'Когда окно свёрнуто или не в фокусе'
              : (s.instantNotify ? 'Сразу, когда приложение свёрнуто' : 'Когда приложение свёрнуто (Android проверяет примерно раз в 15 минут)'),
          value: s.notify,
          onChanged: (v) => s.notify = v,
        ),
        if (_android) ...[
          _Switch(
            icon: Icons.bolt_outlined,
            title: 'Мгновенно',
            subtitle: 'Приложение остаётся на связи с сервером. В шторке будет тихое «Winter Chat на связи» — '
                'его можно скрыть: долгое нажатие на него → выключить этот канал.',
            value: s.instantNotify,
            onChanged: s.notify ? (v) => s.instantNotify = v : (_) {},
          ),
          if (s.notify && s.instantNotify) const _BatteryTile(),
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

/// Подсказка: чтобы Android не усыплял приложение (иначе «мгновенно» иногда опаздывает).
class _BatteryTile extends StatefulWidget {
  const _BatteryTile();

  @override
  State<_BatteryTile> createState() => _BatteryTileState();
}

class _BatteryTileState extends State<_BatteryTile> with WidgetsBindingObserver {
  bool? _ok;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final ok = await Instant.batteryOk();
    if (mounted) setState(() => _ok = ok);
  }

  @override
  Widget build(BuildContext context) {
    if (_ok != false) return const SizedBox.shrink();
    return ListTile(
      leading: Icon(Icons.battery_alert_outlined, color: W.warn),
      title: Text('Не усыплять Winter Chat', style: W.body),
      subtitle: Text('Без этого Android может придержать уведомления, когда телефон долго лежит. Нажми и разреши.', style: W.small),
      trailing: Icon(Icons.chevron_right, color: W.muted),
      onTap: Instant.askBattery,
    );
  }
}

// ---------- внешний вид ----------

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final s = Settings.I;
    final wp = s.wallpaper;
    final wpName = switch (wp.kind) {
      1 => Wallpaper.presets[(wp.preset - 1).clamp(0, Wallpaper.presets.length - 1)],
      2 => 'свой градиент',
      3 => 'своё фото',
      _ => 'без фона',
    };
    return _Section(
      icon: Icons.palette_outlined,
      title: 'ВНЕШНИЙ ВИД',
      children: [
        ListTile(
          leading: Icon(Icons.brush_outlined, color: W.ice),
          title: Text('Оформление', style: W.body),
          subtitle: Text(
            'Тема «${s.palette.name}» · ${Settings.bubbleStyles[s.bubbleStyle].toLowerCase()} · фон: $wpName',
            style: W.small,
          ),
          trailing: Icon(Icons.chevron_right, color: W.muted),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppearanceScreen())),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in palettes)
                ChoiceChip(
                  label: Text(p.name),
                  selected: s.palette.id == p.id,
                  onSelected: (_) => s.palette = p,
                  avatar: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(color: p.bg, shape: BoxShape.circle, border: Border.all(color: p.border)),
                  ),
                ),
            ],
          ),
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

  @override
  Widget build(BuildContext context) {
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
              Icon(Icons.hd_outlined, color: W.muted),
              const SizedBox(width: 16),
              Expanded(child: Text('Качество камеры', style: W.body)),
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
        Padding(
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
          leading: Icon(Icons.cleaning_services_outlined, color: W.muted),
          title: Text('Очистить кэш', style: W.body),
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
    _scan();
    Api.I.refreshInfo();
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
      final kind = Vpn.kindOfUrl(url);
      toast(context, kind.isEmpty ? 'Этот адрес сейчас не отвечает' : 'Не отвечает. Включи $kind на этом устройстве и на сервере.');
      return;
    }
    await Api.I.switchTo(url);
    if (mounted) toast(context, 'Подключено: ${url.replaceFirst('http://', '')}');
  }

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final local = _local;
    final winter = local?.where((a) => a.kind == 'Winter VPN').toList() ?? const <VpnAddr>[];
    final others = local?.where((a) => a.kind != 'Winter VPN').toList() ?? const <VpnAddr>[];
    final urls = api.knownUrls;
    return _Section(
      icon: Icons.hub_outlined,
      title: 'СЕТЬ И WINTER VPN',
      children: [
        ListTile(
          leading: Icon(
            winter.isNotEmpty ? Icons.shield : Icons.shield_outlined,
            color: winter.isNotEmpty ? W.good : W.muted,
          ),
          title: Text(winter.isNotEmpty ? 'Winter VPN включён' : 'Winter VPN выключен', style: W.body),
          subtitle: Text(
            local == null
                ? 'Проверяю…'
                : winter.isNotEmpty
                    ? 'Твой адрес в сети: ${winter.first.ip}'
                    : 'Нужен, если сервер и ты в разных сетях (друг далеко, нет «белого» IP)',
            style: W.small,
          ),
          trailing: IconButton(tooltip: 'Обновить', icon: Icon(Icons.refresh, color: W.muted), onPressed: _scan),
        ),
        if (others.isNotEmpty)
          ListTile(
            leading: Icon(Icons.lan_outlined, color: W.muted),
            title: Text(others.map((a) => a.kind).toSet().join(', '), style: W.body),
            subtitle: Text(others.map((a) => a.ip).join(', '), style: W.small),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  final opened = await Vpn.open();
                  if (!opened && context.mounted) {
                    toast(context, 'Winter VPN не установлен — открыл страницу загрузки (или поставь его через Winter Hub)');
                  }
                },
                icon: const Icon(Icons.shield_outlined, size: 18),
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
                if (Vpn.kindOfUrl(u).isNotEmpty) 'через ${Vpn.kindOfUrl(u)}',
                if (u == api.serverUrl) 'сейчас используется',
              ].join(' · '),
              style: W.small,
            ),
            trailing: _checking == u
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : u == api.serverUrl
                    ? IconButton(
                        tooltip: 'Копировать',
                        icon: Icon(Icons.copy, size: 18, color: W.muted),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: u.replaceFirst('http://', '')));
                          toast(context, 'Скопировано');
                        },
                      )
                    : TextButton(onPressed: () => _connect(u), child: const Text('Подключиться')),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Text(
            'Если основной адрес не отвечает, приложение само переключится на адрес сервера в Winter VPN. '
            'Адреса в Winter VPN сервер сообщает сам — для этого Winter VPN должен быть включён и на компьютере-сервере.',
            style: W.small,
          ),
        ),
      ],
    );
  }
}

/// Подсказка про Winter VPN — на экране входа и когда нет связи с сервером.
class VpnHint extends StatefulWidget {
  const VpnHint({super.key, this.serverText});

  /// Адрес, который ввели на экране входа (чтобы понять, нужен ли VPN).
  final String? serverText;

  @override
  State<VpnHint> createState() => _VpnHintState();
}

class _VpnHintState extends State<VpnHint> {
  List<VpnAddr>? _local;

  @override
  void initState() {
    super.initState();
    Vpn.local().then((l) {
      if (mounted) setState(() => _local = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final on = _local?.any((a) => a.kind == 'Winter VPN') ?? false;
    final typed = widget.serverText ?? Api.I.serverUrl;
    final needs = Vpn.kindOfHost(Uri.tryParse(Api.normalizeUrl(typed))?.host ?? '');
    final text = switch ((needs, on)) {
      ('Winter VPN', false) => 'Этот адрес — в Winter VPN. Включи Winter VPN на этом устройстве, и всё заработает.',
      ('Winter VPN', true) => 'Winter VPN включён. Если не подключается — проверь, что Winter VPN включён и на компьютере-сервере.',
      ('Radmin VPN', _) => 'Это адрес Radmin VPN — проверь, что Radmin включён и вы в одной сети.',
      _ => 'Друг далеко или нет «белого» IP? Поставьте Winter VPN на телефон/ПК и на компьютер-сервер, '
          'а в адрес впиши адрес сервера в Winter VPN (100.x.x.x — он есть в панели сервера).',
    };
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
              Text(on ? 'Winter VPN включён' : 'Winter VPN', style: TextStyle(fontWeight: FontWeight.w700, color: W.text)),
            ],
          ),
          const SizedBox(height: 6),
          Text(text, style: W.small),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                final opened = await Vpn.open();
                if (!opened && context.mounted) toast(context, 'Открыл страницу загрузки Winter VPN');
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(on ? 'Открыть Winter VPN' : 'Включить Winter VPN'),
            ),
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
          leading: Icon(Icons.ac_unit, color: W.muted),
          title: Text('Winter Chat', style: W.body),
          subtitle: Text('Сборка $buildNumber', style: W.small),
        ),
      ],
    );
  }
}
