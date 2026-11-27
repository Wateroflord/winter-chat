import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'widgets/chat_background.dart';

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

  int? _i(String k) => _p.getInt(k);
  Future<void> _setI(String k, int? v) async {
    v == null ? await _p.remove(k) : await _p.setInt(k, v);
    notifyListeners();
  }

  /// Тема (палитра).
  Palette get palette => paletteById(_p.getString('set_palette') ?? 'winter');
  set palette(Palette p) {
    _p.setString('set_palette', p.id);
    notifyListeners();
  }

  static const accents = <(String, Color)>[
    ('Лёд', Color(0xFF7FD8FF)),
    ('Аметист', Color(0xFFBE8CFF)),
    ('Сакура', Color(0xFFFF78AA)),
    ('Мята', Color(0xFF6ED28C)),
    ('Янтарь', Color(0xFFFFAA5A)),
    ('Сапфир', Color(0xFF5B9DFF)),
    ('Рубин', Color(0xFFFF5C5C)),
    ('Лимон', Color(0xFFE8E15A)),
    ('Бирюза', Color(0xFF3DDCC8)),
    ('Лаванда', Color(0xFF9C8CFF)),
    ('Персик', Color(0xFFFF9C7A)),
    ('Серебро', Color(0xFFC4CCD8)),
  ];

  /// Акцент: свой цвет или один из готовых (раньше хранился номер — читаем и его).
  Color get accent {
    final v = _i('set_accent_color');
    if (v != null) return Color(v);
    final idx = (_i('set_accent') ?? 0).clamp(0, accents.length - 1);
    return accents[idx].$2;
  }

  set accent(Color c) => _setI('set_accent_color', c.toARGB32());

  /// Стиль сообщений: 0 — пузыри с уголком, 1 — круглые пузыри, 2 — квадратные, 3 — список (как в Discord).
  static const bubbleStyles = ['С уголком', 'Круглые', 'Квадратные', 'Список'];
  int get bubbleStyle => (_i('set_bubble_style') ?? 0).clamp(0, bubbleStyles.length - 1);
  set bubbleStyle(int v) => _setI('set_bubble_style', v);

  /// Скругление пузырей.
  double get bubbleRadius => _p.getDouble('set_bubble_radius') ?? 16;
  set bubbleRadius(double v) {
    _p.setDouble('set_bubble_radius', v);
    notifyListeners();
  }

  /// Свой цвет моих сообщений (null — из акцента).
  Color? get myBubbleColor => _i('set_my_bubble') == null ? null : Color(_i('set_my_bubble')!);
  set myBubbleColor(Color? c) => _setI('set_my_bubble', c?.toARGB32());

  bool get myBubbleGradient => _b('set_my_bubble_grad', false);
  set myBubbleGradient(bool v) => _setB('set_my_bubble_grad', v);

  /// Свой цвет чужих сообщений (null — как фон карточек темы).
  Color? get otherBubbleColor => _i('set_other_bubble') == null ? null : Color(_i('set_other_bubble')!);
  set otherBubbleColor(Color? c) => _setI('set_other_bubble', c?.toARGB32());

  /// Цвет моих сообщений с учётом темы, акцента и чата.
  Color myBubbleFor([String? chatId]) {
    final own = chatId == null ? null : chatPrefs(chatId).bubble;
    final c = own ?? myBubbleColor;
    if (c != null) return c;
    return W.light ? Color.lerp(Colors.white, W.ice, 0.30)! : Color.lerp(W.bg, W.ice, 0.32)!;
  }

  Color get myBubble => myBubbleFor();

  Color get otherBubble => otherBubbleColor ?? (W.light ? W.surface : W.surface2);

  bool get showAvatars => _b('set_show_avatars', true);
  set showAvatars(bool v) => _setB('set_show_avatars', v);

  bool get bigEmoji => _b('set_big_emoji', true);
  set bigEmoji(bool v) => _setB('set_big_emoji', v);

  bool get compact => _b('set_compact', false);
  set compact(bool v) => _setB('set_compact', v);

  /// Аватары: круг или скруглённый квадрат.
  bool get squareAvatars => _b('set_square_avatars', false);
  set squareAvatars(bool v) => _setB('set_square_avatars', v);

  /// В списке чатов — текст последнего сообщения.
  bool get chatPreview => _b('set_chat_preview', true);
  set chatPreview(bool v) => _setB('set_chat_preview', v);

  /// На ПК: Enter отправляет (иначе — Ctrl+Enter).
  bool get enterSends => _b('set_enter_sends', true);
  set enterSends(bool v) => _setB('set_enter_sends', v);

  /// Фон переписки.
  Wallpaper get wallpaper {
    final w = Wallpaper.decode(_p.getString('set_wallpaper'));
    if (w != null) return w;
    final old = _i('set_chat_bg') ?? 0; // старая настройка: номер готового фона
    return old <= 0 ? const Wallpaper.none() : Wallpaper.preset(old);
  }

  set wallpaper(Wallpaper w) {
    _p.setString('set_wallpaper', w.encode());
    notifyListeners();
  }

  /// Фон с учётом своего фона чата.
  Wallpaper wallpaperFor(String chatId) => chatPrefs(chatId).wallpaper ?? wallpaper;

  /// Звук нового сообщения (номер из [Sounds.messageSounds]).
  int get messageSound => _i('set_msg_sound') ?? 0;
  set messageSound(int v) => _setI('set_msg_sound', v);

  /// Мелодия звонка (номер из [Sounds.ringSounds]).
  int get ringTone => _i('set_ring_tone') ?? 0;
  set ringTone(int v) => _setI('set_ring_tone', v);

  /// Подпись темы — меняется, когда надо перекрасить приложение.
  String get themeKey => '${palette.id}|${accent.toARGB32()}';

  /// Сбросить оформление.
  Future<void> resetAppearance() async {
    for (final k in [
      'set_palette',
      'set_accent',
      'set_accent_color',
      'set_bubble_style',
      'set_bubble_radius',
      'set_my_bubble',
      'set_my_bubble_grad',
      'set_other_bubble',
      'set_show_avatars',
      'set_big_emoji',
      'set_compact',
      'set_square_avatars',
      'set_chat_preview',
      'set_wallpaper',
      'set_chat_bg',
      'set_text_scale',
    ]) {
      await _p.remove(k);
    }
    notifyListeners();
  }

  // ---------- настройки отдельных чатов (только на этом устройстве) ----------

  static const kMutedChats = 'set_muted_chats';

  Map<String, dynamic> get _chats {
    try {
      final raw = _p.getString('set_chat_prefs');
      if (raw == null) return {};
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {};
    }
  }

  // Разобранные настройки чатов: читаются на каждом сообщении, поэтому держим в памяти.
  Map<String, ChatPrefs>? _chatCache;

  ChatPrefs chatPrefs(String chatId) {
    final cache = _chatCache ??= {
      for (final e in _chats.entries)
        if (e.value is Map) e.key: ChatPrefs.fromJson(e.value as Map),
    };
    return cache[chatId] ?? const ChatPrefs();
  }

  Future<void> setChatPrefs(String chatId, ChatPrefs prefs) async {
    final all = _chats;
    if (prefs.isEmpty) {
      all.remove(chatId);
    } else {
      all[chatId] = prefs.toJson();
    }
    await _p.setString('set_chat_prefs', jsonEncode(all));
    _chatCache = null;
    // Фоновые уведомления читают простой список чатов без звука.
    await _p.setStringList(kMutedChats, [
      for (final e in all.entries)
        if (e.value is Map && (e.value as Map)['mute'] == true) e.key,
    ]);
    notifyListeners();
  }

  bool isMuted(String chatId) => chatPrefs(chatId).mute;
  bool isPinned(String chatId) => chatPrefs(chatId).pin;
  String alias(String chatId) => chatPrefs(chatId).alias;

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

