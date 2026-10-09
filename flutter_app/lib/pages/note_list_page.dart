// 笔记列表页：搜索/条目/新建按钮（双状态）/回收站操作
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/data.dart';
import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/sync.dart';
import 'editor_page.dart';
import 'settings_page.dart';

class NoteListPage extends StatefulWidget {
  const NoteListPage({super.key, required this.onOpenNote, required this.onOpenCard, this.onMenu});
  final ValueChanged<String> onOpenNote;
  final VoidCallback? onMenu; // 打开外层抽屉（内层 Scaffold 挡了自动汉堡）
  final ValueChanged<String> onOpenCard; // 卡片类型笔记走卡片编辑页

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
      await data.deleteNote(n.id);
      await refreshNotes();
      await refreshTags();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  Future<void> _restore(String id) async {
    try {
      await data.restoreNote(id);
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
        leading: widget.onMenu != null
            ? IconButton(
                tooltip: '菜单',
                icon: const Icon(Icons.menu),
                onPressed: widget.onMenu,
              )
            : null,
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
            border: _searchBorder(p.border),
            enabledBorder: _searchBorder(p.border),
            focusedBorder: _searchBorder(p.primary, show: true),
          ),
        ),
        actions: [
          // 同步状态徽标：未配置（本地模式）/ ✓已同步 / ⟳同步中 / ⏳N 待同步 / ⛔离线
          ListenableBuilder(
            listenable: syncState,
            builder: (context, _) {
              final Widget badge;
              final String tooltip;
              final VoidCallback onPressed;
              if (!api.configured) {
                badge = Icon(Icons.cloud_off_outlined, size: 18, color: p.muted);
                tooltip = '未配置同步，数据仅保存在本机（点击去设置）';
                onPressed = () => Navigator.of(context).push(fadeUpRoute(const SettingsPage()));
              } else if (syncState.syncing) {
                badge = SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: p.primary),
                );
                tooltip = '同步中…';
                onPressed = () {};
              } else if (syncState.pending > 0) {
                badge = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: p.primaryWeak, borderRadius: BorderRadius.circular(999)),
                  child: Text('${syncState.pending}', style: TextStyle(color: p.primary, fontSize: 11.5)),
                );
                tooltip = '${syncState.pending} 条待同步，点击立即同步';
                onPressed = () => syncNow().catchError((_) {});
              } else if (syncState.online == false) {
                badge = Icon(Icons.block, size: 18, color: p.danger);
                tooltip = '离线模式，点击重试同步';
                onPressed = () => syncNow().catchError((_) {});
              } else {
                badge = Icon(Icons.check_circle_outline, size: 18, color: p.muted);
                tooltip = '已同步，点击刷新';
                onPressed = () => syncNow().catchError((_) {});
              }
              return IconButton(tooltip: tooltip, onPressed: onPressed, icon: badge);
            },
          ),
          if (!isTrash) ...[
            // 新建密码卡片：单按钮双状态（对齐 Web 语义）——
            // 图标=将建出的卡片类型，与侧栏解锁状态刻意相反
            IconButton(
              tooltip: !api.configured
                  ? '本地模式：加密卡片需配置同步后使用'
                  : store.vaultUnlocked ? '创建加密笔记' : '创建不加密笔记',
              icon: Icon(
                store.vaultUnlocked ? Icons.lock : Icons.lock_open,
                size: 20,
                color: !api.configured ? p.muted.withValues(alpha: 0.5) : store.vaultUnlocked ? AppColors.accentOrange : p.text,
              ),
              onPressed: () {
                if (!api.configured) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('加密卡片需配置同步服务器并登录后使用（普通卡片不受影响）')));
                  return;
                }
                widget.onOpenCard('new-card:${store.vaultUnlocked ? 'enc' : 'plain'}');
              },
            ),
            IconButton(
              tooltip: '新建笔记',
              icon: Icon(Icons.edit_note_outlined, color: p.text),
              onPressed: () => widget.onOpenNote('new'),
            ),
          ],
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
                    ? _EmptyView(isTrash: isTrash, onConfigure: !api.configured
                        ? () => Navigator.of(context).push(fadeUpRoute(const SettingsPage()))
                        : null)
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
                                if (store.notes[i].type == 'card') {
                                  widget.onOpenCard(store.notes[i].id);
                                } else {
                                  widget.onOpenNote(store.notes[i].id);
                                }
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
  const _EmptyView({required this.isTrash, this.onConfigure});
  final bool isTrash;
  final VoidCallback? onConfigure; // 未配置同步时提供「去配置」入口
  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final local = onConfigure != null;
    final (icon, text) = isTrash
        ? (Icons.delete_outline, '回收站为空')
        : store.search.isNotEmpty
            ? (Icons.search_off, '没有匹配的笔记')
            : local
                ? (Icons.cloud_off_outlined, '笔记仅保存在本机')
                : (Icons.note_alt_outlined, '暂无笔记，点右上角新建');
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // tonal 圆底图标：替代原来的 emoji，浅暗两套主题自动适配
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(color: p.chip, shape: BoxShape.circle),
            child: Icon(icon, size: 34, color: p.muted),
          ),
          const SizedBox(height: 14),
          Text(text, style: TextStyle(color: p.muted, fontSize: 13.5)),
          if (local) ...[
            const SizedBox(height: 6),
            Text('配置同步后可与 Web 版互通',
                style: TextStyle(color: p.muted.withValues(alpha: 0.8), fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onConfigure,
              child: const Text('配置同步服务器'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 卡片右下角的文字操作（删除/恢复等）：加大触控区 + 按压水波纹
class _CardAction extends StatelessWidget {
  const _CardAction({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(label, style: TextStyle(color: color, fontSize: 12, height: 1.3)),
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
    // Material+InkWell：按压有水波纹反馈（原来 GestureDetector 无任何按压态）
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: p.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.rCard),
          side: BorderSide(color: p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (note.pinned) ...[
                      const Icon(Icons.star, size: 14, color: AppColors.accentOrange),
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
                          style: TextStyle(fontWeight: FontWeight.w600, color: p.text, fontSize: 15, height: 1.4)),
                    ),
                  ],
                ),
                if (note.plainText.isNotEmpty || isCard) ...[
                  const SizedBox(height: 4),
                  Text(
                    isCard
                        ? (note.enc ? (store.cardExcerpts[note.id] ?? '解锁后查看') : _plainCardExcerpt(note))
                        : note.excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.5),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(fmtTime(note.updatedAt), style: TextStyle(color: p.muted, fontSize: 12)),
                    const SizedBox(width: 7),
                    for (final t in note.tags.take(3))
                      Container(
                        margin: const EdgeInsets.only(right: 5),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(AppDimens.rPill)),
                        child: Text(t, style: TextStyle(color: p.muted, fontSize: 11, height: 1.3)),
                      ),
                    const Spacer(),
                    if (isTrash) ...[
                      _CardAction(label: '恢复', color: p.primary, onTap: onRestore),
                      const SizedBox(width: 6),
                      _CardAction(label: '彻底删除', color: p.danger, onTap: () => _purgeConfirm(context)),
                    ] else
                      _CardAction(label: '删除', color: p.muted, onTap: onDelete),
                  ],
                ),
              ],
            ),
          ),
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
      await data.purgeNote(note.id);
      await refreshNotes();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }
}

/// 明文卡片摘要：解析 content 取首套账号（服务端 excerpt 即 plainText 前 120 字，这里复算更稳）
String _plainCardExcerpt(Note n) {
  try {
    final c = CardFields.fromJsonString(n.content);
    return c.excerptFor().isNotEmpty ? c.excerptFor() : n.excerpt;
  } catch (_) {
    return n.excerpt;
  }
}

/// 搜索框边框：平时无边框纯填充，聚焦时主题色描边（圆角胶囊）
OutlineInputBorder _searchBorder(Color color, {bool show = false}) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppDimens.rField + 2),
    borderSide: show ? BorderSide(color: color) : BorderSide.none);
