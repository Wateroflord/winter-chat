import 'dart:io';

import 'package:flutter/material.dart';

import '../settings.dart';
import '../sounds.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/chat_background.dart';
import '../widgets/color_picker.dart';
import 'profile_sheet.dart';

/// Настройки → Оформление: тема, цвета, сообщения, фон, аватары, звуки.
class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});

  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  final s = Settings.I;

  @override
  void initState() {
    super.initState();
    s.addListener(_changed);
  }

  @override
  void dispose() {
    s.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Оформление'),
        actions: [
          TextButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Вернуть как было?'),
                  content: const Text('Тема, цвета, сообщения и фон станут стандартными. Настройки отдельных чатов останутся.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сбросить')),
                  ],
                ),
              );
              if (ok == true) await s.resetAppearance();
            },
            child: const Text('Сбросить'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Живой предпросмотр сверху.
          SizedBox(height: 210, child: _Preview(key: ValueKey(s.themeKey))),
          Divider(height: 1, color: W.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _Header('ТЕМА'),
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: palettes.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _PaletteTile(palettes[i], selected: s.palette.id == palettes[i].id, onTap: () => s.palette = palettes[i]),
                  ),
                ),
                _Header('АКЦЕНТ'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final a in Settings.accents)
                        _Swatch(
                          color: a.$2,
                          tooltip: a.$1,
                          selected: s.accent.toARGB32() == a.$2.toARGB32(),
                          onTap: () => s.accent = a.$2,
                        ),
                      _Swatch(
                        color: Settings.accents.any((a) => a.$2.toARGB32() == s.accent.toARGB32()) ? null : s.accent,
                        tooltip: 'Свой цвет',
                        custom: true,
                        selected: !Settings.accents.any((a) => a.$2.toARGB32() == s.accent.toARGB32()),
                        onTap: () async {
                          final c = await pickColor(context, initial: s.accent, title: 'Цвет акцента');
                          if (c != null) s.accent = c;
                        },
                      ),
                    ],
                  ),
                ),
                _Header('СООБЩЕНИЯ'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: [
                      for (var i = 0; i < Settings.bubbleStyles.length; i++) ButtonSegment(value: i, label: Text(Settings.bubbleStyles[i], style: const TextStyle(fontSize: 12.5))),
                    ],
                    selected: {s.bubbleStyle},
                    onSelectionChanged: (v) => s.bubbleStyle = v.first,
                  ),
                ),
                if (s.bubbleStyle <= 1)
                  _SliderRow(
                    icon: Icons.rounded_corner,
                    title: 'Скругление',
                    value: s.bubbleRadius,
                    min: 6,
                    max: 26,
                    label: '${s.bubbleRadius.round()}',
                    onChanged: (v) => s.bubbleRadius = v,
                  ),
                if (s.bubbleStyle != 3) ...[
                  _ColorRow(
                    title: 'Мои сообщения',
                    subtitle: s.myBubbleColor == null ? 'Из акцента' : colorToHex(s.myBubbleColor!),
                    color: s.myBubble,
                    onPick: () async {
                      final c = await pickColor(context, initial: s.myBubble, title: 'Мои сообщения');
                      if (c != null) s.myBubbleColor = c;
                    },
                    onReset: s.myBubbleColor == null ? null : () => s.myBubbleColor = null,
                  ),
                  _ColorRow(
                    title: 'Сообщения друзей',
                    subtitle: s.otherBubbleColor == null ? 'Из темы' : colorToHex(s.otherBubbleColor!),
                    color: s.otherBubble,
                    onPick: () async {
                      final c = await pickColor(context, initial: s.otherBubble, title: 'Сообщения друзей');
                      if (c != null) s.otherBubbleColor = c;
                    },
                    onReset: s.otherBubbleColor == null ? null : () => s.otherBubbleColor = null,
                  ),
                  _SwitchRow(
                    icon: Icons.gradient,
                    title: 'Градиент на моих сообщениях',
                    value: s.myBubbleGradient,
                    onChanged: (v) => s.myBubbleGradient = v,
                  ),
                  _SwitchRow(
                    icon: Icons.account_circle_outlined,
                    title: 'Аватары в группах',
                    value: s.showAvatars,
                    onChanged: (v) => s.showAvatars = v,
                  ),
                ],
                _SwitchRow(
                  icon: Icons.emoji_emotions_outlined,
                  title: 'Большие эмодзи',
                  subtitle: 'Сообщение из 1–3 эмодзи — крупно',
                  value: s.bigEmoji,
                  onChanged: (v) => s.bigEmoji = v,
                ),
                _SwitchRow(
                  icon: Icons.density_small,
                  title: 'Компактные сообщения',
                  subtitle: 'Меньше отступов — больше сообщений на экране',
                  value: s.compact,
                  onChanged: (v) => s.compact = v,
                ),
                _Header('ФОН ЧАТА'),
                SizedBox(height: 112, child: WallpaperPicker(selected: s.wallpaper, onPick: (w) => s.wallpaper = w)),
                if (s.wallpaper.kind == 2) _GradientEditor(wp: s.wallpaper, onChanged: (w) => s.wallpaper = w),
                if (s.wallpaper.kind == 3) ...[
                  _SliderRow(
                    icon: Icons.brightness_4_outlined,
                    title: 'Затемнение',
                    value: s.wallpaper.dim,
                    min: 0,
                    max: 0.85,
                    label: '${(s.wallpaper.dim * 100).round()}%',
                    onChanged: (v) => s.wallpaper = s.wallpaper.copyWith(dim: v),
                  ),
                  _SliderRow(
                    icon: Icons.blur_on,
                    title: 'Размытие',
                    value: s.wallpaper.blur,
                    min: 0,
                    max: 20,
                    label: s.wallpaper.blur.round().toString(),
                    onChanged: (v) => s.wallpaper = s.wallpaper.copyWith(blur: v),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text('Свой фон для отдельного чата: в чате ⋮ → «Оформление и настройки чата».', style: W.small),
                ),
                _Header('АВАТАРЫ И СПИСОК'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, icon: Icon(Icons.circle_outlined), label: Text('Круглые')),
                      ButtonSegment(value: true, icon: Icon(Icons.crop_square), label: Text('Квадратные')),
                    ],
                    selected: {s.squareAvatars},
                    onSelectionChanged: (v) => s.squareAvatars = v.first,
                  ),
                ),
                _SwitchRow(
                  icon: Icons.short_text,
                  title: 'Последнее сообщение в списке чатов',
                  subtitle: 'Выключи — вместо него будет статус друга',
                  value: s.chatPreview,
                  onChanged: (v) => s.chatPreview = v,
                ),
                _Header('ТЕКСТ'),
                _SliderRow(
                  icon: Icons.format_size,
                  title: 'Размер текста',
                  value: Settings.textScales.indexWhere((v) => (v - s.textScale).abs() < 0.01).clamp(0, Settings.textScales.length - 1).toDouble(),
                  min: 0,
                  max: (Settings.textScales.length - 1).toDouble(),
                  divisions: Settings.textScales.length - 1,
                  label: '${(s.textScale * 100).round()}%',
                  onChanged: (v) => s.textScale = Settings.textScales[v.round()],
                ),
                if (desktop)
                  _SwitchRow(
                    icon: Icons.keyboard_return,
                    title: 'Enter — отправить',
                    subtitle: s.enterSends ? 'Новая строка — Shift+Enter' : 'Отправить — Ctrl+Enter, Enter — новая строка',
                    value: s.enterSends,
                    onChanged: (v) => s.enterSends = v,
                  ),
                _Header('ЗВУКИ'),
                _SoundRow(
                  icon: Icons.notifications_active_outlined,
                  title: 'Звук сообщения',
                  names: Sounds.messageSounds,
                  value: s.messageSound,
                  onChanged: (v) {
                    s.messageSound = v;
                    Sounds.play(v);
                  },
                ),
                _SoundRow(
                  icon: Icons.ring_volume_outlined,
                  title: 'Мелодия звонка',
                  names: Sounds.ringSounds,
                  value: s.ringTone,
                  onChanged: (v) {
                    s.ringTone = v;
                    Sounds.previewRing(v);
                  },
                ),
                _Header('ПРОФИЛЬ'),
                ListTile(
                  leading: Icon(Icons.badge_outlined, color: W.muted),
                  title: Text('Статус, «о себе», цвет и баннер', style: W.body),
                  subtitle: Text('Это видят все друзья', style: W.small),
                  trailing: Icon(Icons.chevron_right, color: W.muted),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileEditScreen())),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: W.muted)),
      );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.icon, required this.title, required this.value, required this.onChanged, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        secondary: Icon(icon, color: W.muted),
        title: Text(title, style: W.body),
        subtitle: subtitle == null ? null : Text(subtitle!, style: W.small),
        value: value,
        onChanged: onChanged,
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    this.divisions,
  });
  final IconData icon;
  final String title, label;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(
          children: [
            Icon(icon, color: W.muted),
            const SizedBox(width: 16),
            SizedBox(width: 110, child: Text(title, style: W.body)),
            Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged)),
            SizedBox(width: 44, child: Text(label, style: W.small, textAlign: TextAlign.right)),
          ],
        ),
      );
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.title, required this.subtitle, required this.color, required this.onPick, this.onReset});
  final String title, subtitle;
  final Color color;
  final VoidCallback onPick;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(Icons.format_color_fill, color: W.muted),
        title: Text(title, style: W.body),
        subtitle: Text(subtitle, style: W.small),
        onTap: onPick,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onReset != null) TextButton(onPressed: onReset, child: const Text('Авто')),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9), border: Border.all(color: W.border)),
            ),
          ],
        ),
      );
}

