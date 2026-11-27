import 'package:flutter/material.dart';

/// Палитра темы: фон, поверхности, текст. Акцент выбирается отдельно.
class Palette {
  const Palette({
    required this.id,
    required this.name,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.text,
    required this.muted,
    this.light = false,
    this.good = const Color(0xFF5EE6A8),
    this.warn = const Color(0xFFFFC46B),
    this.bad = const Color(0xFFFF6B8A),
  });

  final String id, name;
  final bool light;
  final Color bg, surface, surface2, surface3, border, text, muted, good, warn, bad;
}

const palettes = <Palette>[
  Palette(
    id: 'winter',
    name: 'Зима',
    bg: Color(0xFF0A1020),
    surface: Color(0xFF111A2E),
    surface2: Color(0xFF17223A),
    surface3: Color(0xFF1E2B47),
    border: Color(0xFF24324F),
    text: Color(0xFFEAF2FF),
    muted: Color(0xFF8A9BB8),
  ),
  Palette(
    id: 'midnight',
    name: 'Полночь',
    bg: Color(0xFF000000),
    surface: Color(0xFF0C0C10),
    surface2: Color(0xFF16171D),
    surface3: Color(0xFF202129),
    border: Color(0xFF2A2C35),
    text: Color(0xFFF2F3F7),
    muted: Color(0xFF8C8F9C),
  ),
  Palette(
    id: 'graphite',
    name: 'Графит',
    bg: Color(0xFF18191C),
    surface: Color(0xFF202125),
    surface2: Color(0xFF2B2C31),
    surface3: Color(0xFF35373D),
    border: Color(0xFF3C3E45),
    text: Color(0xFFECEDEF),
    muted: Color(0xFF9B9DA5),
  ),
  Palette(
    id: 'forest',
    name: 'Лес',
    bg: Color(0xFF0A1410),
    surface: Color(0xFF101F18),
    surface2: Color(0xFF162920),
    surface3: Color(0xFF1E352A),
    border: Color(0xFF264233),
    text: Color(0xFFE6F4EA),
    muted: Color(0xFF8CA996),
  ),
  Palette(
    id: 'wine',
    name: 'Вино',
    bg: Color(0xFF16080E),
    surface: Color(0xFF210F17),
    surface2: Color(0xFF2C1520),
    surface3: Color(0xFF381C2A),
    border: Color(0xFF482535),
    text: Color(0xFFF7E8EE),
    muted: Color(0xFFB08B9A),
  ),
  Palette(
    id: 'ocean',
    name: 'Океан',
    bg: Color(0xFF041A22),
    surface: Color(0xFF09232D),
    surface2: Color(0xFF0E2E3A),
    surface3: Color(0xFF143A48),
    border: Color(0xFF1B4858),
    text: Color(0xFFE3F6FA),
    muted: Color(0xFF86A9B4),
  ),
  Palette(
    id: 'light',
    name: 'Светлая',
    light: true,
    bg: Color(0xFFF2F4F8),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFE8ECF2),
    surface3: Color(0xFFDCE2EB),
    border: Color(0xFFCBD3DF),
    text: Color(0xFF141B27),
    muted: Color(0xFF5D6A7E),
    good: Color(0xFF16975E),
    warn: Color(0xFFB97A12),
    bad: Color(0xFFD5345A),
  ),
  Palette(
    id: 'sand',
    name: 'Песок',
    light: true,
    bg: Color(0xFFF5EFE6),
    surface: Color(0xFFFFFCF7),
    surface2: Color(0xFFECE3D6),
    surface3: Color(0xFFE1D5C4),
    border: Color(0xFFD3C4AE),
    text: Color(0xFF2A2118),
    muted: Color(0xFF7A6A57),
    good: Color(0xFF2E8B57),
    warn: Color(0xFFB0741A),
    bad: Color(0xFFC6364F),
  ),
];

Palette paletteById(String id) => palettes.firstWhere((p) => p.id == id, orElse: () => palettes.first);

/// Цвет текста, который читается на фоне [c].
Color onColor(Color c) => c.computeLuminance() > 0.45 ? const Color(0xFF0E1420) : Colors.white;

/// Цвета приложения. Меняются вместе с темой (Настройки → Оформление), поэтому это не константы.
class W {
  static Palette palette = palettes.first;

  static Color bg = palette.bg;
  static Color surface = palette.surface;
  static Color surface2 = palette.surface2;
  static Color surface3 = palette.surface3;
  static Color border = palette.border;
  static Color text = palette.text;
  static Color muted = palette.muted;

