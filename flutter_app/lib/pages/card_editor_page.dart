// 密码卡片编辑页：加密开关/名称/网址/多套账号（掩码显隐复制）/备注
// 保存节律与文本编辑页一致：30 秒自动保存 + 返回立即保存
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/app_theme.dart';
import '../core/crypto.dart';
import '../core/models.dart';
import '../core/store.dart';

class CardEditorPage extends StatefulWidget {
  const CardEditorPage({super.key, required this.noteId, required this.initialEnc, required this.onClosed});
  final String noteId; // 'new' = 新建
  final bool initialEnc; // 新建时的默认加密状态（列表按钮双状态决定）
  final VoidCallback onClosed;

  @override
  State<CardEditorPage> createState() => _CardEditorPageState();
}

class _CardEditorPageState extends State<CardEditorPage> {
  final _title = TextEditingController();
  final _url = TextEditingController();
  final _notes = TextEditingController();
  Timer? _saveTimer;

  Note? note;
  CardFields card = CardFields();
  bool cardEnc = false;
  List<bool> showPw = [];
  int version = 0;
  bool loaded = false;
  bool dirty = false;
  String saveState = ''; // '' | saving | saved | error
  String? errorMsg;
  String copyMsg = '';

  @override
  void initState() {
    super.initState();
    debugPrint('CED: init noteId=${widget.noteId} enc=${widget.initialEnc}');
    if (widget.noteId == 'new') {
      cardEnc = widget.initialEnc;
      groupId = store.view == NoteView.group ? store.activeGroupId : null;
      _syncShowPw();
      loaded = true;
    } else {
      _load();
    }
  }

  String? groupId;

  Future<void> _load() async {
    try {
      final n = await api.getNote(widget.noteId);
      if (!mounted) return;
      setState(() {
        note = n;
        _title.text = n.title;
        cardEnc = n.enc;
        groupId = n.groupId;
        version = n.version;
        if (!n.enc) {
          card = CardFields.fromJsonString(n.content);
        } else if (Vault.instance.unlocked) {
          try {
            card = CardFields.fromJsonString(Vault.instance.decrypt(n.content));
          } catch (_) {
            card = CardFields();
            errorMsg = '解密失败（密钥可能不匹配）';
          }
        }
        _syncShowPw();
        loaded = true;
      });
    } catch (e) {
      setState(() {
        loaded = true;
        errorMsg = '加载失败：$e';
      });
    }
  }

  void _syncShowPw() {
    showPw = List<bool>.generate(card.credentials.length, (_) => false);
  }

