import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';

Color colorFor(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return W.avatarColors[h % W.avatarColors.length];
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
}

/// Аватар пользователя: картинка или буквы на цветном круге.
class UserAvatar extends StatelessWidget {
  const UserAvatar(this.userId, {super.key, this.size = 40, this.ring = false});
  final String userId;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final url = api.avatarUrl(userId);
    final name = api.nameOf(userId);
    return LetterAvatar(name: name, seed: userId, size: size, imageUrl: url?.toString(), ring: ring);
  }
}

class LetterAvatar extends StatelessWidget {
  const LetterAvatar({
    super.key,
    required this.name,
    required this.seed,
    this.size = 40,
    this.imageUrl,
    this.icon,
    this.ring = false,
  });
  final String name;
  final String seed;
  final double size;
  final String? imageUrl;
  final IconData? icon;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final c = colorFor(seed);
    final letters = Center(
      child: icon != null
          ? Icon(icon, size: size * 0.5, color: W.bg)
          : Text(
              initials(name),
              style: TextStyle(color: W.bg, fontWeight: FontWeight.w800, fontSize: size * 0.38),
            ),
    );
    Widget inner = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c, Color.lerp(c, W.bg, 0.35)!],
        ),
      ),
      child: imageUrl == null
          ? letters
          : ClipOval(
              child: Image.network(
                imageUrl!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => letters,
              ),
            ),
    );
    if (ring) {
      inner = Container(
        padding: const EdgeInsets.all(2.5),
        decoration: const BoxDecoration(shape: BoxShape.circle, color: W.good),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(shape: BoxShape.circle, color: W.bg),
          child: inner,
        ),
      );
    }
    return inner;
  }
}