class _SoundRow extends StatelessWidget {
  const _SoundRow({required this.icon, required this.title, required this.names, required this.value, required this.onChanged});
  final IconData icon;
  final String title;
  final List<String> names;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Icon(icon, color: W.muted), const SizedBox(width: 16), Text(title, style: W.body)]),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < names.length; i++)
                  ChoiceChip(
                    label: Text(names[i]),
                    selected: value == i,
                    onSelected: (_) => onChanged(i),
                    avatar: value == i ? null : const Icon(Icons.play_arrow, size: 16),
                  ),
              ],
            ),
          ],
        ),
      );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.tooltip, required this.selected, required this.onTap, this.custom = false});
  final Color? color;
  final String tooltip;
  final bool selected, custom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              gradient: color == null ? const SweepGradient(colors: [Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red]) : null,
              border: Border.all(color: selected ? W.text : Colors.transparent, width: 3),
            ),
            child: custom
                ? Icon(Icons.colorize, color: color == null ? Colors.white : onColor(color!), size: 18)
                : (selected ? Icon(Icons.check, color: onColor(color!), size: 20) : null),
          ),
        ),
      );
}

class _PaletteTile extends StatelessWidget {
  const _PaletteTile(this.p, {required this.selected, required this.onTap});
  final Palette p;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 74,
              height: 66,
              decoration: BoxDecoration(
                color: p.bg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: selected ? W.ice : W.border, width: selected ? 2.5 : 1),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 10, width: 44, decoration: BoxDecoration(color: p.surface2, borderRadius: BorderRadius.circular(5))),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(height: 10, width: 36, decoration: BoxDecoration(color: W.ice, borderRadius: BorderRadius.circular(5))),
                  ),
                  const Spacer(),
                  Container(height: 6, width: 30, decoration: BoxDecoration(color: p.muted, borderRadius: BorderRadius.circular(3))),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(p.name, style: TextStyle(fontSize: 11.5, color: selected ? W.text : W.muted)),
          ],
        ),
      );
}

