import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Фон переписки: без фона, готовый, свой градиент или своё фото.
class Wallpaper {
  const Wallpaper._(this.kind, {this.preset = 0, this.c1 = 0, this.c2 = 0, this.angle = 0, this.path = '', this.dim = 0.35, this.blur = 0, this.pattern = false});

  const Wallpaper.none() : this._(0);
  const Wallpaper.preset(int n) : this._(1, preset: n);
  const Wallpaper.gradient(int c1, int c2, {int angle = 0, bool pattern = false}) : this._(2, c1: c1, c2: c2, angle: angle, pattern: pattern);
  const Wallpaper.image(String path, {double dim = 0.35, double blur = 0}) : this._(3, path: path, dim: dim, blur: blur);

  /// 0 — нет, 1 — готовый, 2 — градиент, 3 — фото.
  final int kind;
  final int preset;
  final int c1, c2;

  /// Направление градиента: 0 — сверху вниз, 1 — по диагонали, 2 — слева направо, 3 — из центра.
  final int angle;
  final String path;

  /// Затемнение (0…0.85) и размытие (0…20) фото.
  final double dim, blur;

  /// Снежинки поверх градиента.
  final bool pattern;

  static const presets = ['Снегопад', 'Северное сияние', 'Глубина', 'Звёзды', 'Закат', 'Лаванда', 'Изумруд', 'Утро', 'Бумага'];
  static const angles = ['Сверху вниз', 'По диагонали', 'Слева направо', 'Из центра'];

  Wallpaper copyWith({int? c1, int? c2, int? angle, double? dim, double? blur, bool? pattern}) => Wallpaper._(
        kind,
        preset: preset,
        c1: c1 ?? this.c1,
        c2: c2 ?? this.c2,
        angle: angle ?? this.angle,
        path: path,
        dim: dim ?? this.dim,
        blur: blur ?? this.blur,
        pattern: pattern ?? this.pattern,
      );

  Map<String, dynamic> toJson() => {
        'k': kind,
        if (kind == 1) 'p': preset,
        if (kind == 2) ...{'c1': c1, 'c2': c2, 'a': angle, if (pattern) 'pt': true},
        if (kind == 3) ...{'path': path, 'dim': dim, 'blur': blur},
      };

  static Wallpaper fromJson(Map j) {
    int i(String k, [int d = 0]) => j[k] is num ? (j[k] as num).toInt() : d;
    double f(String k, double d) => j[k] is num ? (j[k] as num).toDouble() : d;
    return switch (i('k')) {
      1 => Wallpaper.preset(i('p', 1).clamp(1, presets.length)),
      2 => Wallpaper.gradient(i('c1'), i('c2'), angle: i('a').clamp(0, 3), pattern: j['pt'] == true),
      3 when j['path'] is String => Wallpaper.image(
          j['path'] as String,
          dim: f('dim', 0.35).clamp(0.0, 0.85).toDouble(),
          blur: f('blur', 0).clamp(0.0, 20.0).toDouble(),
        ),
      _ => const Wallpaper.none(),
    };
  }

  String encode() => jsonEncode(toJson());
  static Wallpaper? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      return j is Map ? fromJson(j) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is Wallpaper && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

/// Фон за перепиской.
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.wallpaper, required this.child});
  final Wallpaper wallpaper;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (wallpaper.kind == 0) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: WallpaperView(wallpaper: wallpaper)),
        child,
      ],
    );
  }
}

