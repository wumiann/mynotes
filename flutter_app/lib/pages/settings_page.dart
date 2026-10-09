// 设置页：同步/主题/账号/数据统计/关于
// 同步区 = 本地优先改造的核心入口：未配置可进向导，已配置可立即同步/换服务器/断开
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/sync.dart';
import 'login_page.dart';
import 'sync_setup_page.dart';

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
    if (!store.authed) return; // 未登录：统计需联网，显示占位
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

  /// 立即同步（带结果提示）
  Future<void> _syncNow() async {
    setState(() => busy = true);
    try {
      final r = await syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r == null
                ? '同步被跳过'
                : r.hasActivity
                    ? '同步完成：上传 ${r.pushed} 条，新拉取 ${r.pulledNew} 条，差异合并 ${r.mergedDiffs} 处'
                    : '已是最新')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('同步失败：$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 断开同步 = 登出（本地数据与队列保留）
  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开同步'),
        content: const Text('将登出当前账号，但本机数据全部保留，'
            '未推送的变更也会保留，重新登录同一账号后继续同步。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('断开')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.logout();
    } catch (_) {}
    lockVault();
    store.authed = false;
    store.notifyListeners();
    if (mounted) setState(() {}); // 刷新同步区为「未登录」态
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
          _section(p, '同步'),
          _card(p, _syncSection(p)),
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
          if (store.authed) ...[
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
          ],
          _section(p, '数据'),
          _card(p, stats == null
              ? Padding(padding: const EdgeInsets.all(14), child: Text(
                  store.authed ? '统计加载中…（需联网）' : '配置同步后可查看服务器统计',
                  style: const TextStyle(fontSize: 13)))
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

  // ---------- 同步区 ----------
  Widget _syncSection(Palette p) {
    // 三种状态：未配置 / 已配置未登录 / 已登录
    if (!api.hasServer) {
      return ListTile(
        dense: true,
        leading: Icon(Icons.cloud_off_outlined, size: 20, color: p.muted),
        title: const Text('未配置同步', style: TextStyle(fontSize: 14)),
        subtitle: const Text('笔记仅保存在本机，配置后可与 Web 版互通', style: TextStyle(fontSize: 11.5)),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => Navigator.of(context).push(fadeUpRoute(const SyncSetupPage())),
      );
    }
    if (!store.authed) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.cloud_outlined, size: 20),
        title: const Text('服务器已配置，未登录', style: TextStyle(fontSize: 14)),
        subtitle: Text(api.baseUrl ?? '', style: TextStyle(fontSize: 11.5), maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => Navigator.of(context).push(fadeUpRoute(LoginPage(onLoggedIn: () {
          store.authed = true;
          releaseSync();
          store.notifyListeners();
          setState(() {}); // 刷新同步区/账号区
          _loadStats();
        }))),
      );
    }
    final lastSync = syncState.lastSync.isEmpty ? '从未' : syncState.lastSync.replaceAll('T', ' ').substring(0, 16);
    return Column(children: [
      ListTile(
        dense: true,
        leading: const Icon(Icons.cloud_done_outlined, size: 20),
        title: const Text('已连接', style: TextStyle(fontSize: 14)),
        subtitle: Text('${api.baseUrl ?? ''} · ${api.username ?? ''}\n上次同步：$lastSync',
            style: const TextStyle(fontSize: 11.5), maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      ListTile(
        dense: true,
        leading: Icon(Icons.sync, size: 20, color: busy ? p.primary : p.muted),
        title: const Text('立即同步', style: TextStyle(fontSize: 14)),
        subtitle: syncState.pending > 0 ? Text('${syncState.pending} 条待同步', style: const TextStyle(fontSize: 11.5)) : null,
        onTap: busy ? null : _syncNow,
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.swap_horiz, size: 20),
        title: const Text('更换服务器', style: TextStyle(fontSize: 14)),
        subtitle: const Text('重新配置地址并选择合并策略', style: TextStyle(fontSize: 11.5)),
        onTap: () => Navigator.of(context).push(fadeUpRoute(const SyncSetupPage())),
      ),
      ListTile(
        dense: true,
        leading: Icon(Icons.link_off, size: 20, color: p.danger),
        title: Text('断开同步', style: TextStyle(fontSize: 14, color: p.danger)),
        onTap: _disconnect,
      ),
    ]);
  }

  Widget _section(Palette p, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
        child: Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.muted)),
      );

  Widget _card(Palette p, Widget child) => Container(
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(AppDimens.rCard),
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
