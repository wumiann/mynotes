// 笔记编辑页：标题/标签/置顶/分组 + AppFlowyEditor（Tiptap 转换）
// 保存节律对齐 Web 版：30 秒粒度自动保存；返回/切换立即保存；全空草稿不落库
import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/data.dart';
import '../core/imgcache.dart';
import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/sync.dart';
import 'history_page.dart';
import '../editor/code_block_component.dart';
import '../editor/image_mobile_toolbar_item.dart';
import '../editor/todo_mobile_toolbar_item.dart';
import '../editor/tiptap_converter.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.noteId, required this.onClosed});
  final String noteId; // 'new' = 新建
  final VoidCallback onClosed;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  EditorState? editorState; // 加载完成后创建（文档替换=直接重建，比改 root 树可靠）
  final _title = TextEditingController();
  Timer? _saveTimer;

  Note? note; // null = 新建未落库
  List<String> tags = [];
  bool pinned = false;
  String? groupId;
  int version = 0;
  bool loaded = false;
  bool dirty = false;
  String saveState = ''; // '' | saving | saved | error
  String? errorMsg;
  String _tagInput = '';
  final _tagController = TextEditingController();

  @override
  void initState() {
    super.initState();
    debugPrint('ED: init noteId=${widget.noteId}');
    if (widget.noteId == 'new') {
      _installDocument({'type': 'doc', 'content': []});
      groupId = store.view == NoteView.group ? store.activeGroupId : null;
      loaded = true;
    } else {
      _load();
    }
  }

  bool _installing = false; // 文档装载期间的事务不算用户修改

  /// 显示前：/a/xxx → 本地缓存路径（带鉴权下载；AppFlowy image 用 Image.file 显示）
  Future<Map<String, dynamic>> _resolveImages(Map<String, dynamic> doc) async {
    await _walk(doc, (node) async {
      if (node['type'] == 'image') {
        final attrs = node['attrs'] as Map<String, dynamic>?;
        final src = attrs?['src'];
        if (src is String && src.startsWith('/a/')) {
          attrs!['src'] = await ImgCache.instance.resolve(src);
        }
      }
    });
    return doc;
  }

  /// 保存前：本地缓存路径 → 还原 /a/xxx
  Map<String, dynamic> _restoreImages(Map<String, dynamic> doc) {
    _walkSync(doc, (node) {
      if (node['type'] == 'image') {
        final attrs = node['attrs'] as Map<String, dynamic>?;
        final src = attrs?['src'];
        if (src is String) {
          attrs!['src'] = ImgCache.instance.restore(src);
        }
      }
    });
    return doc;
  }

  Future<void> _walk(dynamic node, Future<void> Function(Map<String, dynamic>) fn) async {
    if (node is Map<String, dynamic>) {
      await fn(node);
      for (final c in (node['content'] as List? ?? [])) {
        await _walk(c, fn);
      }
    }
  }

  void _walkSync(dynamic node, void Function(Map<String, dynamic>) fn) {
    if (node is Map<String, dynamic>) {
      fn(node);
      for (final c in (node['content'] as List? ?? [])) {
        _walkSync(c, fn);
      }
    }
  }

  void _installDocument(Map<String, dynamic> tiptapDoc) {
    final es = EditorState(document: Document.fromJson({'document': tiptapToAppflowy(tiptapDoc)}));
    es.transactionStream.listen((tr) {
      // before/after 都监听（checkbox 切换等操作的 operations 时机不完全确定）
      if (_installing) return;
      if (tr.$2.operations.isNotEmpty) _markDirty();
    });
    _installing = true;
    setState(() => editorState = es);
    WidgetsBinding.instance.addPostFrameCallback((_) => _installing = false);
  }

  Future<void> _load() async {
    try {
      final n = await data.getNote(widget.noteId);
      if (!mounted) return;
      if (n == null) {
        setState(() {
          loaded = true;
          errorMsg = '笔记不存在或已彻底删除';
        });
        return;
      }
      Map<String, dynamic> doc;
      try {
        doc = jsonDecode(n.content) as Map<String, dynamic>;
      } catch (_) {
        doc = {'type': 'doc', 'content': []};
      }
      setState(() {
        note = n;
        _title.text = n.title;
        tags = [...n.tags];
        pinned = n.pinned;
        groupId = n.groupId;
        version = n.version;
        loaded = true;
      });
      await _resolveImages(doc);
      _installDocument(doc);
    } catch (e) {
      setState(() {
        loaded = true;
        errorMsg = '加载失败：$e';
      });
    }
  }

  void _markDirty() {
    if (!dirty || saveState == 'error') {
      setState(() {
        dirty = true;
        if (saveState != 'error') saveState = '';
      });
    }
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 30), () => _save());
  }

  String _currentTiptapJson() {
    final es = editorState;
    if (es == null) return '{"type":"doc","content":[]}';
    final af = es.document.toJson();
    final root = (af['document'] ?? af) as Map<String, dynamic>;
    final tt = appflowyToTiptap(root);
    _restoreImages(tt); // 本地缓存路径 → /a/xxx（服务端存稳定引用）
    return jsonEncode(tt);
  }

  String _plainText() {
    final es = editorState;
    if (es == null) return '';
    final buf = StringBuffer();
    for (final child in es.document.root.children) {
      final delta = child.delta;
      if (delta != null) {
        for (final op in delta.toList()) {
          if (op is TextInsert) buf.write(op.text);
        }
        buf.write('\n');
      }
    }
    return buf.toString().trim();
  }

  Future<bool> _save() async {
    if (!dirty || !loaded) return true;
    final content = _currentTiptapJson();
    final plain = _plainText();
    // 全空草稿不落库
    if (note == null && _title.text.trim().isEmpty && plain.trim().isEmpty) {
      return true;
    }
    setState(() => saveState = 'saving');
    try {
      final payload = NotePayload(
        type: 'text',
        title: _title.text,
        content: content,
        plainText: plain,
        tags: tags,
        pinned: pinned,
        groupId: groupId,
        expectedVersion: note == null ? null : version,
      );
      final res = note == null
          ? await data.createNote(payload)
          : await data.updateNote(note!.id, payload);
      if (!mounted) return true;
      setState(() {
        note = res;
        version = res.version;
        dirty = false;
        saveState = 'saved';
      });
      await refreshNotes();
      await refreshTags();
      return true;
    } on ApiError catch (e) {
      if (!mounted) return false;
      setState(() {
        saveState = 'error';
        errorMsg = e.status == 409 ? '版本冲突（其他端已修改）' : e.message;
      });
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        saveState = 'error';
        errorMsg = '保存失败：$e';
      });
      return false;
    }
  }

  Future<void> _close() async {
    await _save();
    widget.onClosed();
  }

  Future<void> _openHistory() async {
    // 打开历史前先把未保存内容落库（对齐 Web 行为）
    await _save();
    final restored = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => HistoryPage(noteId: widget.noteId, noteTitle: _title.text)),
    );
    if (restored == true) {
      // 恢复后：立即同步拉取最新，并重载当前页
      await syncNow(silent: true).catchError((_) {});
      await _load();
    }
  }

  Future<void> _delete() async {
    if (note == null) {
      widget.onClosed();
      return;
    }
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
      await data.deleteNote(note!.id);
      await refreshNotes();
      await refreshTags();
      widget.onClosed();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  void _addTag() {
    final t = _tagInput.trim().replaceFirst(RegExp('^#'), '');
    if (t.isNotEmpty && !tags.contains(t) && tags.length < 20) {
      setState(() => tags.add(t));
      _markDirty();
    }
    _tagController.clear();
    setState(() => _tagInput = '');
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (!loaded) {
      return Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(),
        body: Center(child: CircularProgressIndicator(color: p.primary)),
      );
    }
    if (errorMsg != null && note == null) {
      return Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(),
        body: Center(child: Text(errorMsg!, style: TextStyle(color: p.danger))),
      );
    }
    final es = editorState;
    if (es == null) {
      return Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(),
        body: Center(child: CircularProgressIndicator(color: p.primary)),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _close),
          title: TextField(
            controller: _title,
            onChanged: (_) => _markDirty(),
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text),
            decoration: InputDecoration(
              hintText: '标题',
              border: InputBorder.none,
              filled: false,
              hintStyle: TextStyle(color: p.muted, fontWeight: FontWeight.w400),
            ),
          ),
          actions: [
            IconButton(
              tooltip: pinned ? '取消置顶' : '置顶',
              icon: Icon(pinned ? Icons.star : Icons.star_border,
                  color: pinned ? AppColors.accentOrange : p.muted),
              onPressed: () {
                setState(() => pinned = !pinned);
                _markDirty();
              },
            ),
            if (note != null)
              IconButton(
                tooltip: '版本历史',
                icon: Icon(Icons.history, size: 21, color: p.muted),
                onPressed: _openHistory,
              ),
            if (note != null)
              IconButton(
                tooltip: '删除',
                icon: Icon(Icons.delete_outline, color: p.muted),
                onPressed: _delete,
              ),
          ],
        ),
        body: Column(
          children: [
            // meta 行：标签 chips + 输入 + 分组下拉 + 保存状态
            Container(
              color: p.panel,
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final t in tags)
                              InputChip(
                                label: Text(t, style: TextStyle(fontSize: 12, color: p.muted)),
                                backgroundColor: p.chip,
                                side: BorderSide.none,
                                visualDensity: VisualDensity.compact,
                                onDeleted: () {
                                  setState(() => tags.remove(t));
                                  _markDirty();
                                },
                              ),
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: _tagController,
                                onChanged: (v) => setState(() => _tagInput = v),
                                onSubmitted: (_) => _addTag(),
                                style: const TextStyle(fontSize: 12.5),
                                decoration: const InputDecoration(
                                  hintText: '回车加标签',
                                  isDense: true,
                                  filled: false,
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(vertical: 4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 分组下拉
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: groupId,
                          isDense: true,
                          style: TextStyle(fontSize: 12.5, color: p.muted),
                          icon: Icon(Icons.folder_outlined, size: 16, color: p.muted),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('未分组')),
                            for (final g in store.groups)
                              DropdownMenuItem(
                                value: g.id,
                                child: Text('${'　' * g.depth}${g.name}'),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() => groupId = v);
                            _markDirty();
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      _saveStateWidget(p),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            // 正文 + 移动端格式工具栏（随键盘显隐）
            Expanded(
              child: MobileToolbarV2(
                editorState: es,
                toolbarItems: [
                  textDecorationMobileToolbarItem, // 加粗/斜体/下划线/删除线/行内代码
                  headingMobileToolbarItem,
                  listMobileToolbarItem, // 无序/有序
                  todoMobileToolbarItem, // 待办（自定义）
                  quoteMobileToolbarItem,
                  // 代码块/超链接按钮不上工具栏：手机上用处小，已有内容仍正常渲染
                  imageMobileToolbarItem, // 图片：选图/压缩/上传/插入
                ],
                child: AppFlowyEditor(
                  editorState: es,
                  editorStyle: const EditorStyle.mobile(),
                  blockComponentBuilders: {
                    ...standardBlockComponentBuilderMap,
                    CodeBlockKeys.type: CodeBlockComponentBuilder(),
                  },
                ),
              ),
            ),
            if (errorMsg != null)
              Container(
                width: double.infinity,
                color: p.danger.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(errorMsg!, style: TextStyle(color: p.danger, fontSize: 12)),
              ),
            // 底部：更新时间
            Container(
              width: double.infinity,
              color: p.panel,
              padding: EdgeInsets.only(
                left: 16, right: 16,
                top: 7,
                bottom: MediaQuery.paddingOf(context).bottom + 7,
              ),
              child: Text(
                note != null ? '更新于 ${note!.updatedAt.replaceAll('T', ' ').substring(0, 16)}' : '新笔记',
                style: TextStyle(color: p.muted, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _saveStateWidget(Palette p) {
    final label = switch (saveState) {
      'saving' => '保存中…',
      'saved' => '已保存',
      'error' => '保存失败',
      _ => dirty ? '未保存' : '',
    };
    if (label.isEmpty) return const SizedBox(width: 4);
    final color = saveState == 'error' ? p.danger : (dirty || saveState == 'saving' ? p.primary : p.muted);
    return GestureDetector(
      onTap: (dirty || saveState == 'error') ? () => _save() : null,
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
