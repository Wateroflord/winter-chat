import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../call_controller.dart';
import '../main.dart' show buildNumber;
import '../theme.dart';
import '../widgets/avatar.dart';

Future<void> showProfile(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ProfileSheet(),
  );
}

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet();

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  late final _name = TextEditingController(text: Api.I.nameOf(Api.I.myId));
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save({List<http.MultipartFile> files = const []}) async {
    setState(() => _busy = true);
    try {
      final r = await Api.I.pb.collection('users').update(
            Api.I.myId,
            body: {'name': _name.text.trim()},
            files: files,
          );
      Api.I.users[r.id] = r;
      Api.I.pb.authStore.save(Api.I.pb.authStore.token, r);
      if (mounted) toast(context, 'Сохранено');
    } catch (e) {
      if (mounted) toast(context, Api.errorText(e, fallback: 'Не удалось сохранить'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickAvatar() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    final f = res?.files.firstOrNull;
    if (f == null) return;
    final mp = f.path != null
        ? await http.MultipartFile.fromPath('avatar', f.path!, filename: f.name)
        : http.MultipartFile.fromBytes('avatar', f.bytes!, filename: f.name);
    await _save(files: [mp]);
  }

  Future<void> _logout() async {
    await CallController.I.leave();
    await Api.I.logout();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final api = Api.I;
    final me = api.users[api.myId] ?? api.me;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: W.border, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 16),
              Stack(
                children: [
                  UserAvatar(api.myId, size: 92),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: W.ice,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _busy ? null : _pickAvatar,
                        child: const Padding(padding: EdgeInsets.all(7), child: Icon(Icons.photo_camera, size: 18, color: W.bg)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('@${me.getStringValue('username')}', style: W.small),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Имя'),
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? null : () => _save(),
                    icon: const Icon(Icons.check),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined, color: W.muted),
                title: const Text('Сервер'),
                subtitle: Text(api.serverUrl, style: W.small),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout, color: W.bad),
                title: const Text('Выйти из аккаунта', style: TextStyle(color: W.bad)),
                onTap: _busy ? null : _logout,
              ),
              const SizedBox(height: 4),
              Text('Winter Chat · сборка $buildNumber', style: W.small),
            ],
          ),
        ),
      ),
    );
  }
}
