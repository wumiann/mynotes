// 设置页：主题/账号安全/数据统计
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? stats;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStats());
  }

  Future<void> _loadStats() async {
    try {
      stats = await api.getStats();
      setState(() {});
    } catch (_) {}
  }

  Future<void> _setTheme(String mode) async {
    store.settings = AppSettings(
      themeMode: mode,
      cardLock: store.settings.cardLock,
      cardEncrypt: store.settings.cardEncrypt,
      trashRetentionDays: store.settings.trashRetentionDays,
    );
    store.notifyListeners();
    try {
      await api.updateSettings(store.settings.toJson());
    } catch (_) {}
  }

  Future<void> _logoutOthers() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('登出其他设备'),
        content: const Text('除本机外的所有会话将被注销（含 Web 浏览器）。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('登出')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.logoutOthers();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('其他设备已登出')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final mode = store.settings.themeMode;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section(p, '主题'),
          _card(p, Column(
            children: [
              RadioListTile<String>(
                value: 'system',
                groupValue: mode,
                dense: true,
                title: const Text('跟随系统', style: TextStyle(fontSize: 14)),
                onChanged: (v) => _setTheme(v!),
              ),
              RadioListTile<String>(
                value: 'light',
                groupValue: mode,
                dense: true,
                title: const Text('浅色', style: TextStyle(fontSize: 14)),
                onChanged: (v) => _setTheme(v!),
              ),
              RadioListTile<String>(
                value: 'dark',
                groupValue: mode,
                dense: true,
                title: const Text('深色', style: TextStyle(fontSize: 14)),
                onChanged: (v) => _setTheme(v!),
              ),
            ],
          )),
          _section(p, '账号'),
          _card(p, Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_outline, size: 20),
                title: Text(api.username ?? '', style: const TextStyle(fontSize: 14)),
                subtitle: const Text('当前账号', style: TextStyle(fontSize: 11.5)),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.devices_other, size: 20),
                title: const Text('登出其他设备', style: TextStyle(fontSize: 14)),
                onTap: _logoutOthers,
              ),
            ],
          )),
          _section(p, '数据'),
          _card(p, stats == null
              ? const Padding(padding: EdgeInsets.all(14), child: Text('统计加载中…（需联网）', style: TextStyle(fontSize: 13)))
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _statRow(p, '笔记', '${stats!['notes'] ?? '?'} 条'),
                      _statRow(p, '分组', '${stats!['groups'] ?? '?'} 个'),
                      _statRow(p, '标签', '${stats!['tags'] ?? '?'} 个'),
                      _statRow(p, '附件', '${stats!['attachments'] ?? '?'} 个'),
                    ],
                  ),
                )),
          _section(p, '关于'),
          _card(p, const ListTile(
            dense: true,
            leading: Icon(Icons.info_outline, size: 20),
            title: Text('MyNotes Flutter', style: TextStyle(fontSize: 14)),
            subtitle: Text('自托管个人笔记 · 与 Web 版数据互通', style: TextStyle(fontSize: 11.5)),
          )),
        ],
      ),
    );
  }

  Widget _section(Palette p, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
        child: Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.muted)),
      );

  Widget _card(Palette p, Widget child) => Container(
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.border),
        ),
        child: child,
      );

  Widget _statRow(Palette p, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 70, child: Text(k, style: TextStyle(fontSize: 13, color: p.muted))),
            Text(v, style: TextStyle(fontSize: 13, color: p.text)),
          ],
        ),
      );
}
