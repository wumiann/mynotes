// 同步引擎：队列补推 + 拉取合并 + 时机调度（对齐 Web 版 data.ts）
//
// 三种拉取模式（SyncPullMode）：
//   merge        常规同步与首次「合并」策略：push 后三路合并（服务器独有→插入；
//                双方都有→updatedAt 新者胜：服务器新覆盖本地并清其过期队列 op，
//                本地新入队补推走 409 本地胜出）；本地独有跳过（推送由既有队列 op 负责，
//                队列里没有的视为服务器端已删，不复活）
//   uploadOnly   「仅上传（本地为准）」：只推队列，不拉
//   downloadFull 「仅下载（服务器为准）」：清空本地未同步队列后全量替换本地
//
// 丢数据防线：create 的 400/409、update 的二次 409 一律保留 op 中止本轮（绝不静默丢弃）；
// 仅 update/delete 等遇 404（服务器端已删）才安全丢弃。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'localdb.dart';
import 'models.dart';
import 'store.dart';

enum SyncPullMode { merge, uploadOnly, downloadFull }

class SyncState with ChangeNotifier {
  bool syncing = false;
  int pending = 0;
  bool? online; // null=未知
  String lastSync = '';
}

final syncState = SyncState();

/// 一次同步的产出（向导结果页展示用）
class SyncResult {
  int pushed = 0; // 补推队列 op 数
  int pulledNew = 0; // 服务器独有新拉取
  int mergedDiffs = 0; // 双端同存差异（新者胜）处数
  int enqueued = 0; // 合并中因本地较新而入队补推的条数

  bool get hasActivity => pushed > 0 || pulledNew > 0 || mergedDiffs > 0 || enqueued > 0;
}

Timer? _debounce;
Timer? _periodic;
bool _booted = false;
// 配置向导进行中挂起自动同步：登录成功≠策略已选，此时绝不自动合并/全量拉
bool _hold = true;

/// 挂起自动同步（同步配置向导进入时调用）
void holdSync() => _hold = true;

/// 解除挂起并启动周期同步（向导完成 / 已配置用户启动时调用）
void releaseSync() => _hold = false;

/// 登录后启动：立即同步 + 60s 周期 + 前台切换触发
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

/// 立即同步：推队列 → 按模式拉取。silent=不向上抛错（周期触发）
/// 返回 null 表示本次被跳过（未配置/未登录/挂起中/已在同步）
Future<SyncResult?> syncNow({bool silent = false, SyncPullMode mode = SyncPullMode.merge, bool force = false}) async {
  if (!api.configured || !store.authed) return null; // 本地模式：只累积队列，不同步
  if (_hold && !force) return null; // 向导未完成：绝不自动同步
  if (syncState.syncing) return null;
  syncState.syncing = true;
  syncState.notifyListeners();
  final result = SyncResult();
  try {
    result.pushed = await _pushQueue();
    switch (mode) {
      case SyncPullMode.merge:
        result.enqueued = await _mergePull(result);
        if (result.enqueued > 0) {
          // 合并判定本地较新的条目：再推一轮让服务器收到新版本（下轮合并自然收敛）
          await _pushQueue();
        }
      case SyncPullMode.uploadOnly:
        break; // 本地为准：只推不拉
      case SyncPullMode.downloadFull:
        await localdb.clearQueue(); // 本地未同步变更作废（向导中已红字警告）
        result.pulledNew = await _pullFull();
    }
    syncState
      ..online = true
      ..lastSync = DateTime.now().toIso8601String();
    return result;
  } catch (e) {
    debugPrint('SYNC fail: $e');
    syncState.online = false;
    if (!silent) rethrow;
    return null;
  } finally {
    syncState.pending = (await localdb.allQueue()).length;
    syncState.syncing = false;
    syncState.notifyListeners();
  }
}

