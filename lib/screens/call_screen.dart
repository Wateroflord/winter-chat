import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api.dart';
import '../call_controller.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/avatar.dart';

/// Одна плитка в звонке: камера или демонстрация экрана участника.
class _Tile {
  _Tile(this.participant, this.screen);
  final Participant participant;
  final bool screen;
  String get key => '${participant.identity}|${screen ? 's' : 'c'}';
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final call = CallController.I;
  Timer? _ticker;
  String? _focused;
  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    call.addListener(_changed);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    call.removeListener(_changed);
    _ticker?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (call.active) _wasActive = true;
    // Звонок закончился — закрываем экран.
    if (_wasActive && !call.active) {
      Navigator.of(context).maybePop();
      return;
    }
    if (call.error != null) {
      final e = call.error!;
      call.error = null;
      toast(context, e);
    }
    setState(() {});
  }

  List<_Tile> _tiles(Room room) {
    final screens = <_Tile>[];
    final cams = <_Tile>[];
    final all = <Participant>[
      if (room.localParticipant != null) room.localParticipant!,
      ...room.remoteParticipants.values,
    ];
    for (final p in all) {
      final hasScreen = p.videoTrackPublications.any((t) => t.source == TrackSource.screenShareVideo);
      if (hasScreen) screens.add(_Tile(p, true));
      cams.add(_Tile(p, false));
    }
    return [...screens, ...cams];
  }

  String _duration() {
    final s = call.startedAt;
    if (s == null) return call.connecting ? 'подключение…' : '';
    final d = DateTime.now().difference(s);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final sec = d.inSeconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    final room = call.room;
    return Scaffold(
      backgroundColor: const Color(0xFF060A14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF060A14),
        leading: IconButton(
          tooltip: 'Свернуть (звонок продолжится)',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(call.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              call.reconnecting ? 'переподключение…' : _duration(),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: call.reconnecting ? W.warn : W.muted),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: room == null
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 14),
                          Text('Подключаюсь к звонку…', style: W.small),
                        ],
                      ),
                    )
                  : _stage(room),
            ),
            _controls(),
          ],
        ),
      ),
    );
  }

  Widget _stage(Room room) {
    final tiles = _tiles(room);
    if (_focused != null && !tiles.any((t) => t.key == _focused)) _focused = null;
    final screenTile = tiles.where((t) => t.screen).firstOrNull;
    final mainKey = _focused ?? screenTile?.key;

    if (tiles.length == 1) {
      return Column(
        children: [
          Expanded(child: Padding(padding: const EdgeInsets.all(8), child: _tile(tiles.first))),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Ждём остальных… Друзья увидят звонок в этом чате.', style: W.small),
          ),
        ],
      );
    }

    if (mainKey != null) {
      final main = tiles.firstWhere((t) => t.key == mainKey);
      final rest = tiles.where((t) => t.key != mainKey).toList();
      return LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > c.maxHeight;
        final strip = wide
            ? SizedBox(
                width: math.min(240, c.maxWidth * 0.25),
                child: ListView(
                  padding: const EdgeInsets.all(6),
                  children: [for (final t in rest) Padding(padding: const EdgeInsets.only(bottom: 6), child: AspectRatio(aspectRatio: 16 / 10, child: _tile(t)))],
                ),
              )
            : SizedBox(
                height: 120,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(6),
                  children: [for (final t in rest) Padding(padding: const EdgeInsets.only(right: 6), child: AspectRatio(aspectRatio: 4 / 3, child: _tile(t)))],
                ),
              );
        final big = Padding(padding: const EdgeInsets.all(6), child: _tile(main, big: true));
        return wide
            ? Row(children: [Expanded(child: big), strip])
            : Column(children: [Expanded(child: big), strip]);
      });
    }

    return LayoutBuilder(builder: (context, c) {
      final n = tiles.length;
      var cols = 1;
      var best = 0.0;
      for (var k = 1; k <= n; k++) {
        final rows = (n / k).ceil();
        final w = (c.maxWidth - 8) / k;
        final h = (c.maxHeight - 8) / rows;
        final size = math.min(w, h * 4 / 3);
        if (size > best) {
          best = size;
          cols = k;
        }
      }
      final rows = (n / cols).ceil();
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            for (var r = 0; r < rows; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var k = 0; k < cols; k++)
                      Expanded(
                        child: r * cols + k < n
                            ? Padding(padding: const EdgeInsets.all(4), child: _tile(tiles[r * cols + k]))
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _tile(_Tile t, {bool big = false}) {
    return GestureDetector(
      onTap: () => setState(() => _focused = _focused == t.key ? null : t.key),
      child: ParticipantTile(key: ValueKey(t.key), participant: t.participant, screen: t.screen, big: big),
    );
  }

  Widget _controls() {
    final connected = call.room != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 10,
        children: [
          _CtrlButton(
            icon: call.micOn ? Icons.mic : Icons.mic_off,
            label: call.micOn ? 'Микрофон' : 'Выключен',
            active: call.micOn,
            onTap: connected ? call.toggleMic : null,
          ),
          _CtrlButton(
            icon: call.camOn ? Icons.videocam : Icons.videocam_off,
            label: 'Камера',
            active: call.camOn,
            onTap: connected ? call.toggleCamera : null,
          ),
          if (!call.isDesktop && call.camOn)
            _CtrlButton(
              icon: Icons.cameraswitch,
              label: 'Повернуть',
              active: false,
              onTap: call.switchCamera,
            ),
          _CtrlButton(
            icon: call.screenOn ? Icons.stop_screen_share : Icons.screen_share,
            label: call.screenOn ? 'Остановить' : 'Экран',
            active: call.screenOn,
            onTap: connected ? () => call.toggleScreenShare(context) : null,
          ),
          _CtrlButton(
            icon: Icons.call_end,
            label: 'Выйти',
            active: false,
            color: W.bad,
            onTap: () => call.leave(),
          ),
        ],
      ),
    );
  }
}

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({required this.icon, required this.label, required this.active, required this.onTap, this.color});
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (active ? W.ice : W.surface3);
    final fg = color != null ? Colors.white : (active ? W.bg : W.text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: onTap == null ? W.surface2 : bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(15), child: Icon(icon, color: onTap == null ? W.muted : fg, size: 26)),
          ),
        ),
        const SizedBox(height: 5),
        Text(label, style: const TextStyle(fontSize: 11.5, color: W.muted)),
      ],
    );
  }
}

