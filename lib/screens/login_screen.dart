import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _register = false;
  bool _busy = false;
  bool _showPass = false;
  String? _error;

  late final _server = TextEditingController(text: _initialServer());
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  final _invite = TextEditingController();

  static String _initialServer() {
    final s = Api.I.serverUrl;
    return s.replaceFirst('http://', '');
  }

  @override
  void dispose() {
    for (final c in [_server, _username, _name, _password, _password2, _invite]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final server = _server.text.trim();
    final user = _username.text.trim();
    final pass = _password.text;
    String? err;
    if (server.isEmpty) {
      err = 'Введи адрес сервера — его показывает программа-сервер на ноутбуке.';
    } else if (user.isEmpty) {
      err = 'Введи логин';
    } else if (pass.isEmpty) {
      err = 'Введи пароль';
    } else if (_register) {
      if (!RegExp(r'^[a-zA-Z0-9_.\-]{3,24}$').hasMatch(user)) {
        err = 'Логин: 3–24 символа, латинские буквы, цифры, точка, _ и -';
      } else if (pass.length < 8) {
        err = 'Пароль — минимум 8 символов';
      } else if (pass != _password2.text) {
        err = 'Пароли не совпадают';
      } else if (_invite.text.trim().isEmpty) {
        err = 'Нужен код приглашения — он показан на панели сервера';
      }
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        await Api.I.register(server, user, _name.text.trim().isEmpty ? user : _name.text.trim(), pass, _invite.text);
      } else {
        await Api.I.login(server, user, pass);
      }
    } catch (e) {
      if (mounted) setState(() => _error = Api.errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.6, -1.1),
            radius: 1.4,
            colors: [Color(0xFF16264A), W.bg],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Image.asset('assets/icon/icon.png', width: 84, height: 84),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text('Winter Chat', textAlign: TextAlign.center, style: W.h1),
                      const SizedBox(height: 4),
                      const Text('Чаты и звонки для своих', textAlign: TextAlign.center, style: W.small),
                      const SizedBox(height: 24),
                      _tabs(),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _server,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Адрес сервера',
                          hintText: 'например 192.168.1.10:8090',
                          prefixIcon: Icon(Icons.dns_outlined, color: W.muted),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _username,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: 'Логин',
                          prefixIcon: Icon(Icons.alternate_email, color: W.muted),
                        ),
                      ),
                      if (_register) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _name,
                          enabled: !_busy,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Имя (видят друзья)',
                            prefixIcon: Icon(Icons.person_outline, color: W.muted),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_showPass,
                        autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                        onSubmitted: (_) => _register ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: 'Пароль',
                          prefixIcon: const Icon(Icons.lock_outline, color: W.muted),
                          suffixIcon: IconButton(
                            icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility, color: W.muted),
                            onPressed: () => setState(() => _showPass = !_showPass),
                          ),
                        ),
                      ),
                      if (_register) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password2,
                          enabled: !_busy,
                          obscureText: !_showPass,
                          decoration: const InputDecoration(
                            labelText: 'Пароль ещё раз',
                            prefixIcon: Icon(Icons.lock_outline, color: W.muted),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _invite,
                          enabled: !_busy,
                          textCapitalization: TextCapitalization.characters,
                          onSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Код приглашения',
                            hintText: 'например SNOW-1234',
                            prefixIcon: Icon(Icons.key_outlined, color: W.muted),
                          ),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: W.bad.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: W.bad.withValues(alpha: 0.4)),
                          ),
                          child: Text(_error!, style: const TextStyle(color: W.bad)),
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: W.bg))
                            : Text(_register ? 'Зарегистрироваться' : 'Войти'),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Адрес сервера и код приглашения показывает программа Winter Chat Server на компьютере, где она запущена.',
                        textAlign: TextAlign.center,
                        style: W.small,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabs() {
    Widget tab(String text, bool reg) {
      final active = _register == reg;
      return Expanded(
        child: GestureDetector(
          onTap: _busy ? null : () => setState(() {
            _register = reg;
            _error = null;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active ? W.ice : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, color: active ? W.bg : W.muted),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: W.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: W.border),
      ),
      child: Row(children: [tab('Вход', false), tab('Регистрация', true)]),
    );
  }
}
