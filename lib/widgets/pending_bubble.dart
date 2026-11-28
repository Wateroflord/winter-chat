import 'package:flutter/material.dart';

import '../outbox.dart';
import '../settings.dart';
import '../theme.dart';
import '../util.dart';

/// Моё сообщение, которое ещё отправляется (полоска загрузки, «нет связи», «повторить»).
class PendingBubble extends StatelessWidget {
  const PendingBubble({super.key, required this.item});
  final OutItem item;

  @override
  Widget build(BuildContext context) {
    final bg = Settings.I.myBubbleFor(item.chatId);
    final fg = onColor(bg);
    final sub = fg.withValues(alpha: 0.7);
    final maxW = (MediaQuery.sizeOf(context).width * 0.72).clamp(200.0, 560.0).toDouble();
    final failed = item.state == OutState.failed;
    final waiting = item.state == OutState.waiting;
    final total = item.totalBytes;
    final extra = item.extra;
    String what = item.text;
    if (what.isEmpty) {
      if (extra['poll'] is Map) {
        what = '📊 ${(extra['poll'] as Map)['q']}';
      } else if (extra.containsKey('sticker')) {
        what = '🖼 Стикер';
      } else if (extra.containsKey('gif')) {
        what = 'GIF';
      } else if (item.files.length == 1 && item.files.first.name.startsWith('voice_')) {
        what = '🎤 Голосовое';
      }
    }
    final status = failed
        ? '⚠ ${item.error ?? 'Не отправилось'}'
        : waiting
            ? (item.attempts == 0 ? 'Отправляется…' : 'Нет связи — отправлю сам, когда сеть вернётся')
            : total > 0
                ? 'Загрузка ${(item.progress * 100).round()}% · ${humanSize(item.sentBytes)} из ${humanSize(total)}'
                : 'Отправляется…';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Opacity(
              opacity: failed ? 1 : 0.85,
              child: Container(
                constraints: BoxConstraints(maxWidth: maxW),
                padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(Settings.I.bubbleRadius),
                  border: failed ? Border.all(color: W.bad, width: 1.5) : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final f in item.files)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.attach_file, size: 16, color: sub),
                            const SizedBox(width: 4),
                            Flexible(child: Text('${f.name} · ${humanSize(f.size)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 13))),
                          ],
                        ),
                      ),
                    if (what.isNotEmpty) Text(what, style: W.body.copyWith(color: fg)),
                    if (total > 0 && !failed)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: item.state == OutState.sending ? item.progress : null,
                            minHeight: 4,
                            backgroundColor: fg.withValues(alpha: 0.15),
                            color: fg,
                          ),
                        ),
                      ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(failed ? Icons.error_outline : Icons.schedule, size: 13, color: failed ? W.bad : sub),
                        const SizedBox(width: 4),
                        Flexible(child: Text(status, style: TextStyle(fontSize: 11.5, color: failed ? (onColor(bg) == Colors.white ? Colors.white : W.bad) : sub))),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (failed || waiting)
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                            onPressed: () => Outbox.I.retry(item),
                            child: const Text('Повторить'),
                          ),
                        TextButton(
                          style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                          onPressed: () => Outbox.I.remove(item),
                          child: Text(failed || waiting ? 'Удалить' : 'Отменить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