  /// Акцент (раньше всегда был ледяной — отсюда имя).
  static Color ice = const Color(0xFF7FD8FF);
  static Color iceLight = const Color(0xFFC8EEFF);
  static Color iceDeep = const Color(0xFF1C4B6B);

  /// Текст и значки поверх акцента.
  static Color onAccent = palette.bg;

  static Color good = palette.good;
  static Color warn = palette.warn;
  static Color bad = palette.bad;

  static bool get light => palette.light;

  static TextStyle get h1 => TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: text, letterSpacing: -0.5);
  static TextStyle get h2 => TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: text);
  static TextStyle get body => TextStyle(fontSize: 14.5, color: text, height: 1.35);
  static TextStyle get small => TextStyle(fontSize: 12.5, color: muted, height: 1.35);

  static const avatarColors = [
    Color(0xFF7FD8FF),
    Color(0xFFBE8CFF),
    Color(0xFFFF78AA),
    Color(0xFF6ED28C),
    Color(0xFFFFAA5A),
    Color(0xFF5B9DFF),
    Color(0xFFE04848),
    Color(0xFFFFD45A),
  ];

  /// Применить тему и акцент.
  static void apply(Palette p, Color accent) {
    palette = p;
    bg = p.bg;
    surface = p.surface;
    surface2 = p.surface2;
    surface3 = p.surface3;
    border = p.border;
    text = p.text;
    muted = p.muted;
    good = p.good;
    warn = p.warn;
    bad = p.bad;
    // На светлой теме слишком светлый акцент не видно — чуть затемняем.
    ice = p.light && accent.computeLuminance() > 0.5 ? Color.lerp(accent, Colors.black, 0.28)! : accent;
    iceLight = p.light ? Color.lerp(ice, Colors.black, 0.15)! : Color.lerp(ice, Colors.white, 0.55)!;
    iceDeep = p.light ? Color.lerp(ice, Colors.white, 0.75)! : Color.lerp(ice, p.bg, 0.65)!;
    onAccent = onColor(ice);
  }
}

ThemeData buildTheme({Color? accent}) {
  final a = accent ?? W.ice;
  final scheme = (W.light ? const ColorScheme.light() : const ColorScheme.dark()).copyWith(
    primary: a,
    onPrimary: W.onAccent,
    secondary: W.iceLight,
    surface: W.surface,
    onSurface: W.text,
    error: W.bad,
    outline: W.border,
    outlineVariant: W.border,
    onSurfaceVariant: W.muted,
    primaryContainer: W.iceDeep,
    onPrimaryContainer: W.text,
    secondaryContainer: W.iceDeep,
    onSecondaryContainer: W.text,
    surfaceContainerLowest: W.bg,
    surfaceContainerLow: W.surface,
    surfaceContainer: W.surface,
    surfaceContainerHigh: W.surface2,
    surfaceContainerHighest: W.surface3,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: W.border),
  );
  return ThemeData(
    brightness: W.light ? Brightness.light : Brightness.dark,
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: W.bg,
    canvasColor: W.bg,
    dividerColor: W.border,
    iconTheme: IconThemeData(color: W.text),
    textTheme: (W.light ? ThemeData.light() : ThemeData.dark()).textTheme.apply(bodyColor: W.text, displayColor: W.text),
    listTileTheme: ListTileThemeData(textColor: W.text, iconColor: W.muted),
    appBarTheme: AppBarTheme(
      backgroundColor: W.surface,
      foregroundColor: W.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: W.text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: W.surface2,
      hintStyle: TextStyle(color: W.muted),
      labelStyle: TextStyle(color: W.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: a, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: a,
        foregroundColor: W.onAccent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: W.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: W.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: W.surface2,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: W.surface2,
      contentTextStyle: TextStyle(color: W.text),
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: a),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? W.onAccent : W.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? a : W.surface3),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: a, thumbColor: a, inactiveTrackColor: W.surface3),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? a : Colors.transparent),
      checkColor: WidgetStatePropertyAll(W.onAccent),
      side: BorderSide(color: W.muted),
    ),
  );
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Перестроить всё дерево виджетов (после смены темы: многие виджеты созданы как const и сами не обновятся).
void rebuildAll(BuildContext context) {
  void visit(Element e) {
    e.markNeedsBuild();
    e.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);
}
