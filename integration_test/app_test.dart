// Проверка приложения на настоящем сервере: регистрация, чат, сообщение, звонок.
// Запускается в GitHub Actions (screens.yml) на Linux с виртуальным экраном.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' show setLoggingLevel, LoggerLevel;
import 'package:logging/logging.dart';
import 'package:winter_chat/api.dart';
import 'package:winter_chat/call_controller.dart';
import 'package:winter_chat/main.dart' as app;
import 'package:winter_chat/outbox.dart';
import 'package:winter_chat/screens/appearance_screen.dart';
import 'package:winter_chat/screens/call_screen.dart';
import 'package:winter_chat/screens/chat_screen.dart';
import 'package:winter_chat/screens/profile_sheet.dart';
import 'package:winter_chat/screens/search_screen.dart';
import 'package:winter_chat/settings.dart';
import 'package:winter_chat/store.dart';
import 'package:winter_chat/theme.dart';
import 'package:winter_chat/widgets/chat_background.dart';
import 'package:winter_chat/widgets/sticker_panel.dart';

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

/// Ждать, но без провала теста (для того, что зависит от интернета).
Future<bool> softWait(WidgetTester t, Finder f, {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return true;
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  }
  return false;
}

/// Всплывающие подсказки внизу закрывают поле ввода — ждём, пока уйдут.
Future<void> noToast(WidgetTester t) async {
  ScaffoldMessenger.maybeOf(t.element(find.byType(Scaffold).first))?.clearSnackBars();
  await waitUntil(t, () => find.byType(SnackBar).evaluate().isEmpty, seconds: 10, what: 'подсказка внизу закрылась');
  await t.pump(const Duration(milliseconds: 300));
}

/// Всё из очереди отправки ушло на сервер.
Future<void> allSent(WidgetTester t) => waitUntil(t, () => Outbox.I.items.isEmpty, what: 'отправка сообщения (${Outbox.I.items.map((i) => i.error).join(', ')})');

/// Картинка для стикера (рисуем прямо в тесте).
Future<Uint8List> stickerPng() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawCircle(const Offset(64, 64), 58, Paint()..color = const Color(0xFF5B9DFF));
  c.drawCircle(const Offset(64, 64), 30, Paint()..color = const Color(0xFFFFFFFF));
  final img = await rec.endRecording().toImage(128, 128);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Долгое нажатие на сообщение, пока не откроется меню (с диагностикой).
