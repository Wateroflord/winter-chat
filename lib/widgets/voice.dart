import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:record/record.dart';

import '../api.dart';
import '../theme.dart';
import '../util.dart';

/// Запись голосового сообщения в файл.
class VoiceRecorder {
  AudioRecorder? _rec;
  String? _path;
  DateTime? _started;

  bool get recording => _started != null;
  Duration get elapsed => _started == null ? Duration.zero : DateTime.now().difference(_started!);

  /// Начать запись. Вернёт текст ошибки или null.
  Future<String?> start() async {
    try {
      final rec = _rec ??= AudioRecorder();
      if (!await rec.hasPermission()) return 'Нет доступа к микрофону — разреши его в настройках.';
      // AAC (m4a) — маленькие файлы; если нельзя — Opus или WAV.
      var encoder = AudioEncoder.aacLc;
      var ext = 'm4a';
      if (!await rec.isEncoderSupported(encoder)) {
        if (await rec.isEncoderSupported(AudioEncoder.opus)) {
          encoder = AudioEncoder.opus;
          ext = 'ogg';
        } else {
          encoder = AudioEncoder.wav;
          ext = 'wav';
        }
      }
      final dir = await getTemporaryDirectory();
      _path = '${dir.path}${Platform.pathSeparator}voice_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await rec.start(RecordConfig(encoder: encoder, numChannels: 1, sampleRate: 44100, bitRate: 64000), path: _path!);
      _started = DateTime.now();
      return null;
    } catch (e) {
      _started = null;
      return 'Не удалось включить микрофон: $e';
    }
  }

  /// Остановить. Вернёт путь к файлу (null — запись слишком короткая или ошибка).
  Future<String?> stop() async {
    final long = elapsed >= const Duration(milliseconds: 700);
    _started = null;
    try {
      final path = await _rec?.stop();
      if (!long) {
        _delete(path ?? _path);
        return null;
      }
      return path ?? _path;
    } catch (_) {
      return null;
    }
  }

  Future<void> cancel() async {
    _started = null;
    try {
      final path = await _rec?.stop();
      _delete(path ?? _path);
    } catch (_) {}
  }

  void _delete(String? p) {
    if (p == null) return;
    try {
      File(p).deleteSync();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _rec?.dispose();
    } catch (_) {}
    _rec = null;
  }
}

String mmss(Duration d) => '${d.inMinutes}:${two(d.inSeconds % 60)}';

/// Голосовое или аудио в сообщении: ▶, полоса прогресса, длительность.
class VoiceMessage extends StatefulWidget {
  const VoiceMessage({super.key, required this.message, required this.file, required this.width, this.color});
  final RecordModel message;
  final String file;
  final double width;
  final Color? color;

  @override
  State<VoiceMessage> createState() => _VoiceMessageState();
}

class _VoiceMessageState extends State<VoiceMessage> {
  /// Одновременно играет только одно.
  static _VoiceMessageState? _playing;

  Player? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _isPlaying = false;
  Duration _pos = Duration.zero, _dur = Duration.zero;
  double _speed = 1;

  bool get _voice => widget.file.startsWith('voice_');

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _player?.dispose();
    _player = null;
    if (_playing == this) _playing = null;
  }

  Future<void> _toggle() async {
    final p = _player;
    if (p != null) {
      await p.playOrPause();
      return;
    }
    if (_playing != null && _playing != this) _playing!._pause();
    _playing = this;
    final player = Player();
    _player = player;
    _subs
      ..add(player.stream.playing.listen((v) => mounted ? setState(() => _isPlaying = v) : null))
      ..add(player.stream.position.listen((v) => mounted ? setState(() => _pos = v) : null))
      ..add(player.stream.duration.listen((v) => mounted ? setState(() => _dur = v) : null))
      ..add(player.stream.completed.listen((done) {
        if (done && mounted) {
          setState(() {
            _isPlaying = false;
            _pos = Duration.zero;
          });
          player.seek(Duration.zero);
          player.pause();
        }
      }));
    await player.setRate(_speed);
    await player.open(Media(Api.I.fileUrl(widget.message, widget.file).toString()));
  }

  void _pause() => _player?.pause();

  Future<void> _cycleSpeed() async {
    final next = _speed == 1 ? 1.5 : (_speed == 1.5 ? 2.0 : 1.0);
    setState(() => _speed = next);
    await _player?.setRate(next);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.color ?? W.text;
    final total = _dur.inMilliseconds > 0 ? _dur : Duration.zero;
    final progress = total.inMilliseconds == 0 ? 0.0 : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: widget.width.clamp(200.0, 320.0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Material(
              color: W.ice,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: W.onAccent, size: 24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_voice)
                    Text(prettyFileName(widget.file), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: fg)),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: SliderComponentShape.noOverlay,
                      activeTrackColor: W.ice,
                      inactiveTrackColor: fg.withValues(alpha: 0.25),
                      thumbColor: W.ice,
                    ),
                    child: Slider(
                      value: progress,
                      onChanged: total == Duration.zero ? null : (v) => _player?.seek(Duration(milliseconds: (v * total.inMilliseconds).round())),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(_voice ? Icons.mic : Icons.music_note, size: 13, color: fg.withValues(alpha: 0.6)),
                      const SizedBox(width: 3),
                      Text(
                        _player == null ? (_voice ? 'Голосовое' : 'Аудио') : '${mmss(_pos)} / ${mmss(total)}',
                        style: TextStyle(fontSize: 11.5, color: fg.withValues(alpha: 0.7)),
                      ),
                      const Spacer(),
                      if (_player != null)
                        GestureDetector(
                          onTap: _cycleSpeed,
                          child: Text('${_speed == 1 ? '1' : _speed}×', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg.withValues(alpha: 0.8))),
                        ),
                    ],
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