/// Выбор фона: нет, готовые, свой градиент, своё фото.
class WallpaperPicker extends StatelessWidget {
  const WallpaperPicker({super.key, required this.selected, required this.onPick});
  final Wallpaper? selected;
  final ValueChanged<Wallpaper> onPick;

  @override
  Widget build(BuildContext context) {
    final items = <(String, Wallpaper)>[
      ('Без фона', const Wallpaper.none()),
      for (var i = 1; i <= Wallpaper.presets.length; i++) (Wallpaper.presets[i - 1], Wallpaper.preset(i)),
    ];
    final sel = selected;
    final gradientSelected = sel?.kind == 2;
    final imageSelected = sel?.kind == 3;
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        for (final (name, w) in items) _tile(context, name, WallpaperView(wallpaper: w, preview: true), sel == w, () => onPick(w)),
        _tile(
          context,
          'Градиент',
          gradientSelected
              ? WallpaperView(wallpaper: sel!, preview: true)
              : const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF5B9DFF), Color(0xFFFF78AA)]))),
          gradientSelected,
          () {
            if (!gradientSelected) onPick(Wallpaper.gradient(const Color(0xFF1B2A4A).toARGB32(), const Color(0xFF3A1F4A).toARGB32(), angle: 1));
          },
        ),
        _tile(
          context,
          'Своё фото',
          imageSelected ? WallpaperView(wallpaper: sel!, preview: true) : ColoredBox(color: W.surface2, child: Icon(Icons.add_photo_alternate_outlined, color: W.muted)),
          imageSelected,
          () async {
            final path = await importWallpaperImage();
            if (path != null) onPick(Wallpaper.image(path));
          },
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, String name, Widget preview, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Column(
            children: [
              Container(
                width: 68,
                height: 80,
                decoration: BoxDecoration(
                  color: W.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? W.ice : W.border, width: selected ? 2.5 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: preview,
              ),
              const SizedBox(height: 5),
              SizedBox(
                width: 72,
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: W.muted)),
              ),
            ],
          ),
        ),
      );
}

