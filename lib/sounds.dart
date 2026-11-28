import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

/// Звуки сообщений и звонков. Кроме стандартного, все звуки синтезируются в коде (без файлов в APK).
class Sounds {
  static const messageSounds = ['Стандартный', 'Капля', 'Колокольчик', 'Льдинка', 'Пинг', 'Мягкий'];
  static const ringSounds = ['Системный', 'Колокольчики', 'Ретро-телефон', 'Мягкая мелодия'];

  static Player? _player;
  static Player? _ringPlayer;
  static DateTime _last = DateTime(2000);

  static Future<void> message({bool force = false, String? chatId}) async {
    if (!force && (!Settings.I.inAppSound || Settings.I.dnd)) return;
    if (!force && chatId != null && Settings.I.isMuted(chatId)) return;
    // Пачка сообщений подряд — один звук.
    final now = DateTime.now();
    if (!force && now.difference(_last) < const Duration(milliseconds: 1500)) return;
    _last = now;
    await play(Settings.I.messageSound);
  }

  /// Проиграть звук сообщения номер [n] (и для предпрослушивания в настройках).
  static Future<void> play(int n) async {
    try {
      final p = _player ??= Player();
      await p.setVolume(70);
      if (n <= 0 || n >= messageSounds.length) {
        await p.open(Media('asset:///assets/sounds/message.wav'));
      } else {
        await p.open(Media(await _file('msg_$n.wav', () => messageWav(n))));
      }
    } catch (_) {}
  }

  /// Мелодия входящего звонка по кругу. Вернёт функцию «выключить».
  static Future<void Function()> ring() async {
    final n = Settings.I.ringTone;
    if (n <= 0 || n >= ringSounds.length) {
      SystemSound.play(SystemSoundType.alert);
      final t = Stream.periodic(const Duration(seconds: 2)).listen((_) => SystemSound.play(SystemSoundType.alert));
      return t.cancel;
    }
    try {
      final p = _ringPlayer ??= Player();
      await p.setVolume(85);
      await p.setPlaylistMode(PlaylistMode.single);
      await p.open(Media(await _file('ring_$n.wav', () => ringWav(n))));
      return () => p.stop();
    } catch (_) {
      return () {};
    }
  }

  /// Послушать мелодию звонка 3 секунды.
  static Future<void> previewRing(int n) async {
    if (n <= 0) {
      SystemSound.play(SystemSoundType.alert);
      return;
    }
    try {
      final p = _ringPlayer ??= Player();
      await p.setPlaylistMode(PlaylistMode.none);
      await p.open(Media(await _file('ring_$n.wav', () => ringWav(n))));
      Future.delayed(const Duration(seconds: 3), p.stop);
    } catch (_) {}
  }

  static Player? _clickPlayer;

  /// Щелчок рации: [on] — включил микрофон, иначе выключил.
  static Future<void> pttClick(bool on) async {
    try {
      final p = _clickPlayer ??= Player();
      await p.setVolume(45);
      await p.open(Media(await _file(on ? 'ptt_on.wav' : 'ptt_off.wav', () => clickWav(on))));
    } catch (_) {}
  }

  static Future<String> _file(String name, Uint8List Function() make) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}winter_chat_$name');
    if (!f.existsSync()) await f.writeAsBytes(make(), flush: true);
    return f.path;
  }
}

const _rate = 22050;

Uint8List _wav(Float64List s) {
  final pcm = Int16List(s.length);
  for (var i = 0; i < s.length; i++) {
    pcm[i] = (s[i].clamp(-1.0, 1.0) * 32767).round();
  }
  final data = pcm.buffer.asUint8List();
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void u16(int v) => b.add([v & 255, (v >> 8) & 255]);
  b.add('RIFF'.codeUnits);
  u32(36 + data.length);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(_rate);
  u32(_rate * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(data.length);
  b.add(data);
  return b.toBytes();
}

/// Нота: [hz] с затуханием, начиная с [at] секунд.
void _note(Float64List out, double at, double hz, double len, double amp, {double decay = 0.15, double harmonic = 0.25, double bend = 0}) {
  final start = (at * _rate).round();
  final n = (len * _rate).round();
  var phase = 0.0;
  for (var k = 0; k < n && start + k < out.length; k++) {
    final t = k / _rate;
    final f = hz * (1 + bend * t / len);
    phase += 2 * math.pi * f / _rate;
    final env = math.exp(-t / decay) * math.min(1.0, k / (_rate * 0.004));
    out[start + k] += (math.sin(phase) + harmonic * math.sin(2 * phase)) * env * amp;
  }
}

/// Короткий щелчок рации (вверх — включил, вниз — выключил).
Uint8List clickWav(bool on) {
  final s = Float64List((_rate * 0.09).round());
  _note(s, 0, on ? 1400 : 900, 0.07, 0.35, decay: 0.02, harmonic: 0.1, bend: on ? 0.3 : -0.3);
  return _wav(s);
}

/// Звуки сообщения (1…5).
Uint8List messageWav(int n) {
  final s = Float64List((_rate * 0.8).round());
  switch (n) {
    case 1: // капля: короткий скользящий вверх тон
      _note(s, 0, 600, 0.18, 0.6, decay: 0.06, harmonic: 0, bend: 1.2);
    case 2: // колокольчик
      _note(s, 0, 1318.5, 0.7, 0.35, decay: 0.25, harmonic: 0.4);
      _note(s, 0.09, 1975.5, 0.6, 0.25, decay: 0.2, harmonic: 0.3);
    case 3: // льдинка: два высоких звонких тона
      _note(s, 0, 2093, 0.3, 0.3, decay: 0.08, harmonic: 0.1);
      _note(s, 0.11, 2637, 0.4, 0.3, decay: 0.1, harmonic: 0.1);
    case 4: // пинг
      _note(s, 0, 1046.5, 0.5, 0.45, decay: 0.12, harmonic: 0.05);
    default: // мягкий
      _note(s, 0, 523.25, 0.5, 0.4, decay: 0.16, harmonic: 0.15);
      _note(s, 0.12, 659.25, 0.55, 0.35, decay: 0.18, harmonic: 0.15);
  }
  return _wav(s);
}

/// Мелодии звонка (1…3): один повтор ~2,4 с, играет по кругу.
Uint8List ringWav(int n) {
  final s = Float64List((_rate * 2.4).round());
  switch (n) {
    case 1: // колокольчики
      const notes = [1318.5, 1567.98, 1975.5, 1567.98, 1318.5, 1567.98];
      for (var i = 0; i < notes.length; i++) {
        _note(s, i * 0.16, notes[i], 0.5, 0.3, decay: 0.18, harmonic: 0.35);
      }
    case 2: // ретро-телефон: двойная трель
      for (var burst = 0; burst < 2; burst++) {
        for (var i = 0; i < 10; i++) {
          final at = burst * 0.5 + i * 0.04;
          _note(s, at, i.isEven ? 880 : 1100, 0.04, 0.25, decay: 1, harmonic: 0.3);
        }
      }
    default: // мягкая мелодия
      const notes = [523.25, 659.25, 783.99, 1046.5, 783.99, 659.25];
      for (var i = 0; i < notes.length; i++) {
        _note(s, i * 0.22, notes[i], 0.7, 0.32, decay: 0.3, harmonic: 0.2);
      }
  }
  return _wav(s);
}
