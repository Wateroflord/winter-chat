import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import 'api.dart';

/// Один активный звонок на всё приложение.
class CallController extends ChangeNotifier {
  CallController._();
  static final CallController I = CallController._();

  Room? room;
  EventsListener<RoomEvent>? _listener;
  String? chatId;
  String title = '';
  bool connecting = false;
  bool reconnecting = false;
  String? error;
  DateTime? startedAt;
  CameraPosition cameraPosition = CameraPosition.front;

  bool get active => room != null || connecting;

  LocalParticipant? get local => room?.localParticipant;
  bool get micOn => local?.isMicrophoneEnabled() ?? false;
  bool get camOn => local?.isCameraEnabled() ?? false;
  bool get screenOn => local?.isScreenShareEnabled() ?? false;

  bool get isAndroid => !kIsWeb && Platform.isAndroid;
  bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> join(String chatId, String title, {bool withCamera = false}) async {
    if (this.chatId == chatId && room != null) return;
    if (active) await leave();
    this.chatId = chatId;
    this.title = title;
    connecting = true;
    error = null;
    notifyListeners();
    Room? r;
    try {
      final t = await Api.I.callToken(chatId);
      r = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: AudioCaptureOptions(
            noiseSuppression: true,
            echoCancellation: true,
            autoGainControl: true,
          ),
          defaultCameraCaptureOptions: CameraCaptureOptions(
            params: VideoParametersPresets.h720_169,
          ),
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
            params: VideoParametersPresets.screenShareH1080FPS15,
          ),
          defaultVideoPublishOptions: VideoPublishOptions(simulcast: true),
        ),
      );
      final l = r.createListener();
      l
        ..on<RoomDisconnectedEvent>((_) {
          if (room != null && room == r) _cleanup();
        })
        ..on<RoomReconnectingEvent>((_) {
          reconnecting = true;
          notifyListeners();
        })
        ..on<RoomReconnectedEvent>((_) {
          reconnecting = false;
          notifyListeners();
        })
        ..on<RoomEvent>((_) => notifyListeners());
      r.addListener(notifyListeners);

      await r.connect(t.url, t.token, connectOptions: const ConnectOptions(autoSubscribe: true)).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw 'Звонок не подключился за 30 секунд. Проверь интернет и что на сервере открыты порты 7881 (TCP) и 7882 (UDP).',
      );
      room = r;
      _listener = l;
      startedAt = DateTime.now();
      connecting = false;
      notifyListeners();

      if (isAndroid) {
        try {
          await AudioManager.instance.setSpeakerOutputPreferred(true);
        } catch (_) {}
      }
      try {
        await r.localParticipant?.setMicrophoneEnabled(true).timeout(const Duration(seconds: 10));
      } catch (e) {
        error = 'Микрофон недоступен: $e';
      }
      if (withCamera) {
        await toggleCamera();
      }
      notifyListeners();
    } catch (e) {
      connecting = false;
      error = e is String ? e : 'Не удалось подключиться к звонку: $e';
      if (r != null) {
        r.removeListener(notifyListeners);
        unawaited(r.dispose().catchError((_) {}));
      }
      room = null;
      this.chatId = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> leave() async {
    final r = room;
    if (r == null) {
      _cleanup();
      return;
    }
    try {
      if (screenOn) await _stopScreenShare();
    } catch (_) {}
    try {
      await r.disconnect();
    } catch (_) {}
    _cleanup();
  }

  void _cleanup() {
    final r = room;
    room = null;
    chatId = null;
    connecting = false;
    reconnecting = false;
    startedAt = null;
    r?.removeListener(notifyListeners);
    unawaited(_listener?.dispose());
    _listener = null;
    if (r != null) unawaited(r.dispose());
    if (isAndroid) unawaited(_stopBackground());
    notifyListeners();
  }

  Future<void> toggleMic() async {
    await local?.setMicrophoneEnabled(!micOn);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    try {
      await local?.setCameraEnabled(
        !camOn,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: cameraPosition,
          params: VideoParametersPresets.h720_169,
        ),
      );
    } catch (e) {
      error = 'Камера недоступна: $e';
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final pub = local?.videoTrackPublications.where((p) => p.source == TrackSource.camera).firstOrNull;
    final track = pub?.track;
    if (track == null) return;
    cameraPosition = cameraPosition.switched();
    try {
      await track.setCameraPosition(cameraPosition);
    } catch (_) {}
    notifyListeners();
  }

  /// Демонстрация экрана. На ПК сначала нужно выбрать экран или окно.
  Future<void> toggleScreenShare(BuildContext context) async {
    if (screenOn) {
      await _stopScreenShare();
      notifyListeners();
      return;
    }
    final p = local;
    if (p == null) return;
    try {
      if (isDesktop) {
        final source = await showDialog<rtc.DesktopCapturerSource>(
          context: context,
          builder: (_) => ScreenSelectDialog(
            titleText: 'Что показать?',
            screenTabText: 'Весь экран',
            windowTabText: 'Окно',
            cancelText: 'Отмена',
            shareText: 'Показать',
          ),
        );
        if (source == null) return;
        final track = await LocalVideoTrack.createScreenShareTrack(
          ScreenShareCaptureOptions(
            sourceId: source.id,
            maxFrameRate: 15.0,
            params: VideoParametersPresets.screenShareH1080FPS15,
          ),
        );
        await p.publishVideoTrack(track);
      } else if (isAndroid) {
        final ok = await rtc.Helper.requestCapturePermission();
        if (!ok) return;
        await _startBackground();
        await p.setScreenShareEnabled(true, captureScreenAudio: true);
      } else {
        await p.setScreenShareEnabled(true);
      }
    } catch (e) {
      error = 'Не удалось показать экран: $e';
    }
    notifyListeners();
  }

  Future<void> _stopScreenShare() async {
    await local?.setScreenShareEnabled(false);
    if (isAndroid) await _stopBackground();
  }

  Future<void> _startBackground() async {
    try {
      const config = FlutterBackgroundAndroidConfig(
        notificationTitle: 'Winter Chat',
        notificationText: 'Идёт демонстрация экрана',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      );
      var ok = await FlutterBackground.initialize(androidConfig: config);
      if (!ok) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        ok = await FlutterBackground.initialize(androidConfig: config);
      }
      if (ok && !FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.enableBackgroundExecution();
      }
    } catch (_) {}
  }

  Future<void> _stopBackground() async {
    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
      }
    } catch (_) {}
  }
}
