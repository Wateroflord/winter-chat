import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Фон переписки (выбирается в настройках → «Внешний вид»).
/// 0 — без фона, 1 — снегопад, 2 — северное сияние, 3 — глубина, 4 — звёзды.
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.style, required this.child});
  final int style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (style <= 0) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: ChatBackgroundPreview(style: style)),
        child,
      ],
    );
  }
}

/// Только картинка фона (для предпросмотра в настройках).
class ChatBackgroundPreview extends StatelessWidget {
  const ChatBackgroundPreview({super.key, required this.style});
  final int style;

  @override
  Widget build(BuildContext context) {
    final gradient = switch (style) {
      1 => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D1830), Color(0xFF0A1020)],
        ),
      2 => const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B2A2E), Color(0xFF0A1020), Color(0xFF221238)],
          stops: [0, 0.55, 1],
        ),
      3 => const RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.3,
          colors: [Color(0xFF14284A), Color(0xFF070C18)],
        ),
      4 => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF060A16), Color(0xFF0E1630)],
        ),
      _ => const LinearGradient(colors: [W.bg, W.bg]),
    };
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: style == 1 || style == 4 || style == 2 ? CustomPaint(painter: _DotsPainter(style)) : null,
    );
  }
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
