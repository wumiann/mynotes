// 笔记列表页：搜索/条目/新建按钮（双状态）/回收站操作
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'editor_page.dart';

class NoteListPage extends StatefulWidget {
  const NoteListPage({super.key, required this.onOpenNote});
  final ValueChanged<String> onOpenNote;

  @override
  State<NoteListPage> createState() => _NoteListPageState();
}

class _NoteListPageState extends State<NoteListPage> {
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    // 首帧后再拉数据：initState 同步链里 notifyListeners 会触发
    // "markNeedsBuild called during build"，通知被吞导致列表 UI 停在坏状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  void _reload() {
    refreshNotes().catchError((e) {
      if (mounted && e is ApiError && e.status == 401) {
        store.authed = false;
        store.notifyListeners();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
      return null;
    });
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      store.search = v;
      _reload();
    });
  }

  Future<void> _delete(Note n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移到回收站'),
        content: const Text('这条笔记将移到回收站，之后可以恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.deleteNote(n.id);
      await refreshNotes();
      await refreshTags();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  Future<void> _restore(String id) async {
    try {
      await api.restoreNote(id);
      await refreshNotes();
      await refreshTags();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isTrash = store.view == NoteView.trash;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        title: TextField(
          onChanged: _onSearchChanged,
          enabled: !isTrash,
          decoration: InputDecoration(
            hintText: isTrash ? '' : '搜索…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            contentPadding: EdgeInsets.zero,
            filled: true,
            fillColor: p.panel2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          if (!isTrash)
            IconButton(
              tooltip: '新建笔记',
              icon: Icon(Icons.edit_note_outlined, color: p.text),
              onPressed: () => widget.onOpenNote('new'),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(store.viewTitle,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.muted)),
          ),
          Expanded(
            child: store.loadingList && store.notes.isEmpty
                ? Center(child: CircularProgressIndicator(color: p.primary))
                : store.notes.isEmpty
                    ? _EmptyView(isTrash: isTrash)
                    : RefreshIndicator(
                        color: p.primary,
                        onRefresh: () async {
                          await refreshNotes();
                          await refreshGroups();
                          await refreshTags();
                        },
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 90),
                          itemCount: store.notes.length,
                          itemBuilder: (_, i) => _NoteCard(
                            note: store.notes[i],
                            isTrash: isTrash,
                              onTap: () {
                                debugPrint('NL: tap card ${store.notes[i].id}');
                                widget.onOpenNote(store.notes[i].id);
                              },
                            onDelete: () => _delete(store.notes[i]),
                            onRestore: () => _restore(store.notes[i].id),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.isTrash});
  final bool isTrash;
  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(isTrash ? '🗑️' : store.search.isNotEmpty ? '🔍' : '🗒️', style: const TextStyle(fontSize: 32)),
          const SizedBox(height: 10),
          Text(
            isTrash ? '回收站为空' : store.search.isNotEmpty ? '没有匹配的笔记' : '暂无笔记，点击 ＋ 新建',
            style: TextStyle(color: p.muted),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.isTrash,
    required this.onTap,
    required this.onDelete,
    required this.onRestore,
  });

  final Note note;
  final bool isTrash;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isCard = note.type == 'card';
    final title = note.title.isNotEmpty
        ? note.title
        : isCard
            ? '未命名卡片'
            : (note.excerpt.isNotEmpty ? note.excerpt.substring(0, note.excerpt.length > 30 ? 30 : note.excerpt.length) : '无标题');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: const Color(0x0A101828), blurRadius: 2, offset: const Offset(0, 1))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (note.pinned) ...[
                  Icon(Icons.star, size: 14, color: AppColors.accentOrange),
                  const SizedBox(width: 4),
                ],
                if (isCard) ...[
                  Icon(note.enc ? Icons.lock : Icons.lock_open, size: 13, color: p.muted),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: p.text, fontSize: 14.5)),
                ),
              ],
            ),
            if (note.plainText.isNotEmpty || isCard) ...[
              const SizedBox(height: 3),
              Text(
                isCard ? (note.enc ? '解锁后查看' : note.excerpt) : note.excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.5),
              ),
            ],
            const SizedBox(height: 7),
            Row(
              children: [
                Text(fmtTime(note.updatedAt), style: TextStyle(color: p.muted, fontSize: 11.5)),
                const SizedBox(width: 6),
                for (final t in note.tags.take(3))
                  Container(
                    margin: const EdgeInsets.only(right: 5),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(999)),
                    child: Text(t, style: TextStyle(color: p.muted, fontSize: 11)),
                  ),
                const Spacer(),
                if (isTrash) ...[
                  GestureDetector(
                    onTap: onRestore,
                    child: Text('恢复', style: TextStyle(color: p.primary, fontSize: 12)),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => _purgeConfirm(context),
                    child: Text('彻底删除', style: TextStyle(color: p.danger, fontSize: 12)),
                  ),
                ] else
                  GestureDetector(
                    onTap: onDelete,
                    child: Text('删除', style: TextStyle(color: p.muted, fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _purgeConfirm(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: const Text('删除后无法恢复，版本历史一并清理。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.purgeNote(note.id);
      await refreshNotes();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }
}
