// 首启引导页：输入服务器地址 → /api/health 探测通过后保存
import 'package:flutter/material.dart';

import '../core/api.dart';

class BootstrapPage extends StatefulWidget {
  const BootstrapPage({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<BootstrapPage> createState() => _BootstrapPageState();
}

class _BootstrapPageState extends State<BootstrapPage> {
  final _controller = TextEditingController(text: 'http://');
  bool busy = false;
  String? error;

  Future<void> _connect() async {
    var addr = _controller.text.trim();
    if (addr.isEmpty) {
      setState(() => error = '请输入服务器地址');
      return;
    }
    if (!addr.startsWith('http://') && !addr.startsWith('https://')) {
      addr = 'http://$addr';
    }
    // 免端口输入：无冒号时默认 8322（MyNotes 标准端口）
    final hostPart = addr.replaceFirst(RegExp('^https?://'), '');
    if (!hostPart.contains(':')) addr = '$addr:8322';
    _controller.text = addr;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.health(addr);
      await api.saveConfig(addr);
      widget.onDone();
    } catch (e) {
      setState(() {
        busy = false;
        error = '连接失败：${e is ApiError ? e.message : '网络错误'}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.bookmark_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                Text('MyNotes', textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('自托管个人笔记', textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).hintColor)),
                const SizedBox(height: 32),
                TextField(
                  controller: _controller,
                  enabled: !busy,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'http://NAS-IP:8322',
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: busy ? null : _connect,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: busy
                        ? const SizedBox(height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('连接'),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13),
                      textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
