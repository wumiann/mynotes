// 同步配置向导：地址探活 → 登录/注册 → 首次同步策略 → 执行结果
// 本地优先改造后，这是配置/更换同步服务器的唯一入口（原首启引导页已并入）
// 进入即挂起自动同步（holdSync）：登录成功但策略未选时，绝不自动合并/全量拉取
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/store.dart';
import '../core/sync.dart';
import 'login_page.dart';

class SyncSetupPage extends StatefulWidget {
  const SyncSetupPage({super.key});

  @override
  State<SyncSetupPage> createState() => _SyncSetupPageState();
}

class _SyncSetupPageState extends State<SyncSetupPage> {
  int _step = 0; // 0 地址 / 1 登录 / 2 策略 / 3 执行结果
  final _addr = TextEditingController();
  bool busy = false;
  String? error;
  SyncPullMode _mode = SyncPullMode.merge;
  SyncResult? _result;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    holdSync(); // 策略未定前挂起一切自动同步
    _addr.text = api.baseUrl ?? 'http://';
  }

  @override
  void dispose() {
    // 中途放弃：恢复常规同步（已登录才有意义；未登录保持挂起）
    if (!_completed && api.configured && store.authed) {
      releaseSync();
      bootSync();
    }
    _addr.dispose();
    super.dispose();
  }

  void _popToRoot() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---------- step 0：地址 ----------
  Future<void> _connect() async {
    var addr = _addr.text.trim();
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
    _addr.text = addr;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.health(addr);
      await api.saveConfig(addr);
      // 更换服务器场景：旧令牌一并作废，重新登录
      if (!store.authed) await api.clearAuth();
      setState(() {
        busy = false;
        _step = 1;
      });
    } catch (e) {
      setState(() {
        busy = false;
        error = '连接失败：${e is ApiError ? e.message : '网络错误'}';
      });
    }
  }

  // ---------- step 2/3：策略与执行 ----------
  Future<void> _run() async {
    if (_mode == SyncPullMode.downloadFull) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认以服务器为准？'),
          content: const Text(
            '将清空本机所有未同步的变更，并以服务器数据完整重建本机缓存。\n\n'
            '如果本机有未同步的笔记，它们会丢失。',
            style: TextStyle(height: 1.5),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空并下载'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      busy = true;
      error = null;
      _step = 3;
    });
    try {
      final r = await syncNow(force: true, mode: _mode);
      if (r == null) throw Exception('同步未执行（请重试）');
      releaseSync();
      bootSync();
      _completed = true;
      setState(() {
        busy = false;
        _result = r;
      });
    } catch (e) {
      setState(() {
        busy = false;
        error = '同步失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(const ['配置同步服务器', '登录', '选择同步策略', '同步结果'][_step])),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_step == 0) ...[
              Text('连接家中 NAS / 电脑上的 MyNotes 服务。'
                  '不配置也可以一直离线使用，笔记只保存在本机。',
                  style: TextStyle(color: p.muted, fontSize: 13, height: 1.5)),
              const SizedBox(height: 20),
              TextField(
                controller: _addr,
                enabled: !busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
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
            ],
            if (_step == 1) ...[
              Text('服务器已连通。登录后即可选择首次同步策略。', style: TextStyle(color: p.muted, fontSize: 13, height: 1.5)),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy ? null : () async {
                  await Navigator.of(context).push(fadeUpRoute(LoginPage(onLoggedIn: () {
                    store.authed = true;
                    store.notifyListeners(); // 不解除挂起：策略选定前不自动同步
                  })));
                  if (store.authed && mounted) setState(() => _step = 2);
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('登录 / 注册账号'),
                ),
              ),
            ],
            if (_step == 2) ..._strategy(p),
            if (_step == 3) ..._resultView(p),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: TextStyle(color: p.danger, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _strategy(Palette p) {
    return [
      Text('本地已有数据与服务器数据如何合并？',
          style: TextStyle(color: p.muted, fontSize: 13, height: 1.5)),
      const SizedBox(height: 16),
      _strategyTile(
        value: SyncPullMode.merge,
        title: '合并（推荐）',
        desc: '本地新增数据上传、服务器数据下载到本机；同一条笔记两端都改过时保留较新版本'
            '（被覆盖版本可在 Web 版历史中找回）。',
      ),
      _strategyTile(
        value: SyncPullMode.uploadOnly,
        title: '仅上传（本地为准）',
        desc: '首次只把本地变更推送到服务器，暂不拉取；之后的常规同步会正常拉取合并。',
      ),
      _strategyTile(
        value: SyncPullMode.downloadFull,
        title: '仅下载（服务器为准）',
        desc: '清空本机所有未同步变更，以服务器数据完整重建本机。',
        danger: true,
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: busy ? null : _run,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text('开始同步'),
        ),
      ),
    ];
  }

  Widget _strategyTile({
    required SyncPullMode value,
    required String title,
    required String desc,
    bool danger = false,
  }) {
    final p = paletteOf(context);
    final selected = _mode == value;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected ? p.primaryWeak : p.panel,
        borderRadius: BorderRadius.circular(AppDimens.rCard),
        border: Border.all(color: selected ? p.primary : p.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppDimens.rCard),
        onTap: () => setState(() => _mode = value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? p.primary : p.muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: danger ? p.danger : p.text)),
                  const SizedBox(height: 4),
                  Text(desc,
                      style: TextStyle(fontSize: 12.5, color: p.muted, height: 1.5)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resultView(Palette p) {
    final r = _result;
    return [
      Icon(
        error == null ? Icons.check_circle_outline : Icons.error_outline,
        size: 52,
        color: error == null ? p.primary : p.danger,
      ),
      const SizedBox(height: 14),
      Center(
        child: Text(error ?? '同步完成',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: p.text)),
      ),
      if (error == null && r != null) ...[
        const SizedBox(height: 18),
        _resultRow(p, Icons.upload_outlined, '上传本地变更', '${r.pushed} 条'),
        if (_mode == SyncPullMode.merge) ...[
          _resultRow(p, Icons.download_outlined, '新拉取服务器笔记', '${r.pulledNew} 条'),
          _resultRow(p, Icons.merge_outlined, '双端差异合并（新者胜）', '${r.mergedDiffs} 处'),
        ],
        if (_mode == SyncPullMode.downloadFull)
          _resultRow(p, Icons.download_outlined, '按服务器重建本机', '${r.pulledNew} 条'),
        const SizedBox(height: 10),
        Text('之后回到局域网 / VPN 时会自动保持同步（60 秒周期 + 打开应用时）。',
            style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.5)),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: error == null ? _popToRoot : () => setState(() => _step = 2),
        child: Text(error == null ? '完成' : '返回重试'),
      ),
    ];
  }

  Widget _resultRow(Palette p, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: p.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: TextStyle(fontSize: 13.5, color: p.text))),
          Text(value, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.text)),
        ],
      ),
    );
  }
}
