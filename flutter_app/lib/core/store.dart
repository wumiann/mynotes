// 全局状态：视图/列表数据/登录态，ChangeNotifier 单例
import 'package:flutter/foundation.dart';

import 'api.dart';
import 'sync.dart';
import 'crypto.dart';
import 'data.dart';
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

  // 解锁后缓存：加密卡 id → 解密出的摘要（首套账号）
  Map<String, String> cardExcerpts = {};

  bool get vaultUnlocked => Vault.instance.unlocked;

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
    // 列表数据按视图在本地过滤，切视图必须重载（store.notes 仍是旧视图的缓存）
    refreshNotes().catchError((_) {});
  }
}

final store = AppState();

/// 刷新列表（保持视图条件），并顺带刷新分组
int _refreshSeq = 0; // 并发守卫：只有最新一次请求的结果可写回，防止旧响应覆盖新数据
Future<void> refreshNotes() async {
  final seq = ++_refreshSeq;
  if (!store.loadingList) {
    store.loadingList = true;
    store.notifyListeners();
  }
  try {
    // 本地优先：视图过滤在本地做（数据由同步引擎维护）
    final notes = await data.listNotes();
    if (seq != _refreshSeq) return; // 已有更新的请求在途，丢弃本次结果
    store.notes = notes;
    await hydrateCardExcerpts(); // 已解锁时解密加密卡摘要（内部有 unlocked 守卫）
    store.loadingList = false;
    store.notifyListeners();
  } catch (e) {
    if (seq != _refreshSeq) return;
    store.loadingList = false;
    store.notifyListeners();
    rethrow;
  }
}

Future<void> refreshGroups() async {
  // 分组来自本地库（同步引擎更新）
  store.groups = await localdb.allGroups();
  store.notifyListeners();
}

/// 标签列表：本地全量统计
Future<void> refreshTags() => refreshTagsFromLocal();

// ---------- 密码卡片解锁（对齐 Web store.ts 的 unlockVault/lockVault） ----------

/// 解锁：派生 encKey（kdfSalt2）并解密当前列表加密卡的摘要
Future<void> unlockVault(String password) async {
  final username = api.username;
  if (username == null) throw Exception('未登录');
  final salts = await api.getSalts(username);
  await Vault.instance.unlock(password, salts['kdfSalt2'] as String);
  await hydrateCardExcerpts();
  store.notifyListeners();
}

/// 锁定：清密钥与摘要缓存
void lockVault() {
  Vault.instance.lock();
  store.cardExcerpts = {};
  store.notifyListeners();
}

/// 解密当前列表中加密卡的摘要（对齐 Web hydrateCardTitles）
Future<void> hydrateCardExcerpts() async {
  if (!Vault.instance.unlocked) return;
  for (final n in store.notes) {
    if (n.type == 'card' && n.enc && n.content.isNotEmpty) {
      try {
        final plain = Vault.instance.decrypt(n.content);
        final card = CardFields.fromJsonString(plain);
        store.cardExcerpts[n.id] = card.excerptFor();
      } catch (_) {
        // 解密失败（密钥不匹配）：摘要保持「解锁后查看」
      }
    }
  }
}
