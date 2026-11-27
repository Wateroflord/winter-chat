import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../settings.dart';
import '../theme.dart';

/// Цвет человека: свой из профиля или постоянный по id.
Color colorFor(String id) {
  final own = Api.I.profileColor(id);
  if (own != null) return own;
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return W.avatarColors[h % W.avatarColors.length];
}

/// Цвет имени в переписке: на светлой теме чуть темнее, чтобы читалось.
Color nameColorFor(String id) {
  final c = colorFor(id);
  return W.light && c.computeLuminance() > 0.45 ? Color.lerp(c, Colors.black, 0.35)! : c;
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
}

/// Форма аватара (Настройки → Оформление): круг или скруглённый квадрат.
ShapeBorder avatarShape(double size) =>
    Settings.I.squareAvatars ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(size * 0.28)) : const CircleBorder();

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

/// Аватар чата: фото группы, иначе значок группы; личный чат — аватар собеседника.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar(this.chat, {super.key, this.size = 40});
  final RecordModel chat;
  final double size;

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    if (!chat.getBoolValue('is_group')) return UserAvatar(api.otherMember(chat) ?? api.myId, size: size);
    final title = api.chatTitle(chat);
    return LetterAvatar(name: title, seed: chat.id, size: size, icon: Icons.group, imageUrl: api.chatAvatarUrl(chat)?.toString());
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
    final fg = onColor(c);
    final letters = Center(
      child: icon != null
          ? Icon(icon, size: size * 0.5, color: fg)
          : Text(
              initials(name),
              style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: size * 0.38),
            ),
    );
    final shape = avatarShape(size);
    Widget inner = Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        shape: shape,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c, Color.lerp(c, Colors.black, 0.25)!],
        ),
      ),
      child: imageUrl == null
          ? letters
          : ClipPath(
              clipper: ShapeBorderClipper(shape: shape),
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
        decoration: ShapeDecoration(shape: avatarShape(size + 9), color: W.good),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: ShapeDecoration(shape: avatarShape(size + 4), color: W.bg),
          child: inner,
        ),
      );
    }
    return inner;
  }
}