/// Настройки одного чата на этом устройстве.
class ChatPrefs {
  const ChatPrefs({this.alias = '', this.pin = false, this.mute = false, this.wallpaper, this.bubble});

  /// Своё имя чата (видишь только ты).
  final String alias;
  final bool pin, mute;

  /// Свой фон (null — как во всех чатах).
  final Wallpaper? wallpaper;

  /// Свой цвет моих сообщений (null — как везде).
  final Color? bubble;

  bool get isEmpty => alias.isEmpty && !pin && !mute && wallpaper == null && bubble == null;

  ChatPrefs copyWith({
    String? alias,
    bool? pin,
    bool? mute,
    Wallpaper? wallpaper,
    bool clearWallpaper = false,
    Color? bubble,
    bool clearBubble = false,
  }) =>
      ChatPrefs(
        alias: alias ?? this.alias,
        pin: pin ?? this.pin,
        mute: mute ?? this.mute,
        wallpaper: clearWallpaper ? null : (wallpaper ?? this.wallpaper),
        bubble: clearBubble ? null : (bubble ?? this.bubble),
      );

  Map<String, dynamic> toJson() => {
        if (alias.isNotEmpty) 'alias': alias,
        if (pin) 'pin': true,
        if (mute) 'mute': true,
        if (wallpaper != null) 'wp': wallpaper!.toJson(),
        if (bubble != null) 'bubble': bubble!.toARGB32(),
      };

  factory ChatPrefs.fromJson(Map j) => ChatPrefs(
        alias: j['alias'] is String ? j['alias'] as String : '',
        pin: j['pin'] == true,
        mute: j['mute'] == true,
        wallpaper: j['wp'] is Map ? Wallpaper.fromJson(j['wp'] as Map) : null,
        bubble: j['bubble'] is int ? Color(j['bubble'] as int) : null,
      );
}
