// 主骨架：抽屉（分组/标签/底部状态）+ 列表 ↔ 编辑器导航
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/store.dart';
import '../core/sync.dart' show releaseSync;
import 'card_editor_page.dart';
import 'editor_page.dart';
import 'login_page.dart';
import 'note_list_page.dart';
import 'settings_page.dart';
import 'sync_setup_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
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
      key: _scaffoldKey,
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
      return NoteListPage(key: const ValueKey('list'), onOpenNote: _openNote, onOpenCard: _openCard, onMenu: () => _scaffoldKey.currentState?.openDrawer());
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
            // 品牌：tonal 圆角容器图标 + 字标
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                        color: p.primaryWeak, borderRadius: BorderRadius.circular(AppDimens.rField)),
                    child: Icon(Icons.bookmark_rounded, size: 21, color: p.primary),
                  ),
                  const SizedBox(width: 11),
                  Text('MyNotes',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700, color: p.text, letterSpacing: 0.2)),
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
            // 底部：解锁状态 + 用户名 + 登出（卡片化容器）
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: p.panel2,
                borderRadius: BorderRadius.circular(AppDimens.rCard),
                border: Border.all(color: p.border),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: !api.configured
                        ? '本地模式：加密卡片需配置同步后使用'
                        : store.vaultUnlocked ? '已解锁，可创建查看加密笔记（点击锁定）' : '未解锁（点击输入主密码）',
                    icon: Icon(
                      store.vaultUnlocked ? Icons.lock_open : Icons.lock,
                      size: 20,
                      color: !api.configured
                          ? p.muted.withValues(alpha: 0.5)
                          : store.vaultUnlocked ? AppColors.accentOrange : p.muted,
                    ),
                    onPressed: () => _toggleVault(context),
                  ),
                  Expanded(
                    child: Text(api.username ?? (api.hasServer ? '未登录' : '本地模式'),
                        style: TextStyle(color: p.text, fontSize: 13.5, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    tooltip: '设置',
                    icon: Icon(Icons.settings_outlined, size: 19, color: p.muted),
                    onPressed: () => Navigator.of(context).push(fadeUpRoute(const SettingsPage())),
                  ),
                  if (!api.hasServer)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(fadeUpRoute(const SyncSetupPage())),
                      child: const Text('配置同步'),
                    )
                  else if (!store.authed)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(fadeUpRoute(LoginPage(onLoggedIn: () {
                        store.authed = true;
                        releaseSync(); // 抽屉登录不在向导里，直接恢复正常同步
                        store.notifyListeners();
                      }))),
                      child: const Text('登录'),
                    )
                  else
                    TextButton(
                      onPressed: () async {
                        // 服务端登出失败也要完成本地登出（clearAuth 在 logout 的 finally 里）
                        try {
                          await api.logout();
                        } catch (_) {}
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
    if (!api.configured) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本地模式：加密卡片需配置同步服务器并登录后使用')));
      return;
    }
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
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
      child: Text(title,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: p.muted, letterSpacing: 0.6)),
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(icon, size: 20, color: selected ? p.primary : p.muted),
        title: Text(label,
            style: TextStyle(
                fontSize: 14,
                color: selected ? p.primary : p.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        trailing: trailing != null
            ? Text(trailing, style: TextStyle(color: p.muted, fontSize: 12))
            : null,
        selected: selected,
        selectedTileColor: p.primaryWeak,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppDimens.rField)),
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