Future<int> _pushQueue() async {
  final ops = await localdb.allQueue();
  final remap = <String, String>{}; // 本地临时 id → 服务端 id
  var pushed = 0;
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
              // 版本冲突：取服务器当前版本号覆盖写入（本地编辑胜出，
              // 被覆盖内容靠服务端版本历史找回）
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
          await api.emptyTrash();
      }
      await localdb.dequeue(op.id!); // 成功：丢弃
      pushed++;
    } on ApiError catch (e) {
      final safeDrop = switch (op.kind) {
        // 内容类操作绝不静默丢弃：create 丢了=整条笔记消失；update 丢了=编辑丢失
        'create' => false,
        'update' => e.status == 404, // 仅服务器端已删才可弃
        // 非内容操作（删除/恢复/移动等）服务器状态已定或目标无效，可安全弃
        _ => e.status == 404 || e.status == 409 || e.status == 400,
      };
      if (safeDrop) {
        await localdb.dequeue(op.id!);
      } else {
        rethrow; // 保留 op，中止本轮，下次恢复网络/手动同步续推
      }
    }
  }
  return pushed;
}

/// 合并拉取（常规同步核心）：返回因「本地较新」而入队补推的条数
Future<int> _mergePull(SyncResult result) async {
  final serverNotes = await api.listNotesFull();
  final groups = await api.listGroups();
  await localdb.replaceAllGroups(groups);

  final localById = {for (final n in await localdb.allNotes()) n.id: n};
  final inserts = <Note>[];
  final overwrites = <Note>[];
  final pushIds = <String>[];
  for (final sn in serverNotes) {
    final decision = decideMerge(localById[sn.id], sn);
    switch (decision) {
      case MergeDecision.insertLocal:
        inserts.add(sn);
      case MergeDecision.overwriteLocal:
        overwrites.add(sn);
        await localdb.dequeueByNote(sn.id); // 服务器胜出：本地过期 op 作废
      case MergeDecision.enqueuePush:
        pushIds.add(sn.id);
      case MergeDecision.skip:
        break;
    }
  }
  await localdb.upsertNotes([...inserts, ...overwrites]);

  var enqueued = 0;
  for (final id in pushIds) {
    if ((await localdb.queueForNote(id)).isNotEmpty) continue; // 已有待推送 op
    final n = localById[id]!;
    if (n.deletedAt != null) {
      await localdb.enqueue(QueueOp(kind: 'delete', noteId: id));
    } else {
      await localdb.enqueue(QueueOp(kind: 'update', noteId: id, payload: _payloadOf(n).toJson()));
    }
    enqueued++;
  }

  // 刷新内存视图（与全量拉取尾部一致，但数据源是合并后的本地库）
  final merged = await localdb.allNotes();
  store.notes = applyViewLocal(merged);
  store.groups = groups;
  await hydrateCardExcerpts();
  store.notifyListeners();
  await refreshTagsFromLocal();

  result
    ..pulledNew = inserts.length
    ..mergedDiffs = overwrites.length + enqueued;
  return enqueued;
}

/// 三路合并判定（纯函数，可单测）
MergeDecision decideMerge(Note? local, Note server) {
  if (local == null) return MergeDecision.insertLocal;
  final cmp = server.updatedAt.compareTo(local.updatedAt);
  if (cmp > 0) return MergeDecision.overwriteLocal;
  if (cmp < 0) return MergeDecision.enqueuePush;
  return MergeDecision.skip;
}

enum MergeDecision { insertLocal, overwriteLocal, enqueuePush, skip }

NotePayload _payloadOf(Note n) => NotePayload(
      type: n.type,
      title: n.title,
      content: n.content,
      plainText: n.plainText,
      tags: n.tags,
      pinned: n.pinned,
      groupId: n.groupId,
      enc: n.enc,
    );

/// 全量替换本地（仅「仅下载」策略使用：服务器为准，本地未同步变更已清）。返回重建条数
Future<int> _pullFull() async {
  final notes = await api.listNotesFull();
  final groups = await api.listGroups();
  await localdb.replaceAllNotes(notes);
  await localdb.replaceAllGroups(groups);
  store.notes = applyViewLocal(notes);
  store.groups = groups;
  await hydrateCardExcerpts();
  store.notifyListeners();
  await refreshTagsFromLocal();
  return notes.length;
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
