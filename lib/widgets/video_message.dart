import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pocketbase/pocketbase.dart';

import '../api.dart';
import '../settings.dart';
import '../theme.dart';
import '../util.dart';

/// Видео прямо в сообщении: превью с кнопкой ▶, по нажатию играет здесь же.
/// В панели плеера есть кнопка «на весь экран».
class VideoMessage extends StatefulWidget {
  const VideoMessage({super.key, required this.message, required this.file, required this.width});
  final RecordModel message;
  final String file;
  final double width;

  @override
  State<VideoMessage> createState() => _VideoMessageState();
}

class _VideoMessageState extends State<VideoMessage> {
  /// Одновременно играет только одно видео.
  static _VideoMessageState? _playing;

  Player? _player;
  VideoController? _controller;
  double _aspect = 16 / 9;
  String? _error;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final p = _player;
    _player = null;
    _controller = null;
    if (_playing == this) _playing = null;
    if (p != null) p.dispose();
  }

  Future<void> _start() async {
    if (_player != null) return;
    if (_playing != null && _playing != this) {
      _playing!._pauseFromOther();
    }
    _playing = this;
    final player = Player();
    final controller = VideoController(player);
    setState(() {
      _player = player;
      _controller = controller;
      _error = null;
    });
    _subs.add(player.stream.width.listen((_) => _updateAspect()));
    _subs.add(player.stream.height.listen((_) => _updateAspect()));
    _subs.add(player.stream.error.listen((e) {
      if (mounted && e.isNotEmpty && _player == player && player.state.duration == Duration.zero) {
        setState(() => _error = 'Не получилось воспроизвести видео');
      }
    }));
    try {
      if (Settings.I.videoMuted) await player.setVolume(0);
      final url = Api.I.fileUrl(widget.message, widget.file).toString();
      await player.open(Media(url));
    } catch (_) {
      if (mounted) setState(() => _error = 'Не получилось открыть видео');
    }
  }

  void _pauseFromOther() {
    try {
      _player?.pause();
    } catch (_) {}
  }

  void _updateAspect() {
    final p = _player;
    if (p == null || !mounted) return;
    final w = p.state.width ?? 0;
    final h = p.state.height ?? 0;
    if (w > 0 && h > 0) {
      final a = (w / h).clamp(0.5, 2.4).toDouble();
      if ((a - _aspect).abs() > 0.01) setState(() => _aspect = a);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    // Вертикальные видео не должны занимать весь экран.
    final maxH = (MediaQuery.sizeOf(context).height * 0.6).clamp(220.0, 640.0).toDouble();
    var boxW = w;
    var boxH = w / _aspect;
    if (boxH > maxH) {
      boxH = maxH;
      boxW = maxH * _aspect;
    }
    final c = _controller;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: boxW,
          height: boxH,
          child: c == null || _error != null ? _placeholder() : Video(controller: c, fill: Colors.black),
        ),
      ),
    );
  }

  Widget _placeholder() {
    final name = prettyFileName(widget.file);
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: () {
          if (_error != null) {
            _stop();
            setState(() => _error = null);
          }
          _start();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF0E1A30), Color(0xFF050A14)],
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Icon(_error != null ? Icons.refresh : Icons.play_arrow_rounded, size: 40, color: Colors.white),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: const TextStyle(color: W.warn, fontSize: 12.5)),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: Row(
                children: [
                  const Icon(Icons.movie_outlined, size: 15, color: Colors.white70),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
