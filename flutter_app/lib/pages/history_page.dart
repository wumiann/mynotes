// 版本历史页：版本列表 → 行级 diff（对比上一版）→ 一键恢复
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/diff.dart';
import '../core/models.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.noteId, required this.noteTitle});
  final String noteId;
  final String noteTitle;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<NoteVersionMeta> versions = [];
  bool loading = true;
  String? error;
  // 展开状态：version -> diff（懒加载）
  final Map<int, List<DiffLine>> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      versions = await api.getNoteVersions(widget.noteId);
      setState(() => loading = false);
      // 最新一版默认展开
      if (versions.isNotEmpty) await _toggle(versions.first);
    } catch (e) {
      setState(() {
        loading = false;
        error = '获取历史失败（需要联网）：$e';
      });
    }
  }

  Future<void> _toggle(NoteVersionMeta v) async {
    if (_expanded.containsKey(v.version)) {
      setState(() => _expanded.remove(v.version));
      return;
    }
    setState(() => _expanded[v.version] = []); // 占位=加载中
    try {
      final cur = await api.getNoteVersionPlainText(widget.noteId, v.version);
      final idx = versions.indexOf(v);
      final prevMeta = idx + 1 < versions.length ? versions[idx + 1] : null;
      final prev = prevMeta != null ? await api.getNoteVersionPlainText(widget.noteId, prevMeta.version) : '';
      setState(() => _expanded[v.version] = collapseSame(lineDiff(prev, cur)));
    } catch (e) {
      setState(() => _expanded.remove(v.version));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载改动失败：$e')));
    }
  }

  Future<void> _restore(NoteVersionMeta v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('恢复到 v${v.version}'),
        content: const Text('当前内容会先自动保存一份到历史，然后覆盖为所选版本。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.restoreNoteVersion(widget.noteId, v.version);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已恢复')));
        Navigator.pop(context, true); // 通知编辑页重载
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(title: Text(widget.noteTitle.isEmpty ? '版本历史' : '历史：${widget.noteTitle}')),
      body: loading
          ? Center(child: CircularProgressIndicator(color: p.primary))
          : error != null
              ? Center(child: Text(error!, style: TextStyle(color: p.danger)))
              : versions.isEmpty
                  ? Center(child: Text('还没有历史版本\n（每次保存有实际变化的内容时自动留档）',
                      textAlign: TextAlign.center, style: TextStyle(color: p.muted)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(10),
                      itemCount: versions.length,
                      itemBuilder: (_, i) {
                        final v = versions[i];
                        final diff = _expanded[v.version];
                        return Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: p.panel,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: p.border),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 44,
                                    child: Text('v${v.version}',
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.primary)),
                                  ),
                                  Expanded(
                                    child: Text(fmtTime(v.updatedAt), style: TextStyle(fontSize: 12.5, color: p.muted)),
                                  ),
                                  TextButton(
                                    onPressed: () => _toggle(v),
                                    child: Text(diff == null ? '看改动' : '收起', style: const TextStyle(fontSize: 12.5)),
                                  ),
                                  TextButton(
                                    onPressed: () => _restore(v),
                                    child: Text('恢复', style: TextStyle(fontSize: 12.5, color: p.primary)),
                                  ),
                                ],
                              ),
                            ),
                            if (diff != null)
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 4, bottom: 8),
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  color: p.panel2,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: p.border),
                                ),
                                child: diff.isEmpty
                                    ? Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: SizedBox(
                                            height: 16, width: 16,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: p.primary)),
                                      )
                                    : Column(
                                        children: [
                                          for (final l in diff)
                                            Container(
                                              width: double.infinity,
                                              color: switch (l.type) {
                                                'add' => const Color(0x2200C853),
                                                'del' => const Color(0x22D93025),
                                                _ => null,
                                              },
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  SizedBox(
                                                    width: 14,
                                                    child: Text(
                                                      switch (l.type) { 'add' => '+', 'del' => '−', _ => '' },
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: switch (l.type) {
                                                          'add' => const Color(0xFF00893E),
                                                          'del' => p.danger,
                                                          _ => p.muted,
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: Text(
                                                      l.text.isEmpty ? ' ' : l.text,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        height: 1.5,
                                                        color: l.type == 'fold' ? p.muted : p.text,
                                                        decoration: l.type == 'del' ? TextDecoration.lineThrough : null,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                              ),
                          ],
                        );
                      },
                    ),
    );
  }
}
