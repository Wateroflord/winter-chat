import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../settings.dart';
import '../theme.dart';
import '../util.dart';

/// Форматирование сообщений:
/// **жирный**, *курсив* или _курсив_, ~~зачёркнутый~~, ||спойлер||, `код`, ```блок кода```,
/// ссылки и упоминания @ник / @все.

const fBold = 1, fItalic = 2, fStrike = 4, fCode = 8, fSpoiler = 16, fBlock = 32;

class RichSeg {
  const RichSeg(this.text, this.flags, {this.url, this.mention, this.spoiler = 0});
  final String text;
  final int flags;
  final String? url;

  /// Ник без «@» (в нижнем регистре) или «all» для @все.
  final String? mention;

  /// Номер спойлера (0 — не спойлер).
  final int spoiler;

  bool has(int f) => flags & f != 0;

  @override
  String toString() => 'RichSeg($text, $flags${url != null ? ', url' : ''}${mention != null ? ', @$mention' : ''}${spoiler > 0 ? ', sp$spoiler' : ''})';
}

final _blockRe = RegExp(r'```(?:[a-zA-Z0-9_+\-]*\n)?([\s\S]*?)```');
final _patterns = <(RegExp, int)>[
  (RegExp(r'`([^`\n]+)`'), fCode),
  (RegExp(r'\|\|([\s\S]+?)\|\|'), fSpoiler),
  (RegExp(r'\*\*([\s\S]+?)\*\*'), fBold),
  (RegExp(r'~~([\s\S]+?)~~'), fStrike),
  (RegExp(r'(?<![\p{L}\p{N}_])_(?![\s_])([^_\n]+?)(?<![\s_])_(?![\p{L}\p{N}_])', unicode: true), fItalic),
  (RegExp(r'(?<![\p{L}\p{N}*])\*(?![\s*])([^*\n]+?)(?<![\s*])\*(?![\p{L}\p{N}*])', unicode: true), fItalic),
];
final mentionRegex = RegExp(r'(?<![\p{L}\p{N}_@/])@([\p{L}\p{N}_.\-]{2,32})', unicode: true);
const allMentions = {'все', 'всем', 'all', 'everyone', 'here', 'тут'};

class _Ctx {
  int spoilers = 0;
}

/// Разобрать текст сообщения на кусочки с оформлением.
List<RichSeg> parseRich(String text) {
  final out = <RichSeg>[];
  final ctx = _Ctx();
  var last = 0;
  for (final m in _blockRe.allMatches(text)) {
    if (m.start > last) _inline(text.substring(last, m.start), 0, 0, out, ctx);
    var code = m.group(1)!;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    if (code.isNotEmpty) out.add(RichSeg(code, fBlock | fCode));
    last = m.end;
  }
  if (last < text.length) _inline(text.substring(last), 0, 0, out, ctx);
  return out;
}

void _inline(String s, int flags, int spoiler, List<RichSeg> out, _Ctx ctx) {
  if (s.isEmpty) return;
  if (flags & fCode != 0) {
    out.add(RichSeg(s, flags, spoiler: spoiler));
    return;
  }
  final urls = [for (final m in urlRegex.allMatches(s)) (m.start, m.end)];
  bool inUrl(int i) => urls.any((u) => i >= u.$1 && i < u.$2);
  RegExpMatch? best;
  var bestFlag = 0;
  for (final (re, f) in _patterns) {
    if (flags & f != 0 && f != fItalic) continue; // **внутри** жирного ещё раз жирный не нужен
    for (final m in re.allMatches(s)) {
      if (inUrl(m.start) || inUrl(m.end - 1)) continue;
      if (best == null || m.start < best.start) {
        best = m;
        bestFlag = f;
      }
      break;
    }
  }
  if (best == null) {
    _leaf(s, flags, spoiler, out);
    return;
  }
  _leaf(s.substring(0, best.start), flags, spoiler, out);
  var sp = spoiler;
  if (bestFlag == fSpoiler) sp = ++ctx.spoilers;
  _inline(best.group(1)!, flags | bestFlag, sp, out, ctx);
  _inline(s.substring(best.end), flags, spoiler, out, ctx);
}

void _leaf(String s, int flags, int spoiler, List<RichSeg> out) {
  if (s.isEmpty) return;
  final hits = <(int, int, String?, String?)>[]; // start, end, url, mention
  for (final m in urlRegex.allMatches(s)) {
    var url = m.group(0)!;
    // Точка или скобка в конце обычно не часть ссылки.
    while (url.isNotEmpty && '.,;:!?)]}»…'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.length > 8) hits.add((m.start, m.start + url.length, url, null));
  }
  for (final m in mentionRegex.allMatches(s)) {
    if (hits.any((h) => m.start < h.$2 && m.end > h.$1)) continue;
    var name = m.group(1)!;
    while (name.isNotEmpty && '.-'.contains(name[name.length - 1])) {
      name = name.substring(0, name.length - 1);
    }
    if (name.length < 2) continue;
    final low = name.toLowerCase();
    hits.add((m.start, m.start + 1 + name.length, null, allMentions.contains(low) ? 'all' : low));
  }
  hits.sort((a, b) => a.$1.compareTo(b.$1));
  var last = 0;
  for (final h in hits) {
    if (h.$1 > last) out.add(RichSeg(s.substring(last, h.$1), flags, spoiler: spoiler));
    out.add(RichSeg(s.substring(h.$1, h.$2), flags, url: h.$3, mention: h.$4, spoiler: spoiler));
    last = h.$2;
  }
  if (last < s.length) out.add(RichSeg(s.substring(last), flags, spoiler: spoiler));
}