class _GradientEditor extends StatelessWidget {
  const _GradientEditor({required this.wp, required this.onChanged});
  final Wallpaper wp;
  final ValueChanged<Wallpaper> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _colorButton(context, 'Цвет 1', Color(wp.c1), (c) => onChanged(wp.copyWith(c1: c.toARGB32()))),
                const SizedBox(width: 10),
                _colorButton(context, 'Цвет 2', Color(wp.c2), (c) => onChanged(wp.copyWith(c2: c.toARGB32()))),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Поменять местами',
                  onPressed: () => onChanged(wp.copyWith(c1: wp.c2, c2: wp.c1)),
                  icon: const Icon(Icons.swap_horiz),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < Wallpaper.angles.length; i++)
                  ChoiceChip(label: Text(Wallpaper.angles[i]), selected: wp.angle == i, onSelected: (_) => onChanged(wp.copyWith(angle: i))),
                FilterChip(label: const Text('Снежинки'), selected: wp.pattern, onSelected: (v) => onChanged(wp.copyWith(pattern: v))),
              ],
            ),
          ],
        ),
      );

  Widget _colorButton(BuildContext context, String label, Color c, ValueChanged<Color> set) => Expanded(
        child: OutlinedButton.icon(
          onPressed: () async {
            final v = await pickColor(context, initial: c, title: label);
            if (v != null) set(v);
          },
          icon: Container(width: 18, height: 18, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: W.border))),
          label: Text(label),
        ),
      );
}

/// Предпросмотр переписки с текущими настройками.
class _Preview extends StatelessWidget {
  const _Preview({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Settings.I;
    final list = s.bubbleStyle == 3;
    Widget bubble(String text, bool mine, String time, {String? name, Color? nameColor}) {
      final bg = list ? Colors.transparent : (mine ? s.myBubble : s.otherBubble);
      final fg = list ? W.text : onColor(bg);
      final r = s.bubbleStyle == 2 ? 4.0 : s.bubbleRadius;
      final tail = s.bubbleStyle == 0 ? (r * 0.3).clamp(3.0, 6.0) : r;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name != null) Text(name, style: TextStyle(fontSize: list ? 14 : 12.5, fontWeight: FontWeight.w700, color: nameColor)),
          Text(text, style: TextStyle(color: fg, fontSize: 14 * s.textScale)),
          if (!list) Align(alignment: Alignment.centerRight, child: Text(time, style: TextStyle(fontSize: 10.5, color: fg.withValues(alpha: 0.6)))),
        ],
      );
      final b = list
          ? content
          : Container(
              constraints: const BoxConstraints(maxWidth: 240),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
              decoration: BoxDecoration(
                color: mine && s.myBubbleGradient ? null : bg,
                gradient: mine && s.myBubbleGradient
                    ? LinearGradient(colors: [Color.lerp(bg, Colors.white, 0.12)!, Color.lerp(bg, Colors.black, 0.18)!])
                    : null,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(r),
                  topRight: Radius.circular(r),
                  bottomLeft: Radius.circular(mine ? r : tail),
                  bottomRight: Radius.circular(mine ? tail : r),
                ),
                border: W.light && !mine && s.otherBubbleColor == null ? Border.all(color: W.border) : null,
              ),
              child: content,
            );
      final avatar = Container(
        width: list ? 32 : 26,
        height: list ? 32 : 26,
        decoration: ShapeDecoration(
          shape: s.squareAvatars ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)) : const CircleBorder(),
          color: mine ? W.ice : const Color(0xFFFF78AA),
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisAlignment: mine && !list ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: list ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            if (!mine || list) ...[avatar, const SizedBox(width: 8)],
            Flexible(child: b),
          ],
        ),
      );
    }

    return ChatBackground(
      wallpaper: s.wallpaper,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            bubble('Го в доту вечером? 🎮', false, '18:02', name: list || s.showAvatars ? 'Вова' : null, nameColor: const Color(0xFFFF78AA)),
            bubble('Давай, после смены', true, '18:03', name: list ? 'Ты' : null, nameColor: W.ice),
            Align(alignment: list ? Alignment.centerLeft : Alignment.centerRight, child: Padding(padding: EdgeInsets.only(left: list ? 40 : 0), child: Text(s.bigEmoji ? '🔥' : '🔥 ', style: TextStyle(fontSize: s.bigEmoji ? 30 : 14)))),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