Future<void> openMenu(WidgetTester t, Finder target, String name) async {
  for (var attempt = 1; attempt <= 4; attempt++) {
    await t.longPress(target);
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
      if (find.text('Ответить').evaluate().isNotEmpty) {
        // ignore: avoid_print
        print('MENU $name: попытка $attempt');
        return;
      }
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    }
  }
  await shot(t, 'timeout');
  fail('Не открылось меню сообщения: $name');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Когда открывается меню, навигатор отменяет касание, которое ещё держит палец.
  // На телефоне эта отмена приходит сама, а в тесте её надо пропускать явно —
  // иначе долгое нажатие на это сообщение «залипает».
  binding.shouldPropagateDevicePointerEvents = true;
  hierarchicalLoggingEnabled = true;
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

    // --- ✓✓ прочитано, реакция и «печатает…» от Боба (скрипт на сервере) ---
    await waitFor(t, find.text('🔥 1'), seconds: 30, what: 'реакция Боба 🔥');
    await waitFor(t, find.byIcon(Icons.done_all), seconds: 30, what: '✓✓ — Боб прочитал');
    await waitFor(t, find.text('печатает…'), seconds: 30, what: '«печатает…» от Боба');
    // Боб позвал меня: упоминание подсвечено, **это** — жирным.
    await waitFor(t, find.text('@alice ты тут? Глянь это'), seconds: 30, what: 'упоминание от Боба');
    await shot(t, '05a_read_typing');

    // --- своя реакция и ответ с цитатой ---
    Finder inChat(String text) => find.descendant(of: find.byType(ChatScreen), matching: find.text(text));
    await openMenu(t, inChat('Привет, Алиса!'), 'первое');
    await shot(t, '05b_menu');
    await t.tap(find.text('👍').last);
    await waitFor(t, find.text('👍 1'), what: 'моя реакция 👍');
    // Меню закрывается с анимацией — ждём, пока оно уйдёт совсем.
    await waitUntil(t, () => find.byType(BottomSheet).evaluate().isEmpty, what: 'меню закрылось');
    await t.pump(const Duration(milliseconds: 400));
    await openMenu(t, inChat('Привет, Алиса!'), 'второе');
    await t.tap(find.text('Ответить'));
    await waitUntil(t, () => find.byType(BottomSheet).evaluate().isEmpty, what: 'меню закрылось');
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(composer, 'Отвечаю с цитатой');
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byIcon(Icons.send_rounded));
    await waitFor(t, find.text('Отвечаю с цитатой'), what: 'ответ с цитатой');
    await allSent(t);
    await t.pump(const Duration(milliseconds: 400));
    // Цитата: имя автора и текст исходного сообщения внутри ответа.
    expect(inChat('Привет, Алиса!'), findsAtLeastNWidgets(2));

    // --- закрепить ---
    // На ПК меню открывается правой кнопкой мыши.
    await t.tap(inChat('Привет из теста'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await waitFor(t, find.text('Закрепить'), what: 'меню по правой кнопке: закрепить');
    await shot(t, '05c_context_menu');
    await t.tap(find.text('Закрепить'));
    await waitUntil(t, () => (Store.I.chat(t.widget<ChatScreen>(find.byType(ChatScreen)).chatId)?.getListValue<String>('pins') ?? const []).isNotEmpty,
        what: 'сервер сохранил закреп');
    await t.pump(const Duration(milliseconds: 500));
    await shot(t, '05d_reply_pin');

    // --- поиск ---
    final cid = t.widget<ChatScreen>(find.byType(ChatScreen)).chatId;
    app.navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => SearchScreen(chatId: cid)));
    final searchField = find.descendant(of: find.byType(SearchScreen), matching: find.byType(TextField));
    await waitFor(t, searchField, what: 'экран поиска');
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(searchField, 'цитат');
    await waitFor(t, find.descendant(of: find.byType(SearchScreen), matching: find.byType(ListTile)), what: 'результат поиска');
    await shot(t, '05e_search');
    app.navigatorKey.currentState!.pop();
    await t.pump(const Duration(milliseconds: 500));

    // --- оформление текста ---
    await noToast(t);
    await t.enterText(composer, '**Жирный**, _курсив_ и ||спойлер|| для @bob');
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byIcon(Icons.send_rounded));
    await allSent(t);
    await waitFor(t, find.text('Жирный, курсив и спойлер для @bob'), what: 'сообщение с оформлением');

    // --- опрос ---
    await noToast(t);
    await t.tap(find.byTooltip('Прикрепить'));
    await waitFor(t, find.text('Опрос'), what: 'меню вложений');
    await t.tap(find.text('Опрос'));
    await waitFor(t, find.text('Новый опрос'), what: 'окно опроса');
    final pf = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await t.enterText(pf.at(0), 'Во сколько играем?');
    await t.enterText(pf.at(1), '19:00');
    await t.enterText(pf.at(2), '20:00');
    await t.tap(find.text('Отправить'));
    await allSent(t);
    await waitFor(t, find.text('20:00'), what: 'опрос в чате');
    await t.tap(find.text('20:00'));
    await waitFor(t, find.text('100% · 1'), what: 'голос в опросе');
    await shot(t, '05f_format_poll');

    // --- превью ссылки (сервер сам ходит на сайт — нужен интернет) ---
    await t.enterText(composer, 'Глянь https://example.com');
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byIcon(Icons.send_rounded));
    await allSent(t);
    if (await softWait(t, find.text('Example Domain'), seconds: 25)) {
      await shot(t, '05g_link_preview');
    } else {
      // ignore: avoid_print
      print('WARN превью ссылки не пришло (нет интернета у сервера?)');
    }

    // --- свой стикер и вкладка GIF ---
    final png = await t.runAsync(stickerPng);
    await t.runAsync(() => StickerStore.I.upload(pack: 'Снежинки', name: 'snow.png', bytes: png!));
    await noToast(t);
    await t.tap(find.byTooltip('Стикеры и GIF'));
    final stickerImg = find.descendant(of: find.byType(StickerPanel), matching: find.byType(Image));
    await waitFor(t, stickerImg, what: 'стикер в панели');
    await t.tap(stickerImg.first);
    await allSent(t);
    await t.tap(find.text('GIF'));
    await waitFor(t, find.textContaining('Поиск GIF на сервере выключен'), what: 'вкладка GIF без ключа');
    await shot(t, '05h_stickers');
    await t.tap(find.byTooltip('Стикеры и GIF'));
    await t.pump(const Duration(milliseconds: 300));

    // --- группа с каналами, пересылка, напоминание ---
    final bobId = Api.I.users.keys.firstWhere((id) => id != Api.I.myId);
    final group = await t.runAsync(() => Store.I.createGroup('Банда', [bobId]));
    final members = group!.getListValue<String>('members');
    final games = await t.runAsync(() => Api.I.pb.collection('chats').create(body: {'name': 'игры', 'is_group': true, 'parent': group.id, 'members': members}));
    final voiceCh = await t.runAsync(() => Api.I.pb.collection('chats').create(body: {'name': 'Катка', 'is_group': true, 'parent': group.id, 'kind': 'voice', 'members': members}));
    Store.I.replaceChat(games!);
    Store.I.replaceChat(voiceCh!);
    await noToast(t);
    await openMenu(t, inChat('Привет, Алиса!'), 'переслать');
    await t.tap(find.text('Переслать'));
    await waitFor(t, find.text('Банда › #игры'), what: 'канал в списке пересылки');
    await t.tap(find.text('Банда › #игры'));
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.text('Отправить'));
    await waitFor(t, find.text('Переслано ✓'), what: 'пересылка');
    app.navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: group.id)));
    await waitFor(t, find.text('общий'), what: 'полоска каналов');
    await t.tap(find.text('игры'));
    await waitFor(t, find.textContaining('Переслано от'), what: 'пересланное в канале');
    await t.runAsync(() => Api.I.pb.collection('scheduled').create(body: {
          'chat': games.id,
          'text': 'Катка в 20:00 — заходите!',
          'at': DateTime.now().add(const Duration(seconds: 2)).toUtc().toIso8601String(),
          'remind': true,
        }));
    await waitFor(t, find.text('⏰ Напоминание'), seconds: 40, what: 'напоминание от сервера');
    await shot(t, '05i_channels_forward_remind');
    app.navigatorKey.currentState!.pop();
    await t.pump(const Duration(milliseconds: 600));

    // --- звонок ---
    await t.tap(find.byTooltip('Аудиозвонок'));
    await waitUntil(t, () => CallController.I.room != null, seconds: 40, what: 'подключение к звонку (${CallController.I.error})');
    await waitFor(t, find.textContaining('Ждём остальных'), what: 'экран звонка');
    final chatId = CallController.I.chatId!;
    await waitUntil(t, () => Store.I.callParticipants(chatId).isNotEmpty, seconds: 20, what: 'сервер видит участника звонка');
    await shot(t, '06_call');

    // --- рация и саундборд ---
    await t.tap(find.text('Рация'));
    await waitUntil(t, () => Settings.I.pttEnabled && !CallController.I.micOn, what: 'рация: микрофон молчит');
    await waitFor(t, find.textContaining('Держи'), what: 'кнопка рации');
    await shot(t, '06a_ptt');
    await t.tap(find.text('Звуки'));
    await waitFor(t, find.text('Саундборд'), what: 'панель саундборда');
    await t.pump(const Duration(milliseconds: 600));
    await shot(t, '06b_soundboard');
    app.navigatorKey.currentState!.pop();
    await t.pump(const Duration(milliseconds: 400));
    await CallController.I.setPtt(false);
    await t.pump(const Duration(milliseconds: 300));

    await t.tap(find.descendant(of: find.byType(CallScreen), matching: find.byIcon(Icons.call_end)));
    await waitUntil(t, () => !CallController.I.active, what: 'завершение звонка');
    await waitUntil(t, () => Store.I.callParticipants(chatId).isEmpty, seconds: 20, what: 'сервер убрал звонок');
    await shot(t, '07_after_call');

    // --- профиль друга (статус и цвет Боба выставил скрипт на сервере) ---
    await waitUntil(t, () => Api.I.statusText(Api.I.users.keys.firstWhere((id) => id != Api.I.myId, orElse: () => '')).isNotEmpty,
        seconds: 20, what: 'статус Боба');
    await t.tap(find.text('Боб').last);
    await waitFor(t, find.text('Написать'), what: 'карточка профиля');
    await shot(t, '08_profile');
    app.navigatorKey.currentState!.pop();
    await t.pump(const Duration(milliseconds: 500));

    // --- оформление: светлая тема, круглые пузыри, свой градиент ---
    final s = Settings.I;
    s.palette = paletteById('light');
    s.accent = const Color(0xFF5B9DFF);
    s.bubbleStyle = 1;
    s.wallpaper = Wallpaper.gradient(0xFFDCEBFA, 0xFFF4E9F2, angle: 1, pattern: false);
    await t.pump(const Duration(milliseconds: 600));
    await shot(t, '09_light_theme');

    // --- «как в Discord»: список, тёмная «Полночь», квадратные аватары ---
    s.palette = paletteById('midnight');
    s.accent = const Color(0xFFBE8CFF);
    s.bubbleStyle = 3;
    s.squareAvatars = true;
    s.wallpaper = const Wallpaper.preset(4);
    await t.pump(const Duration(milliseconds: 600));
    await shot(t, '10_list_style');

    app.navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const AppearanceScreen()));
    await waitFor(t, find.text('ТЕМА'), what: 'экран оформления');
    await shot(t, '11_appearance');
    app.navigatorKey.currentState!.pop();
    app.navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
    await waitFor(t, find.text('Сохранить профиль'), what: 'редактор профиля');
    await shot(t, '12_profile_edit');
    app.navigatorKey.currentState!.pop();
    await s.resetAppearance();
    await t.pump(const Duration(milliseconds: 600));
    // ignore: avoid_print
    print('ALL UI CHECKS PASSED');
  });
}
