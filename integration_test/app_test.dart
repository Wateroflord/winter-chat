// Проверка приложения на настоящем сервере: регистрация, чат, сообщение, звонок.
// Запускается в GitHub Actions (screens.yml) на Linux с виртуальным экраном.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' show setLoggingLevel, LoggerLevel;
import 'package:logging/logging.dart';
import 'package:winter_chat/call_controller.dart';
import 'package:winter_chat/main.dart' as app;
import 'package:winter_chat/screens/call_screen.dart';
import 'package:winter_chat/store.dart';

const server = String.fromEnvironment('SERVER', defaultValue: '127.0.0.1:8090');
const invite = String.fromEnvironment('INVITE');
const shotsDir = String.fromEnvironment('SHOTS', defaultValue: 'shots');

Future<void> shot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 300));
  await t.runAsync(() async {
    final rv = t.binding.renderViews.first;
    final layer = rv.debugLayer! as OffsetLayer;
    final img = await layer.toImage(Offset.zero & rv.size, pixelRatio: 1);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(shotsDir).createSync(recursive: true);
    File('$shotsDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('SHOT $name');
}

Future<void> waitFor(WidgetTester t, Finder f, {int seconds = 25, String? what}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  }
  await shot(t, 'timeout');
  fail('Не дождался: ${what ?? f}');
}

Future<void> waitUntil(WidgetTester t, bool Function() cond, {int seconds = 25, required String what}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (cond()) return;
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  }
  await shot(t, 'timeout');
  fail('Не дождался: $what');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setLoggingLevel(LoggerLevel.kINFO);
  Logger('livekit').onRecord.listen((r) {
    // ignore: avoid_print
    print('LK ${r.level.name} ${r.message}${r.error != null ? ' ERR ${r.error}' : ''}');
  });

  testWidgets('регистрация, чат, сообщение, звонок', (t) async {
    await app.main();
    await waitFor(t, find.text('Winter Chat'), what: 'экран входа');
    await shot(t, '01_login');

    // --- регистрация через интерфейс ---
    await t.tap(find.text('Регистрация'));
    await t.pump(const Duration(milliseconds: 400));
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(6));
    await t.enterText(fields.at(0), server);
    await t.enterText(fields.at(1), 'alice');
    await t.enterText(fields.at(2), 'Алиса');
    await t.enterText(fields.at(3), 'password123');
    await t.enterText(fields.at(4), 'password123');
    await t.enterText(fields.at(5), invite);
    await shot(t, '02_register');
    await t.tap(find.text('Зарегистрироваться'));
    await waitFor(t, find.text('Чатов пока нет'), what: 'главный экран после регистрации');
    await shot(t, '03_home_empty');

    // --- новый личный чат с Бобом ---
    await t.tap(find.text('Новый чат').first);
    await waitFor(t, find.text('Боб'), what: 'Боб в списке людей');
    await shot(t, '04_new_chat');
    await t.tap(find.text('Боб'));
    await waitFor(t, find.text('Напиши первое сообщение 👋'), what: 'пустой чат');

    // --- сообщение ---
    final composer = find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Сообщение'),
    );
    await t.enterText(composer, 'Привет из теста');
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byIcon(Icons.send_rounded));
    await waitFor(t, find.text('Привет из теста'), what: 'отправленное сообщение');
    // Ответ Боба приходит с сервера в реальном времени (его отправляет скрипт).
    await waitFor(t, find.text('Привет, Алиса!'), seconds: 40, what: 'ответ Боба в реальном времени');
    await shot(t, '05_chat');

    // --- звонок ---
    await t.tap(find.byTooltip('Аудиозвонок'));
    await waitUntil(t, () => CallController.I.room != null, seconds: 40, what: 'подключение к звонку (${CallController.I.error})');
    await waitFor(t, find.textContaining('Ждём остальных'), what: 'экран звонка');
    final chatId = CallController.I.chatId!;
    await waitUntil(t, () => Store.I.callParticipants(chatId).isNotEmpty, seconds: 20, what: 'сервер видит участника звонка');
    await shot(t, '06_call');

    await t.tap(find.descendant(of: find.byType(CallScreen), matching: find.byIcon(Icons.call_end)));
    await waitUntil(t, () => !CallController.I.active, what: 'завершение звонка');
    await waitUntil(t, () => Store.I.callParticipants(chatId).isEmpty, seconds: 20, what: 'сервер убрал звонок');
    await shot(t, '07_after_call');
    // ignore: avoid_print
    print('ALL UI CHECKS PASSED');
  });
}
