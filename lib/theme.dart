import 'package:flutter/material.dart';

/// Зимняя тема Winter Hub: тёмно-синий фон и ледяные акценты.
class W {
  static const bg = Color(0xFF0A1020);
  static const surface = Color(0xFF111A2E);
  static const surface2 = Color(0xFF17223A);
  static const surface3 = Color(0xFF1E2B47);
  static const border = Color(0xFF24324F);
  static const text = Color(0xFFEAF2FF);
  static const muted = Color(0xFF8A9BB8);
  static const ice = Color(0xFF7FD8FF);
  static const iceLight = Color(0xFFC8EEFF);
  static const iceDeep = Color(0xFF1C4B6B);
  static const good = Color(0xFF5EE6A8);
  static const warn = Color(0xFFFFC46B);
  static const bad = Color(0xFFFF6B8A);

  static const h1 = TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: text, letterSpacing: -0.5);
  static const h2 = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: text);
  static const body = TextStyle(fontSize: 14.5, color: text, height: 1.35);
  static const small = TextStyle(fontSize: 12.5, color: muted, height: 1.35);

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
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: W.ice,
    onPrimary: W.bg,
    secondary: W.iceLight,
    surface: W.surface,
    onSurface: W.text,
    error: W.bad,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: W.border),
  );
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: W.bg,
    canvasColor: W.bg,
    dividerColor: W.border,
    appBarTheme: const AppBarTheme(
      backgroundColor: W.surface,
      foregroundColor: W.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: W.text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: W.surface2,
      hintStyle: const TextStyle(color: W.muted),
      labelStyle: const TextStyle(color: W.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: const BorderSide(color: W.ice, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: W.ice,
        foregroundColor: W.bg,
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
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: W.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: W.surface2,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: W.surface2,
      contentTextStyle: TextStyle(color: W.text),
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: W.ice),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? W.ice : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(W.bg),
      side: const BorderSide(color: W.muted),
    ),
  );
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
