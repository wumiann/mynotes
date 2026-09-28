// 全局状态：视图/列表数据/登录态，ChangeNotifier 单例
import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

enum NoteView { all, group, ungrouped, pinned, trash, tag }

class AppState with ChangeNotifier {
  // 视图
  NoteView view = NoteView.all;
  String? activeGroupId;
  String? activeTag;
  String search = '';

  // 数据
  List<Note> notes = [];
  List<Group> groups = [];
  List<TagCount> tagList = [];
  bool loadingList = false;

  // 登录态
  bool authed = false;
  AppSettings settings = AppSettings();

  String get viewTitle {
    switch (view) {
      case NoteView.all: return '全部笔记';
      case NoteView.group:
        return groups.where((g) => g.id == activeGroupId).map((g) => g.name).followedBy(['分组']).first;
      case NoteView.ungrouped: return '未分组';
      case NoteView.pinned: return '★ 置顶';
      case NoteView.trash: return '回收站';
      case NoteView.tag: return '# $activeTag';
    }
  }

  void setView(NoteView v, {String? groupId, String? tag}) {
    view = v;
    activeGroupId = groupId;
    activeTag = tag;
    notifyListeners();
  }
}

final store = AppState();

/// 刷新列表（保持视图条件），并顺带刷新分组
Future<void> refreshNotes() async {
  if (!store.loadingList) {
    store.loadingList = true;
    store.notifyListeners();
  }
  try {
    final notes = await api.listNotes(
      q: store.search.trim().isEmpty ? null : store.search.trim(),
      tag: store.view == NoteView.tag ? store.activeTag : null,
      pinned: store.view == NoteView.pinned ? true : null,
      trash: store.view == NoteView.trash ? true : null,
      group: switch (store.view) {
        NoteView.group => store.activeGroupId,
        NoteView.ungrouped => 'none',
        _ => null,
      },
    );
    store.notes = notes;
    store.loadingList = false;
    store.notifyListeners();
  } catch (e) {
    store.loadingList = false;
    store.notifyListeners();
    rethrow;
  }
}

Future<void> refreshGroups() async {
  try {
    store.groups = await api.listGroups();
    store.notifyListeners();
  } catch (_) {
    // 分组刷新失败不阻塞主流程
  }
}

/// 标签列表：全量笔记统计（与 Web 端一致——客户端算）
Future<void> refreshTags() async {
  try {
    final all = await api.listNotes();
    final m = <String, int>{};
    for (final n in all) {
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
  } catch (_) {}
}
