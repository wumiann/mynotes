// 登录/首建账号页：零知识派生（PBKDF2 600k，转圈期间不阻塞提示）
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/crypto.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onLoggedIn});
  final VoidCallback onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool busy = false;
  String? error;
  bool _needSetup = false; // 服务器无账号 → 切换为创建账号
  Map<String, dynamic>? _pendingSalts; // setup 时本地生成

  Future<void> _submit() async {
    final username = _user.text.trim();
    final password = _pass.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => error = '请输入用户名和密码');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (_needSetup) {
        // 创建账号：本地生成两个盐，authKey 发给服务器
        final salt1 = _randomHex(16);
        final salt2 = _randomHex(16);
        final authKey = await Vault.instance.deriveHex(password, salt1);
        await api.setup({
          'username': username,
          'authKey': authKey,
          'kdfSalt1': salt1,
          'kdfSalt2': salt2,
        });
      }
      final salts = await api.getSalts(username);
      final authKey = await Vault.instance.deriveHex(password, salts['kdfSalt1'] as String);
      final res = await api.login(username, authKey);
      await api.saveAuth(res['token'] as String? ?? '', username);
      widget.onLoggedIn();
    } on ApiError catch (e) {
      // 404 = 无账号 → 转创建模式
      if (e.status == 404 && !_needSetup) {
        setState(() {
          _needSetup = true;
          busy = false;
          error = null;
        });
        return;
      }
      setState(() {
        busy = false;
        error = e.message;
      });
    } catch (e) {
      setState(() {
        busy = false;
        error = '登录失败：$e';
      });
    }
  }

  String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_needSetup ? '创建账号' : '登录')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _user,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '用户名', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _pass,
                  enabled: !busy,
                  obscureText: true,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: '密码', prefixIcon: Icon(Icons.lock_outline)),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: busy
                        ? const Column(children: [
                            SizedBox(height: 18, width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                            SizedBox(height: 6),
                            Text('密钥派生中…', style: TextStyle(fontSize: 12)),
                          ])
                        : Text(_needSetup ? '创建并登录' : '登录'),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