  void _markDirty() {
    if (!dirty || saveState == 'error') {
      setState(() {
        dirty = true;
        if (saveState != 'error') saveState = '';
      });
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 30), () => _save());
  }

  Future<bool> _save() async {
    if (!dirty || !loaded) return true;
    // 全空草稿不落库（对齐 Web isEmptyDraft）
    if (note == null) {
      final c = card.serialized();
      final credsEmpty = c.credentials.every((x) => x.isEmpty);
      if (_title.text.trim().isEmpty && c.url.trim().isEmpty && c.notes.trim().isEmpty && credsEmpty) {
        return true;
      }
    }
    if (cardEnc && !Vault.instance.unlocked) {
      setState(() {
        saveState = 'error';
        errorMsg = '加密存储需要先输入主密码解锁';
      });
      return false;
    }
    setState(() => saveState = 'saving');
    try {
      final cs = card.serialized();
      final payload = NotePayload(
        type: 'card',
        title: _title.text,
        content: cardEnc ? Vault.instance.encrypt(cs.toJsonString()) : cs.toJsonString(),
        plainText: cardEnc ? '' : cs.plainSummary(),
        tags: const [],
        pinned: note?.pinned ?? false,
        groupId: groupId,
        enc: cardEnc,
        expectedVersion: note == null ? null : version,
      );
      final res = note == null
          ? await api.createNote(payload)
          : await api.updateNote(note!.id, payload);
      if (!mounted) return true;
      setState(() {
        note = res;
        version = res.version;
        dirty = false;
        saveState = 'saved';
        errorMsg = null;
      });
      await refreshNotes();
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

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    setState(() => copyMsg = '已复制');
    Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => copyMsg = '');
    });
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
    if (note != null && note!.enc && !Vault.instance.unlocked) {
      // 加密卡未解锁：解锁框
      return Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onClosed)),
        body: _unlockBody(p),
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
          title: Text('密码卡片', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
          actions: [
            if (note != null)
              IconButton(
                tooltip: '删除',
                icon: Icon(Icons.delete_outline, color: p.muted),
                onPressed: () => _delete(),
              ),
            _saveStateWidget(p),
            const SizedBox(width: 12),
          ],
        ),
        body: Column(
          children: [
            if (errorMsg != null)
              Container(
                width: double.infinity,
                color: p.danger.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(errorMsg!, style: TextStyle(color: p.danger, fontSize: 12)),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _encRow(p),
                  const SizedBox(height: 8),
                  _field(p, controller: _title, label: '名称', hint: '如：淘宝（标题明文可搜索）', onChanged: (_) => _markDirty()),
                  const SizedBox(height: 10),
                  _field(p, controller: _url, label: '网址', hint: 'https://', onChanged: (_) => _markDirty()),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: Text('账号密码（${card.credentials.length} 套）',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text))),
                      TextButton.icon(
                        onPressed: () {
                          setState(() => card.credentials.add(Credential()));
                          _syncShowPw();
                          _markDirty();
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('添加一套'),
                      ),
                    ],
                  ),
                  for (var i = 0; i < card.credentials.length; i++) _credentialBlock(p, i),
                  const SizedBox(height: 16),
                  Text('备注', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _notes,
                    maxLines: 4,
                    onChanged: (_) => _markDirty(),
                    decoration: InputDecoration(hintText: '备注…', hintStyle: TextStyle(color: p.muted)),
                  ),
                  if (copyMsg.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(copyMsg, style: TextStyle(color: p.primary, fontSize: 12)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unlockBody(Palette p) {
    final pw = TextEditingController();
    bool busy = false;
    return StatefulBuilder(
      builder: (context, setInner) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.lock_outline, size: 40, color: p.muted),
              const SizedBox(height: 10),
              Text('卡片内容已加密，输入主密码解锁本机', textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, fontSize: 13.5)),
              const SizedBox(height: 16),
              TextField(
                controller: pw,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(hintText: '主密码', prefixIcon: Icon(Icons.key_outlined)),
                onSubmitted: (_) => _doUnlock(pw, () => setInner(() {}), (fn) => setInner(fn)),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _doUnlock(pw, () => setInner(() {}), (fn) => setInner(fn)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: busy
                      ? const SizedBox(height: 18, width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('解锁'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _doUnlock(TextEditingController pw, VoidCallback refresh, void Function(void Function()) setInnerState) async {
    if (pw.text.isEmpty) return;
    setInnerState(() {});
    try {
      await unlockVault(pw.text);
      pw.clear();
      await _load(); // 重新解密加载
    } catch (e) {
      setState(() => errorMsg = '解锁失败：$e');
    }
    refresh();
  }

  Widget _encRow(Palette p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(cardEnc ? Icons.lock : Icons.lock_open, size: 18, color: cardEnc ? AppColors.accentOrange : p.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cardEnc ? '加密存储' : '明文存储',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.text)),
                Text(
                  cardEnc ? '内容在本机加密后才上传，服务器无法读取；换设备需输入主密码' : '内容明文存储，可被服务端搜索，任何设备打开无需密码',
                  style: TextStyle(fontSize: 11.5, color: p.muted, height: 1.4),
                ),
              ],
            ),
          ),
          Switch(
            value: cardEnc,
            activeColor: AppColors.accentOrange,
            onChanged: (v) {
              if (v && !Vault.instance.unlocked) {
                // 明文→加密需要密钥：提示先解锁
                setState(() => errorMsg = '开启加密需要先解锁（侧栏锁图标输入主密码）');
                return;
              }
              setState(() => cardEnc = v);
              _markDirty();
            },
          ),
        ],
      ),
    );
  }

  Widget _credentialBlock(Palette p, int i) {
    final c = card.credentials[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: TextEditingController(text: c.label),
                  onChanged: (v) {
                    c.label = v;
                    _markDirty();
                  },
                  decoration: InputDecoration(hintText: '标签，如：主号 / 小号', isDense: true),
                  style: TextStyle(fontSize: 13),
                ),
              ),
              if (card.credentials.length > 1)
                IconButton(
                  icon: Icon(Icons.close, size: 16, color: p.danger),
                  onPressed: () {
                    setState(() => card.credentials.removeAt(i));
                    _syncShowPw();
                    _markDirty();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 60,
                child: Text('账号', style: TextStyle(fontSize: 12.5, color: p.muted)),
              ),
              Expanded(
                child: TextField(
                  controller: TextEditingController(text: c.username),
                  onChanged: (v) {
                    c.username = v;
                    _markDirty();
                  },
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(hintText: '账号 / 邮箱', isDense: true),
                ),
              ),
              IconButton(
                icon: Icon(Icons.copy, size: 16, color: p.muted),
                tooltip: '复制账号',
                onPressed: () => _copy(c.username),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 60,
                child: Text('密码', style: TextStyle(fontSize: 12.5, color: p.muted)),
              ),
              Expanded(
                child: TextField(
                  controller: TextEditingController(text: c.password),
                  onChanged: (v) {
                    c.password = v;
                    _markDirty();
                  },
                  obscureText: !(showPw[i]),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(hintText: '密码', isDense: true),
                ),
              ),
              IconButton(
                icon: Icon(showPw[i] ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 16, color: p.muted),
                tooltip: showPw[i] ? '隐藏' : '显示',
                onPressed: () => setState(() => showPw[i] = !showPw[i]),
              ),
              IconButton(
                icon: Icon(Icons.copy, size: 16, color: p.muted),
                tooltip: '复制密码',
                onPressed: () => _copy(c.password),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(Palette p, {required TextEditingController controller, required String label, String? hint, ValueChanged<String>? onChanged}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(hintText: hint, hintStyle: TextStyle(color: p.muted)),
        ),
      ],
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

  Future<void> _delete() async {
    if (note == null) {
      widget.onClosed();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移到回收站'),
        content: const Text('这条卡片将移到回收站，之后可以恢复。'),
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
      await api.deleteNote(note!.id);
      await refreshNotes();
      widget.onClosed();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }
}
