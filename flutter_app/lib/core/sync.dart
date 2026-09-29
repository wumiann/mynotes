// 同步引擎：队列补推 + 全量拉取 + 时机调度（对齐 Web 版 data.ts）
// 冲突语义：update 409 → 取服务器版本覆盖重写（后写胜出，被覆盖内容靠服务端版本历史找回）
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'localdb.dart';
import 'models.dart';
import 'store.dart';

class SyncState with ChangeNotifier {
  bool syncing = false;
  int pending = 0;
  bool? online; // null=未知
  String lastSync = '';
}

final syncState = SyncState();

Timer? _debounce;
Timer? _periodic;
bool _booted = false;

/// 登录后启动：首次全量 + 60s 周期 + 前台切换
void bootSync() {
  if (_booted) return;
  _booted = true;
  void sync() => syncNow(silent: true);
  WidgetsBindingInstanceObserverHolder.instance.addListener(sync);
  _periodic = Timer.periodic(const Duration(seconds: 60), (_) => sync());
  unawaited(syncNow());
}

/// 修改后 2 秒触发补推（Web 版同款节律）
void schedulePush() {
  _debounce?.cancel();
  _debounce = Timer(const Duration(seconds: 2), () => syncNow(silent: true));
}

/// 立即同步：推队列 → 全量拉取。silent=不弹错误提示（周期触发）
Future<void> syncNow({bool silent = false}) async {
  if (syncState.syncing) return;
  syncState.syncing = true;
  syncState.notifyListeners();
  try {
    await _pushQueue();
    await _pullFull();
    syncState
      ..online = true
      ..lastSync = DateTime.now().toIso8601String();
  } catch (e) {
    debugPrint('SYNC fail: $e');
    syncState.online = false;
    if (!silent) rethrow;
  } finally {
    syncState.pending = (await localdb.allQueue()).length;
    syncState.syncing = false;
    syncState.notifyListeners();
  }
}

Future<void> _pushQueue() async {
  final ops = await localdb.allQueue();
  final remap = <String, String>{}; // 本地临时 id → 服务端 id
  for (final op in ops) {
    final noteId = op.noteId != null ? (remap[op.noteId] ?? op.noteId) : null;
    try {
      switch (op.kind) {
        case 'create' when noteId != null:
          final res = await api.createNote(NotePayloadFromJson.fromJson(op.payload!));
          remap[op.noteId!] = res.id;
          await localdb.updateQueueNoteId(op.noteId!, res.id);
          // 本地缓存的临时行替换为服务端行
          await localdb.deleteNote(op.noteId!);
          await localdb.upsertNote(res);
        case 'update' when noteId != null:
          final local = await localdb.getNote(noteId);
          try {
            await api.updateNote(noteId, NotePayloadFromJson.fromJson({
              ...op.payload!,
              'expectedVersion': local?.version ?? 1,
            }));
          } on ApiError catch (e) {
            if (e.status == 409) {
              // 版本冲突：取服务器当前版本号覆盖写入（本地编辑胜出）
              final server = await api.getNote(noteId);
              await api.updateNote(noteId, NotePayloadFromJson.fromJson({
                ...op.payload!,
                'expectedVersion': server.version,
              }));
            } else {
              rethrow;
            }
          }
        case 'delete' when noteId != null:
          await api.deleteNote(noteId);
        case 'restore' when noteId != null:
          await api.restoreNote(noteId);
        case 'purge' when noteId != null:
          await api.purgeNote(noteId);
        case 'move' when noteId != null:
          await api.moveNote(noteId, op.groupId);
        case 'emptyTrash':
          await _emptyTrashRemote();
      }
      await localdb.dequeue(op.id!); // 成功：丢弃
    } on ApiError catch (e) {
      if (e.status == 409 || e.status == 404 || e.status == 400) {
        // 服务器胜出/笔记已不存在：丢弃操作（全量拉取会覆盖本地）
        await localdb.dequeue(op.id!);
      } else {
        rethrow; // 网络/服务器错误：中止本轮，留待下次
      }
    }
  }
}

Future<void> _emptyTrashRemote() async {
  // 服务端没有清空回收站专接口？有：POST /api/trash/empty
  await api.emptyTrash();
}

Future<void> _pullFull() async {
  final notes = await api.listNotesFull();
  final groups = await api.listGroups();
  await localdb.replaceAllNotes(notes);
  await localdb.replaceAllGroups(groups);
  store.notes = _applyView(notes);
  store.groups = groups;
  await hydrateCardExcerpts();
  store.notifyListeners();
  await refreshTagsFromLocal();
}

/// 按当前视图过滤全量（与 refreshNotes 的服务端过滤等价的本地版）
List<Note> applyViewLocal(List<Note> all) => _applyView(all);

List<Note> _applyView(List<Note> all) {
  final q = store.search.trim();
  Iterable<Note> out = all;
  if (store.view == NoteView.trash) {
    out = out.where((n) => n.deletedAt != null);
  } else if (store.view == NoteView.pinned) {
    out = out.where((n) => n.deletedAt == null && n.pinned);
  } else if (store.view == NoteView.tag) {
    out = out.where((n) => n.deletedAt == null && n.tags.contains(store.activeTag));
  } else if (store.view == NoteView.group) {
    final ids = descendantIds(store.activeGroupId);
    out = out.where((n) => n.deletedAt == null && n.groupId != null && ids.contains(n.groupId));
  } else if (store.view == NoteView.ungrouped) {
    out = out.where((n) => n.deletedAt == null && n.groupId == null);
  } else {
    out = out.where((n) => n.deletedAt == null);
  }
  if (q.isNotEmpty) {
    out = out.where((n) => n.title.contains(q) || n.plainText.contains(q));
  }
  // 置顶在前 + 时间倒序（对齐 Web 服务端排序）
  final list = out.toList()
    ..sort((a, b) {
      final pin = (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0);
      return pin != 0 ? pin : b.updatedAt.compareTo(a.updatedAt);
    });
  return list;
}

Set<String> descendantIds(String? rootId) {
  if (rootId == null) return {};
  final out = <String>{rootId};
  var frontier = [rootId];
  while (frontier.isNotEmpty) {
    final next = store.groups.where((g) => g.parentId != null && frontier.contains(g.parentId)).map((g) => g.id).toList();
    out.addAll(next);
    frontier = next;
  }
  return out;
}

/// 本地全量统计标签（离线也能刷新标签区）
Future<void> refreshTagsFromLocal() async {
  final all = await localdb.allNotes();
  final m = <String, int>{};
  for (final n in all.where((n) => n.deletedAt == null)) {
    for (final t in n.tags) {
      m[t] = (m[t] ?? 0) + 1;
    }
  }
  final list = m.entries.map((e) => TagCount(tag: e.key, count: e.value)).toList();
  list.sort((a, b) {
    final c = b.count.compareTo(a.count);
    return c != 0 ? c : a.tag.compareTo(b.tag);
  });
  store.tagList = list;
  store.notifyListeners();
}

/// 前台切换监听（生命周期）
class WidgetsBindingInstanceObserverHolder with ChangeNotifier {
  WidgetsBindingInstanceObserverHolder._() {
    WidgetsBinding.instance.addObserver(_Observer(this));
  }
  static final instance = WidgetsBindingInstanceObserverHolder._();
  void onResumed() => notifyListeners();
}

class _Observer with WidgetsBindingObserver {
  _Observer(this.owner);
  final WidgetsBindingInstanceObserverHolder owner;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) owner.onResumed();
  }
}

final localdb = LocalDb.instance;
