import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Настройки приложения (хранятся на устройстве).
///
/// Ключи уведомлений читает и фоновая задача (bg_notify.dart), поэтому они
/// вынесены в константы и хранятся простыми значениями.
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings I = Settings._();

  // уведомления и звуки
  static const kNotify = 'set_notify';
  static const kNotifySound = 'set_notify_sound';
  static const kInAppSound = 'set_inapp_sound';
  static const kRingSound = 'set_ring_sound';
  static const kDndUntil = 'set_dnd_until'; // мс с 1970; -1 — пока не выключу

  late SharedPreferences _p;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
  }

  bool _b(String k, bool def) => _p.getBool(k) ?? def;
  Future<void> _setB(String k, bool v) async {
    await _p.setBool(k, v);
    notifyListeners();
  }

  // ---------- уведомления и звуки ----------

  bool get notify => _b(kNotify, true);
  set notify(bool v) => _setB(kNotify, v);

  bool get notifySound => _b(kNotifySound, true);
  set notifySound(bool v) => _setB(kNotifySound, v);

  /// Короткий звук, когда приходит сообщение в другой чат, пока приложение открыто.
  bool get inAppSound => _b(kInAppSound, true);
  set inAppSound(bool v) => _setB(kInAppSound, v);

  bool get ringSound => _b(kRingSound, true);
  set ringSound(bool v) => _setB(kRingSound, v);

  /// «Не беспокоить» включён прямо сейчас.
  bool get dnd => dndActive(_p);

  static bool dndActive(SharedPreferences p) {
    final until = p.getInt(kDndUntil) ?? 0;
    if (until == -1) return true;
    return until > DateTime.now().millisecondsSinceEpoch;
  }

  /// null — выключить, Duration.zero — пока не выключу.
  Future<void> setDnd(Duration? d) async {
    if (d == null) {
      await _p.remove(kDndUntil);
    } else if (d == Duration.zero) {
      await _p.setInt(kDndUntil, -1);
    } else {
      await _p.setInt(kDndUntil, DateTime.now().add(d).millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  /// До какого времени «Не беспокоить» (null — выключено или «пока не выключу»).
  DateTime? get dndUntil {
    final until = _p.getInt(kDndUntil) ?? 0;
    if (until <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(until);
  }

  bool get dndForever => (_p.getInt(kDndUntil) ?? 0) == -1;

  // ---------- внешний вид ----------

  static const textScales = [0.9, 1.0, 1.1, 1.2, 1.35];

  double get textScale => _p.getDouble('set_text_scale') ?? 1.0;
  set textScale(double v) {
    _p.setDouble('set_text_scale', v);
    notifyListeners();
  }

  static const accents = <(String, Color)>[
    ('Лёд', Color(0xFF7FD8FF)),
    ('Аметист', Color(0xFFBE8CFF)),
    ('Сакура', Color(0xFFFF78AA)),
    ('Мята', Color(0xFF6ED28C)),
    ('Янтарь', Color(0xFFFFAA5A)),
    ('Сапфир', Color(0xFF5B9DFF)),
  ];

  int get accentIndex => (_p.getInt('set_accent') ?? 0).clamp(0, accents.length - 1);
  set accentIndex(int v) {
    _p.setInt('set_accent', v);
    notifyListeners();
  }

  Color get accent => accents[accentIndex].$2;

  /// Цвет своих сообщений: тёмный оттенок акцента.
  Color get myBubble => Color.lerp(const Color(0xFF0A1020), accent, 0.32)!;

  static const backgrounds = ['Без фона', 'Снегопад', 'Северное сияние', 'Глубина', 'Звёзды'];

  int get chatBackground => (_p.getInt('set_chat_bg') ?? 0).clamp(0, backgrounds.length - 1);
  set chatBackground(int v) {
    _p.setInt('set_chat_bg', v);
    notifyListeners();
  }

  bool get compact => _b('set_compact', false);
  set compact(bool v) => _setB('set_compact', v);

  // ---------- звонки и медиа ----------

  bool get noiseSuppression => _b('set_ns', true);
  set noiseSuppression(bool v) => _setB('set_ns', v);

  bool get echoCancellation => _b('set_aec', true);
  set echoCancellation(bool v) => _setB('set_aec', v);

  bool get autoGain => _b('set_agc', true);
  set autoGain(bool v) => _setB('set_agc', v);

  /// Качество камеры: 0 — 480p, 1 — 720p, 2 — 1080p.
  int get cameraQuality => (_p.getInt('set_cam_q') ?? 1).clamp(0, 2);
  set cameraQuality(int v) {
    _p.setInt('set_cam_q', v);
    notifyListeners();
  }

  /// Выбранные устройства (deviceId), пусто — по умолчанию.
  String get micId => _p.getString('set_mic') ?? '';
  set micId(String v) {
    _p.setString('set_mic', v);
    notifyListeners();
  }

  String get cameraId => _p.getString('set_cam') ?? '';
  set cameraId(String v) {
    _p.setString('set_cam', v);
    notifyListeners();
  }

  String get speakerId => _p.getString('set_spk') ?? '';
  set speakerId(String v) {
    _p.setString('set_spk', v);
    notifyListeners();
  }

  /// Показывать фото сразу (иначе — по нажатию).
  bool get autoloadImages => _b('set_autoload_img', true);
  set autoloadImages(bool v) => _setB('set_autoload_img', v);

  /// Видео: сразу со звуком или без.
  bool get videoMuted => _b('set_video_muted', false);
  set videoMuted(bool v) => _setB('set_video_muted', v);
}
