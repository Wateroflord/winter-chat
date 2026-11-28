import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../theme.dart';
import 'sticker_panel.dart';

/// Опросы, превью ссылок, стикеры, GIF, «переслано» и «напоминание» внутри сообщения.

Map<String, dynamic>? jsonMapOf(RecordModel m, String key) {
  final v = m.data[key];
  return v is Map ? Map<String, dynamic>.from(v) : null;
}

// ---------- опрос ----------

class PollCard extends StatefulWidget {
  const PollCard({super.key, required this.message, required this.fg});
  final RecordModel message;
  final Color fg;

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  List<int>? _mine; // мой голос, пока сервер не подтвердил
  String _forUpdated = '';
  bool _busy = false;

  Map<String, List<int>> get _votes {
    final v = widget.message.data['votes'];
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.value is List) '${e.key}': [for (final x in e.value as List) if (x is num) x.toInt()],
    };
  }

  Future<void> _tap(int i, bool multi) async {
    if (_busy) return;
    final current = List<int>.from(_mine ?? _votes[Api.I.myId] ?? const []);
    List<int> next;
    if (multi) {
      next = current.contains(i) ? (current..remove(i)) : [...current, i];
    } else {
      if (current.length == 1 && current.first == i) return;
      next = [i];
    }
    await _send(next);
  }

  Future<void> _send(List<int> next) async {
    setState(() {
      _mine = next;
      _busy = true;
    });
    try {
      await Api.I.vote(widget.message.id, next);
    } catch (e) {
      if (mounted) {
        toast(context, '$e');
        setState(() => _mine = null);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _showVoters(List<String> opts, Map<String, List<int>> votes) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(14),
          children: [
            for (var i = 0; i < opts.length; i++) ...[
              Text(opts[i], style: W.body.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                [for (final e in votes.entries) if (e.value.contains(i)) Api.I.nameOf(e.key)].join(', ').ifEmpty('— никто'),
                style: W.small,
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final poll = jsonMapOf(widget.message, 'poll') ?? const {};
    final q = '${poll['q'] ?? ''}';
    final opts = [for (final o in (poll['o'] as List? ?? const [])) '$o'];
    final multi = poll['m'] == true;
    final updated = widget.message.getStringValue('updated');
    if (updated != _forUpdated) {
      _forUpdated = updated;
      _mine = null; // сервер прислал свежие голоса
    }
    final votes = Map<String, List<int>>.from(_votes);
    if (_mine != null) {
      if (_mine!.isEmpty) {
        votes.remove(Api.I.myId);
      } else {
        votes[Api.I.myId] = _mine!;
      }
    }
    final voters = votes.length;
    final mine = votes[Api.I.myId] ?? const <int>[];
    final fg = widget.fg;
    final counts = [for (var i = 0; i < opts.length; i++) votes.values.where((v) => v.contains(i)).length];
    final top = counts.isEmpty ? 0 : counts.reduce((a, b) => a > b ? a : b);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(multi ? '📊 Опрос · можно несколько' : '📊 Опрос', style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.7), fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(q, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: fg)),
          const SizedBox(height: 8),
          for (var i = 0; i < opts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _tap(i, multi),
                  child: Container(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: fg.withValues(alpha: mine.contains(i) ? 0.7 : 0.22))),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: voters == 0 ? 0 : counts[i] / voters,
                            child: Container(color: fg.withValues(alpha: counts[i] == top && top > 0 ? 0.22 : 0.12)),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: Row(
                            children: [
                              Icon(
                                multi
                                    ? (mine.contains(i) ? Icons.check_box : Icons.check_box_outline_blank)
                                    : (mine.contains(i) ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                                size: 18,
                                color: fg.withValues(alpha: mine.contains(i) ? 1 : 0.6),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(opts[i], style: TextStyle(color: fg, fontSize: 14))),
                              if (voters > 0)
                                Text('${(counts[i] * 100 / voters).round()}% · ${counts[i]}', style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Row(
            children: [
              InkWell(
                onTap: voters == 0 ? null : () => _showVoters(opts, votes),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(voters == 0 ? 'Пока никто не голосовал' : 'Проголосовали: $voters · кто?', style: TextStyle(fontSize: 12.5, color: fg.withValues(alpha: 0.75))),
                ),
              ),
              const Spacer(),
              if (mine.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: _busy ? null : () => _send(const []),
                  child: const Text('Отменить голос', style: TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Окно «Новый опрос». Возвращает {q, o, m} или null.
Future<Map<String, dynamic>?> showCreatePoll(BuildContext context) {
  final q = TextEditingController();
  final opts = [TextEditingController(), TextEditingController()];
  var multi = false;
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Новый опрос'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: q, autofocus: true, maxLength: 200, decoration: const InputDecoration(labelText: 'Вопрос', hintText: 'Во сколько играем?')),
                for (var i = 0; i < opts.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TextField(
                      controller: opts[i],
                      maxLength: 100,
                      decoration: InputDecoration(
                        labelText: 'Вариант ${i + 1}',
                        counterText: '',
                        suffixIcon: opts.length > 2 ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => set(() => opts.removeAt(i))) : null,
                      ),
                    ),
                  ),
                if (opts.length < 10)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(onPressed: () => set(() => opts.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('Вариант')),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Можно выбрать несколько'),
                  value: multi,
                  onChanged: (v) => set(() => multi = v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final o = [for (final c in opts) if (c.text.trim().isNotEmpty) c.text.trim()];
              if (q.text.trim().isEmpty) {
                toast(ctx, 'Напиши вопрос');
                return;
              }
              if (o.length < 2) {
                toast(ctx, 'Нужно хотя бы 2 варианта');
                return;
              }
              Navigator.pop(ctx, {'q': q.text.trim(), 'o': o, 'm': multi});
            },
            child: const Text('Отправить'),
          ),
        ],
      ),
    ),
  );
}

// ---------- превью ссылки ----------

class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({super.key, required this.preview, required this.fg, required this.maxWidth, required this.onOpen});
  final Map<String, dynamic> preview;
  final Color fg;
  final double maxWidth;
  final void Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    if (preview['fail'] == true) return const SizedBox.shrink();
    final url = '${preview['url'] ?? ''}';
    final site = '${preview['site'] ?? ''}';
    final title = '${preview['title'] ?? ''}';
    final desc = '${preview['desc'] ?? ''}';
    final image = '${preview['image'] ?? ''}';
    final yt = preview['yt'] == true;
    final bigImage = image.isNotEmpty && (yt || desc.isEmpty);
    final w = (maxWidth - 20).clamp(160.0, 420.0).toDouble();
    Widget img(double width, double height) => Image.network(
          image,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
    return GestureDetector(
      onTap: url.isEmpty ? null : () => onOpen(url),
      child: Container(
        width: w,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.fromLTRB(10, 7, 8, 8),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: yt ? const Color(0xFFFF4444) : W.ice, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (site.isNotEmpty) Text(site, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: yt ? const Color(0xFFFF6B6B) : W.ice, fontWeight: FontWeight.w700)),
                      if (title.isNotEmpty) Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: fg, fontWeight: FontWeight.w700)),
                      if (desc.isNotEmpty) Text(desc, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: fg.withValues(alpha: 0.78))),
                    ],
                  ),
                ),
                if (image.isNotEmpty && !bigImage) ...[
                  const SizedBox(width: 8),
                  ClipRRect(borderRadius: BorderRadius.circular(6), child: img(64, 64)),
                ],
              ],
            ),
            if (bigImage)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      img(w - 18, (w - 18) * 9 / 16),
                      if (yt)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(color: Color(0xCCFF0000), shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow, color: Colors.white, size: 30),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- стикер и GIF ----------

class StickerView extends StatelessWidget {
  const StickerView({super.key, required this.message, this.size = 150});
  final RecordModel message;
  final double size;

  @override
  Widget build(BuildContext context) {
    final id = message.getStringValue('sticker');
    RecordModel? st;
    final ex = message.expand['sticker'];
    if (ex != null && ex.isNotEmpty) st = ex.first;
    st ??= StickerStore.I.byId(id);
    if (st == null) {
      return Container(
        width: size,
        height: 40,
        alignment: Alignment.center,
        child: Text('🖼 Стикер удалён', style: W.small),
      );
    }
    final url = StickerStore.urlOf(st);
    return Tooltip(
      message: '${st.getStringValue('pack')} · ${Api.I.nameOf(st.getStringValue('owner'))}',
      child: Image.network(
        url.toString(),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => SizedBox(width: size, height: size, child: Icon(Icons.broken_image_outlined, color: W.muted)),
      ),
    );
  }
}

class GifView extends StatelessWidget {
  const GifView({super.key, required this.gif, this.maxWidth = 260});
  final Map<String, dynamic> gif;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final url = '${gif['url'] ?? ''}';
    final w = ((gif['w'] as num?) ?? 200).toDouble();
    final h = ((gif['h'] as num?) ?? 200).toDouble();
    final width = w.clamp(80.0, maxWidth).toDouble();
    final height = (width * h / w).clamp(60.0, 360.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        loadingBuilder: (_, child, p) => p == null ? child : Container(width: width, height: height, color: W.surface2, alignment: Alignment.center, child: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        errorBuilder: (_, __, ___) => Container(width: width, height: 60, color: W.surface2, alignment: Alignment.center, child: Text('GIF не загрузилась', style: W.small)),
      ),
    );
  }
}

/// Сообщение-стикер или GIF без текста и файлов: рисуем без пузыря.
bool isBareMedia(RecordModel m) =>
    m.getStringValue('text').trim().isEmpty &&
    m.getListValue<String>('files').isEmpty &&
    (m.getStringValue('sticker').isNotEmpty || jsonMapOf(m, 'gif') != null);