/// Текст без значков оформления (для уведомлений, списка чатов и поиска).
String richPlain(String text, {bool hideSpoilers = true}) {
  final b = StringBuffer();
  var lastSpoiler = 0;
  for (final s in parseRich(text)) {
    if (hideSpoilers && s.spoiler > 0) {
      if (s.spoiler != lastSpoiler) b.write('▒▒▒');
      lastSpoiler = s.spoiler;
      continue;
    }
    lastSpoiler = 0;
    b.write(s.text);
  }
  return b.toString();
}

/// Кого зовут в тексте: ники в нижнем регистре и «all».
Set<String> mentionsIn(String text) => {
      for (final s in parseRich(text))
        if (s.mention != null && !s.has(fCode)) s.mention!,
    };

/// Зовут ли меня (по нику или через @все).
bool mentionsMe(String text) {
  if (!Api.I.loggedIn) return false;
  final m = mentionsIn(text);
  if (m.isEmpty) return false;
  return m.contains('all') || m.contains(Api.I.me.getStringValue('username').toLowerCase());
}

/// Найти человека по нику (из уже загруженных).
String? userIdByUsername(String username) {
  final low = username.toLowerCase();
  for (final u in Api.I.users.values) {
    if (u.getStringValue('username').toLowerCase() == low) return u.id;
  }
  return null;
}

/// Текст сообщения с оформлением, ссылками, упоминаниями и спойлерами.
class RichMessageText extends StatefulWidget {
  const RichMessageText(this.text, {super.key, this.color, this.onLink, this.onMention});
  final String text;
  final Color? color;
  final void Function(String url)? onLink;
  final void Function(String userId)? onMention;

  @override
  State<RichMessageText> createState() => _RichMessageTextState();
}

class _RichMessageTextState extends State<RichMessageText> {
  final Set<int> _shown = {};
  final List<TapGestureRecognizer> _taps = [];
  List<RichSeg>? _segs;
  String? _parsedFor;

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback f) {
    final t = TapGestureRecognizer()..onTap = f;
    _taps.add(t);
    return t;
  }

  @override
  Widget build(BuildContext context) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    if (_parsedFor != widget.text) {
      _segs = parseRich(widget.text);
      _parsedFor = widget.text;
    }
    final segs = _segs!;
    final text = widget.text;
    final fg = widget.color ?? W.text;
    final accent = widget.color == null || widget.color == W.text ? W.ice : fg;
    final big = Settings.I.bigEmoji && text.runes.length <= 3 && !RegExp(r'[a-zA-Zа-яА-Я0-9]').hasMatch(text);
    final me = Api.I.loggedIn ? Api.I.me.getStringValue('username').toLowerCase() : '';
    const mono = 'monospace';
    const monoFallback = ['Consolas', 'Menlo', 'DejaVu Sans Mono', 'Roboto Mono', 'monospace'];

    final spans = <InlineSpan>[];
    for (final s in segs) {
      if (s.has(fBlock)) {
        spans.add(WidgetSpan(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            decoration: BoxDecoration(color: fg.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(8), border: Border.all(color: fg.withValues(alpha: 0.12))),
            child: SelectableText(s.text, style: TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 13, color: fg, height: 1.35)),
          ),
        ));
        continue;
      }
      final hidden = s.spoiler > 0 && !_shown.contains(s.spoiler);
      var style = TextStyle(
        fontWeight: s.has(fBold) ? FontWeight.w700 : null,
        fontStyle: s.has(fItalic) ? FontStyle.italic : null,
        decoration: s.has(fStrike) ? TextDecoration.lineThrough : null,
        decorationColor: fg,
      );
      if (s.has(fCode)) {
        style = style.copyWith(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 13.5, backgroundColor: fg.withValues(alpha: 0.10));
      }
      GestureRecognizer? rec;
      if (s.url != null && !hidden) {
        style = style.copyWith(color: accent, decoration: TextDecoration.underline, decorationColor: accent);
        final url = s.url!;
        rec = _tap(() => widget.onLink?.call(url));
      } else if (s.mention != null && !hidden) {
        final mine = s.mention == 'all' || s.mention == me;
        style = style.copyWith(
          color: accent,
          fontWeight: FontWeight.w700,
          backgroundColor: mine ? accent.withValues(alpha: 0.16) : null,
        );
        final id = s.mention == 'all' ? null : userIdByUsername(s.mention!);
        if (id != null) rec = _tap(() => widget.onMention?.call(id));
      }
      if (hidden) {
        final n = s.spoiler;
        style = style.copyWith(color: Colors.transparent, backgroundColor: fg.withValues(alpha: 0.55), decoration: TextDecoration.none);
        rec = _tap(() => setState(() => _shown.add(n)));
      }
      spans.add(TextSpan(text: s.text, style: style, recognizer: rec));
    }
    return Text.rich(
      TextSpan(children: spans),
      style: big ? const TextStyle(fontSize: 34) : W.body.copyWith(color: widget.color),
    );
  }
}

/// Обернуть выделенный текст значками оформления (для меню выделения и Ctrl+B / Ctrl+I).
void wrapSelection(TextEditingController c, String left, [String? right]) {
  right ??= left;
  final sel = c.selection;
  final text = c.text;
  if (!sel.isValid) return;
  final start = sel.start, end = sel.end;
  final inner = text.substring(start, end);
  final next = text.replaceRange(start, end, '$left$inner$right');
  c.value = TextEditingValue(
    text: next,
    selection: inner.isEmpty
        ? TextSelection.collapsed(offset: start + left.length)
        : TextSelection(baseOffset: start + left.length, extentOffset: start + left.length + inner.length),
  );
}
