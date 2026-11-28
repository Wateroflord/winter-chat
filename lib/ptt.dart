import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'call_controller.dart';
import 'settings.dart';
import 'sounds.dart';

/// Рация (push-to-talk): микрофон включён, только пока держишь клавишу.
/// На Windows клавиша работает, даже когда открыта игра (опрос клавиатуры раз в 30 мс).
/// На других ПК — пока окно Winter Chat активно. На телефоне — кнопка «Держи, чтобы говорить».

class PttKey {
  const PttKey(this.id, this.label, {this.vk = 0, this.key, this.mouse = 0});
  final String id;
  final String label;

  /// Код клавиши Windows (GetAsyncKeyState).
  final int vk;
  final LogicalKeyboardKey? key;

  /// Кнопка мыши (kBackMouseButton / kForwardMouseButton).
  final int mouse;
}

const pttKeys = <PttKey>[
  PttKey('mouse4', 'Боковая кнопка мыши (назад)', vk: 0x05, mouse: kBackMouseButton),
  PttKey('mouse5', 'Боковая кнопка мыши (вперёд)', vk: 0x06, mouse: kForwardMouseButton),
  PttKey('mouse3', 'Колёсико (нажать)', vk: 0x04, mouse: kMiddleMouseButton),
  PttKey('v', 'V', vk: 0x56, key: LogicalKeyboardKey.keyV),
  PttKey('b', 'B', vk: 0x42, key: LogicalKeyboardKey.keyB),
  PttKey('t', 'T', vk: 0x54, key: LogicalKeyboardKey.keyT),
  PttKey('g', 'G', vk: 0x47, key: LogicalKeyboardKey.keyG),
  PttKey('x', 'X', vk: 0x58, key: LogicalKeyboardKey.keyX),
  PttKey('caps', 'Caps Lock', vk: 0x14, key: LogicalKeyboardKey.capsLock),
  PttKey('lalt', 'Левый Alt', vk: 0xA4, key: LogicalKeyboardKey.altLeft),
  PttKey('lctrl', 'Левый Ctrl', vk: 0xA2, key: LogicalKeyboardKey.controlLeft),
  PttKey('tilde', '` (Ё)', vk: 0xC0, key: LogicalKeyboardKey.backquote),
  PttKey('f8', 'F8', vk: 0x77, key: LogicalKeyboardKey.f8),
  PttKey('f9', 'F9', vk: 0x78, key: LogicalKeyboardKey.f9),
];

PttKey pttKeyById(String id) => pttKeys.firstWhere((k) => k.id == id, orElse: () => pttKeys.first);

typedef _KeyStateC = Int16 Function(Int32 vKey);
typedef _KeyStateDart = int Function(int vKey);

class Ptt extends ChangeNotifier {
  Ptt._();
  static final Ptt I = Ptt._();

  static bool get _windows => !kIsWeb && Platform.isWindows;
  static bool get desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  _KeyStateDart? _keyState;
  Timer? _poll;
  bool _hooked = false;
  bool _key = false, _win = false, _mouse = false, _ui = false;
  bool _down = false;

  /// Сейчас говорю (клавиша зажата).
  bool get down => _down;

  bool get active => CallController.I.room != null && Settings.I.pttEnabled;

  PttKey get current => pttKeyById(Settings.I.pttKey);

  /// Включить/выключить слежение за клавишей (после входа/выхода из звонка и смены настроек).
  void sync() {
    if (active) {
      _start();
    } else {
      _stop();
    }
  }

  void _start() {
    if (!_hooked) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _hooked = true;
    }
    if (_windows && _poll == null) {
      try {
        _keyState ??= DynamicLibrary.open('user32.dll').lookupFunction<_KeyStateC, _KeyStateDart>('GetAsyncKeyState');
        _poll = Timer.periodic(const Duration(milliseconds: 30), (_) => _pollWindows());
      } catch (e) {
        debugPrint('ptt: $e');
      }
    }
  }

  void _stop() {
    if (_hooked) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _hooked = false;
    }
    _poll?.cancel();
    _poll = null;
    _key = _win = _mouse = _ui = false;
    if (_down) {
      _down = false;
      notifyListeners();
    }
  }

  bool _onKey(KeyEvent e) {
    final k = current.key;
    if (k != null && e.logicalKey == k) {
      if (e is KeyDownEvent) _key = true;
      if (e is KeyUpEvent) _key = false;
      _apply();
    }
    return false; // клавишу не «съедаем»
  }

  void _pollWindows() {
    final f = _keyState;
    if (f == null) return;
    final held = (f(current.vk) & 0x8000) != 0;
    if (held != _win) {
      _win = held;
      _apply();
    }
  }

  /// Кнопки мыши внутри окна приложения (для Linux; на Windows хватает опроса).
  void pointer(int buttons) {
    if (!active) return;
    final m = current.mouse;
    if (m == 0) return;
    final held = buttons & m != 0;
    if (held != _mouse) {
      _mouse = held;
      _apply();
    }
  }

  /// Кнопка «Держи, чтобы говорить» на экране.
  void hold(bool held) {
    _ui = held;
    _apply();
  }

  void _apply() {
    final d = active && (_key || _win || _mouse || _ui);
    if (d == _down) return;
    _down = d;
    CallController.I.setPttTalking(d);
    if (Settings.I.pttClick) Sounds.pttClick(d);
    notifyListeners();
  }
}
