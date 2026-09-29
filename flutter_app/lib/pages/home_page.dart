// 主骨架：抽屉（分组/标签/底部状态）+ 列表 ↔ 编辑器导航
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/store.dart';
import 'card_editor_page.dart';
import 'editor_page.dart';
import 'note_list_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // null=列表；'new'=新建文本；'new-card'=新建卡片；其他=笔记id
  String? _openNoteId;

  @override
  void initState() {
    super.initState();
    // 首帧后加载抽屉数据（分组/标签），避免 build 期通知
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshGroups();
      refreshTags();
    });
  }

  void _openNote(String id) => setState(() => _openNoteId = id);

  void _openCard(String id) => setState(() {
        _openNoteId = 'card:$id';
      });

  void _closeEditor() => setState(() => _openNoteId = null);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: paletteOf(context).bg,
      drawer: const AppDrawer(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: _buildChild(),
      ),
    );
  }

  Widget _buildChild() {
    final id = _openNoteId;
    if (id == null) {
      return NoteListPage(key: const ValueKey('list'), onOpenNote: _openNote, onOpenCard: _openCard);
    }
    if (id.startsWith('card:')) {
      final cardId = id.substring(5);
      // 新建：card:new-card:enc / card:new-card:plain（列表按钮双状态决定）
      final isNew = cardId.startsWith('new-card:');
      return CardEditorPage(
        key: ValueKey('card-$cardId'),
        noteId: isNew ? 'new' : cardId,
        initialEnc: cardId.endsWith(':enc'),
        onClosed: _closeEditor,
      );
    }
    return EditorPage(key: ValueKey('editor-$id'), noteId: id, onClosed: _closeEditor);
  }
}

/// 侧栏抽屉：品牌 / 分组树 / 标签 / 底部（用户名+登出）
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Drawer(
      backgroundColor: p.panel,
      width: 290,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 品牌
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
              child: Row(
                children: [
                  Icon(Icons.bookmark_outlined, size: 22, color: p.primary),
                  const SizedBox(width: 8),
                  Text('MyNotes', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  _section(context, '分组'),
                  _item(context,
                      icon: Icons.all_inclusive,
                      label: '全部笔记',
                      selected: store.view == NoteView.all,
                      onTap: () => _switch(context, () => store.setView(NoteView.all))),
                  for (final g in store.groups)
                    _item(context,
                        icon: Icons.folder_outlined,
                        label: g.name,
                        indent: 12.0 + g.depth * 16,
                        selected: store.view == NoteView.group && store.activeGroupId == g.id,
                        onTap: () => _switch(context, () => store.setView(NoteView.group, groupId: g.id))),
                  _item(context,
                      icon: Icons.folder_open_outlined,
                      label: '未分组',
                      selected: store.view == NoteView.ungrouped,
                      onTap: () => _switch(context, () => store.setView(NoteView.ungrouped))),
                  const SizedBox(height: 8),
                  _item(context,
                      icon: Icons.star_outline,
                      label: '★ 置顶',
                      selected: store.view == NoteView.pinned,
                      onTap: () => _switch(context, () => store.setView(NoteView.pinned))),
                  _item(context,
                      icon: Icons.delete_outline,
                      label: '回收站',
                      selected: store.view == NoteView.trash,
                      onTap: () => _switch(context, () => store.setView(NoteView.trash))),
                  const SizedBox(height: 10),
                  _section(context, '标签'),
                  for (final t in store.tagList)
                    _item(context,
                        icon: Icons.tag,
                        label: '# ${t.tag}',
                        trailing: '${t.count}',
                        selected: store.view == NoteView.tag && store.activeTag == t.tag,
                        onTap: () => _switch(context, () => store.setView(NoteView.tag, tag: t.tag))),
                  if (store.tagList.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(30, 6, 18, 6),
                      child: Text('在笔记里加标签后会显示在这里', style: TextStyle(color: p.muted, fontSize: 12)),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            // 底部：解锁状态 + 用户名 + 登出
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: store.vaultUnlocked ? '已解锁，可创建查看加密笔记（点击锁定）' : '未解锁（点击输入主密码）',
                    icon: Icon(
                      store.vaultUnlocked ? Icons.lock_open : Icons.lock,
                      size: 20,
                      color: store.vaultUnlocked ? AppColors.accentOrange : p.muted,
                    ),
                    onPressed: () => _toggleVault(context),
                  ),
                  Expanded(
                    child: Text(api.username ?? '',
                        style: TextStyle(color: p.text, fontSize: 13.5, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                  ),
                  TextButton(
                    onPressed: () async {
                      await api.logout();
                      lockVault();
                      store.authed = false;
                      store.notifyListeners();
                    },
                    child: const Text('登出'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点击解锁状态图标：已解锁 → 锁定；未解锁 → 弹密码框
  Future<void> _toggleDrawerVault(BuildContext context) async {
    if (store.vaultUnlocked) {
      lockVault();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _VaultUnlockDialog(),
    );
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已解锁，可创建和查看加密卡片'), duration: Duration(seconds: 2)));
    }
  }

  Future<void> _toggleVault(BuildContext context) => _toggleDrawerVault(context);

  void _switch(BuildContext context, VoidCallback fn) {
    fn();
    Navigator.pop(context); // 收抽屉
  }

  Widget _section(BuildContext context, String title) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Text(title, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: p.muted)),
    );
  }

  Widget _item(BuildContext context,
      {required IconData icon, required String label, String? trailing, double indent = 12,
      bool selected = false, required VoidCallback onTap}) {
    final p = paletteOf(context);
    return Padding(
      padding: EdgeInsets.only(left: indent - 12),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(icon, size: 18, color: selected ? p.primary : p.muted),
        title: Text(label,
            style: TextStyle(
                fontSize: 13.5,
                color: selected ? p.primary : p.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        trailing: trailing != null
            ? Text(trailing, style: TextStyle(color: p.muted, fontSize: 11.5))
            : null,
        selected: selected,
        selectedTileColor: p.primaryWeak,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: () {
          onTap();
          refreshNotes();
        },
      ),
    );
  }
}

/// 解锁对话框：输入主密码派生 encKey（PBKDF2 600k，转圈等待）
class _VaultUnlockDialog extends StatefulWidget {
  @override
  State<_VaultUnlockDialog> createState() => _VaultUnlockDialogState();
}

class _VaultUnlockDialogState extends State<_VaultUnlockDialog> {
  final _pw = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> _go() async {
    if (_pw.text.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await unlockVault(_pw.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        busy = false;
        error = '解锁失败（密码可能不正确）';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('解锁密码卡片'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('输入主密码以解密卡片（解锁状态保持到下次锁定）', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: _pw,
            obscureText: true,
            autofocus: true,
            enabled: !busy,
            decoration: const InputDecoration(hintText: '主密码', prefixIcon: Icon(Icons.key_outlined)),
            onSubmitted: (_) => _go(),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          onPressed: _go,
          child: busy
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('解锁'),
        ),
      ],
    );
  }
}