/// Видео участника (камера или экран) или аватар, если видео нет.
class ParticipantTile extends StatefulWidget {
  const ParticipantTile({super.key, required this.participant, required this.screen, this.big = false});
  final Participant participant;
  final bool screen;
  final bool big;

  @override
  State<ParticipantTile> createState() => _ParticipantTileState();
}

class _ParticipantTileState extends State<ParticipantTile> {
  @override
  void initState() {
    super.initState();
    widget.participant.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ParticipantTile old) {
    super.didUpdateWidget(old);
    if (old.participant != widget.participant) {
      old.participant.removeListener(_changed);
      widget.participant.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.participant.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  VideoTrack? get _track {
    final source = widget.screen ? TrackSource.screenShareVideo : TrackSource.camera;
    for (final pub in widget.participant.videoTrackPublications) {
      if (pub.source != source) continue;
      if (pub.muted) return null;
      final t = pub.track;
      if (t is VideoTrack) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.participant;
    final identity = p.identity;
    final known = Api.I.users.containsKey(identity);
    final name = known ? Api.I.nameOf(identity) : (p.name.isNotEmpty ? p.name : identity);
    final track = _track;
    final speaking = p.isSpeaking && !widget.screen;
    final isLocal = p is LocalParticipant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: W.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: speaking ? W.good : W.border, width: speaking ? 3 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            VideoTrackRenderer(
              track,
              fit: widget.screen ? VideoViewFit.contain : VideoViewFit.cover,
              mirrorMode: isLocal && !widget.screen ? VideoViewMirrorMode.mirror : VideoViewMirrorMode.off,
            )
          else
            Center(
              child: LayoutBuilder(builder: (context, c) {
                final size = math.max(36.0, math.min(110.0, math.min(c.maxWidth, c.maxHeight) * 0.42));
                return known
                    ? UserAvatar(identity, size: size)
                    : LetterAvatar(name: name, seed: identity, size: size);
              }),
            ),
          Positioned(
            left: 8,
            bottom: 8,
            right: 8,
            child: Row(
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.screen) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.screen_share, size: 14, color: W.ice)),
                        if (!widget.screen && !p.isMicrophoneEnabled())
                          const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.mic_off, size: 14, color: W.bad)),
                        Flexible(
                          child: Text(
                            widget.screen ? 'Экран: $name' : (isLocal ? '$name (ты)' : name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
