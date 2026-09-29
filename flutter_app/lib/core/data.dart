// 数据门面（本地优先）：UI 只与本层交互
// 读=本地库；写=本地立即生效 + 入变更队列 + 2 秒后补推（对齐 Web App 模式）
import 'dart:math';

import 'localdb.dart';
import 'models.dart';
import 'localdb.dart';
import 'sync.dart' show applyViewLocal, schedulePush, localdb;

class Data {
  Data._();
  static final instance = Data._();

  Future<List<Note>> listNotes() async {
    final all = await localdb.allNotes();
    return applyViewLocal(all);
  }

  Future<Note?> getNote(String id) => localdb.getNote(id);

  /// 创建：本地临时 id（uuid 风格）+ version 1 + 入队；推送成功后重映射为服务端 id
  Future<Note> createNote(NotePayload p) async {
    final id = _localId();
    final now = DateTime.now().toIso8601String();
    final n = Note(
      id: id,
      type: p.type,
      title: p.title,
      content: p.content,
      plainText: p.plainText,
      tags: p.tags,
      pinned: p.pinned,
      groupId: p.groupId,
      enc: p.enc ?? false,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    await localdb.upsertNote(n);
    await localdb.enqueue(QueueOp(kind: 'create', noteId: id, payload: p.toJson()));
    schedulePush();
    return n;
  }

  Future<Note> updateNote(String id, NotePayload p) async {
    final old = await localdb.getNote(id);
    final n = old!.copyWith(
      title: p.title,
      content: p.content,
      plainText: p.plainText,
      tags: p.tags,
      pinned: p.pinned,
      groupId: p.groupId,
      updatedAt: DateTime.now().toIso8601String(),
    );
    await localdb.upsertNote(n);
    await localdb.enqueue(QueueOp(kind: 'update', noteId: id, payload: p.toJson()));
    schedulePush();
    return n;
  }

  /// 进回收站：本地标 deletedAt + 入队
  Future<void> deleteNote(String id) async {
    final old = await localdb.getNote(id);
    if (old == null) return;
    final n = old.copyWith(updatedAt: DateTime.now().toIso8601String());
    await localdb.upsertNote(Note(
      id: n.id, type: n.type, title: n.title, content: n.content, plainText: n.plainText,
      tags: n.tags, pinned: n.pinned, groupId: n.groupId, enc: n.enc, version: n.version,
      createdAt: n.createdAt, updatedAt: n.updatedAt, deletedAt: DateTime.now().toIso8601String(),
    ));
    await localdb.enqueue(QueueOp(kind: 'delete', noteId: id));
    schedulePush();
  }

  Future<void> restoreNote(String id) async {
    final old = await localdb.getNote(id);
    if (old == null) return;
    await localdb.upsertNote(Note(
      id: old.id, type: old.type, title: old.title, content: old.content, plainText: old.plainText,
      tags: old.tags, pinned: old.pinned, groupId: old.groupId, enc: old.enc, version: old.version,
      createdAt: old.createdAt, updatedAt: DateTime.now().toIso8601String(), deletedAt: null,
    ));
    await localdb.enqueue(QueueOp(kind: 'restore', noteId: id));
    schedulePush();
  }

  Future<void> purgeNote(String id) async {
    await localdb.deleteNote(id);
    await localdb.enqueue(QueueOp(kind: 'purge', noteId: id));
    schedulePush();
  }

  Future<void> moveNote(String id, String? groupId) async {
    final old = await localdb.getNote(id);
    if (old == null) return;
    await localdb.upsertNote(old.copyWith(groupId: groupId, updatedAt: DateTime.now().toIso8601String()));
    await localdb.enqueue(QueueOp(kind: 'move', noteId: id, groupId: groupId));
    schedulePush();
  }

  Future<void> emptyTrash() async {
    final all = await localdb.allNotes();
    for (final n in all.where((n) => n.deletedAt != null)) {
      await localdb.deleteNote(n.id);
    }
    await localdb.enqueue(QueueOp(kind: 'emptyTrash'));
    schedulePush();
  }

  String _localId() {
    final r = Random.secure();
    return 'local-${List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join()}';
  }
}

final data = Data.instance;