/// Только картинка фона (и для предпросмотра в настройках).
class WallpaperView extends StatelessWidget {
  const WallpaperView({super.key, required this.wallpaper, this.preview = false});
  final Wallpaper wallpaper;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final w = wallpaper;
    switch (w.kind) {
      case 1:
        return DecoratedBox(
          decoration: BoxDecoration(gradient: _presetGradient(w.preset)),
          child: _presetPattern(w.preset) == 0 ? null : CustomPaint(painter: _DotsPainter(_presetPattern(w.preset))),
        );
      case 2:
        final colors = [Color(w.c1), Color(w.c2)];
        final Gradient g = switch (w.angle) {
          1 => LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          2 => LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: colors),
          3 => RadialGradient(radius: 1.2, colors: colors),
          _ => LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors),
        };
        return DecoratedBox(
          decoration: BoxDecoration(gradient: g),
          child: w.pattern ? CustomPaint(painter: _DotsPainter(1)) : null,
        );
      case 3:
        final f = File(w.path);
        if (!f.existsSync()) return ColoredBox(color: W.bg);
        Widget img = Image.file(f, fit: BoxFit.cover, width: double.infinity, height: double.infinity, cacheWidth: preview ? 300 : null);
        if (w.blur > 0) {
          final b = preview ? w.blur / 3 : w.blur;
          img = ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b, tileMode: TileMode.mirror), child: img);
        }
        return Stack(fit: StackFit.expand, children: [
          ClipRect(child: img),
          if (w.dim > 0) ColoredBox(color: Colors.black.withValues(alpha: w.dim)),
        ]);
      default:
        return ColoredBox(color: W.bg);
    }
  }

  static Gradient _presetGradient(int n) => switch (n) {
        1 => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0D1830), Color(0xFF0A1020)]),
        2 => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B2A2E), Color(0xFF0A1020), Color(0xFF221238)],
            stops: [0, 0.55, 1],
          ),
        3 => const RadialGradient(center: Alignment(0, -0.6), radius: 1.3, colors: [Color(0xFF14284A), Color(0xFF070C18)]),
        4 => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF060A16), Color(0xFF0E1630)]),
        5 => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2A1033), Color(0xFF4A1A2E), Color(0xFF1A0E1E)],
            stops: [0, 0.5, 1],
          ),
        6 => const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1E1838), Color(0xFF2E2350)]),
        7 => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF06261E), Color(0xFF0A1A16)]),
        8 => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFDCEBFA), Color(0xFFF4E9F2)]),
        9 => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF3EDE2), Color(0xFFE9E1D3)]),
        _ => LinearGradient(colors: [W.bg, W.bg]),
      };

  /// Узор поверх готового фона: 1 — снег, 2 — сияние, 4 — звёзды.
  static int _presetPattern(int n) => switch (n) {
        1 => 1,
        2 => 2,
        4 => 4,
        5 => 4,
        7 => 2,
        _ => 0,
      };

  /// Похож ли фон на светлый (для подписей поверх него).
  static bool isLight(Wallpaper w) => switch (w.kind) {
        0 => W.light,
        1 => w.preset >= 8,
        2 => Color.lerp(Color(w.c1), Color(w.c2), 0.5)!.computeLuminance() > 0.45,
        3 => w.dim < 0.25 && W.light,
        _ => W.light,
      };
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.style);
  final int style;

  @override
  void paint(Canvas canvas, Size size) {
    if (style == 2) {
      // мягкие полосы сияния
      final p = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60);
      p.color = const Color(0xFF2FE0A0).withValues(alpha: 0.10);
      canvas.drawOval(Rect.fromLTWH(-size.width * 0.2, size.height * 0.05, size.width * 1.1, size.height * 0.22), p);
      p.color = const Color(0xFF8C5BFF).withValues(alpha: 0.10);
      canvas.drawOval(Rect.fromLTWH(size.width * 0.2, size.height * 0.25, size.width * 1.0, size.height * 0.2), p);
      return;
    }
    final rnd = Random(style * 7919);
    final count = (size.width * size.height / (style == 1 ? 5200 : 3800)).clamp(30, 420).toInt();
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      final r = style == 1 ? 0.8 + rnd.nextDouble() * 2.0 : 0.4 + rnd.nextDouble() * 1.1;
      final a = style == 1 ? 0.05 + rnd.nextDouble() * 0.12 : 0.15 + rnd.nextDouble() * 0.5;
      paint.color = Colors.white.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => old.style != style;
}
