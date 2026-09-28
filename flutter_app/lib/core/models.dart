// 数据模型：与 Web 版 lib/types.ts + 服务端契约对齐
// 富文本 content 为 Tiptap JSON 字符串（转换器负责 ↔ AppFlowy）

class Note {
  Note({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.plainText,
    required this.tags,
    required this.pinned,
    required this.groupId,
    required this.enc,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String type; // 'text' | 'card'
  final String title;
  final String content;
  final String plainText;
  final List<String> tags;
  final bool pinned;
  final String? groupId;
  final bool enc; // 卡片是否加密
  final int version;
  final String createdAt;
  final String updatedAt;
  final String? deletedAt;

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        type: (j['type'] as String?) ?? 'text',
        title: (j['title'] as String?) ?? '',
        content: (j['content'] as String?) ?? '',
        plainText: (j['plainText'] as String?) ?? '',
        tags: ((j['tags'] as List?) ?? []).map((e) => e as String).toList(),
        pinned: j['pinned'] == true,
        groupId: j['groupId'] as String?,
        enc: j['enc'] == true,
        version: (j['version'] as num?)?.toInt() ?? 1,
        createdAt: (j['createdAt'] as String?) ?? '',
        updatedAt: (j['updatedAt'] as String?) ?? '',
        deletedAt: j['deletedAt'] as String?,
      );

  String get excerpt => plainText.length > 120 ? plainText.substring(0, 120) : plainText;

  Note copyWith({String? title, String? content, String? plainText, List<String>? tags,
      bool? pinned, String? groupId, int? version, String? updatedAt}) => Note(
        id: id, type: type,
        title: title ?? this.title,
        content: content ?? this.content,
        plainText: plainText ?? this.plainText,
        tags: tags ?? this.tags,
        pinned: pinned ?? this.pinned,
        groupId: groupId ?? this.groupId,
        enc: enc,
        version: version ?? this.version,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt,
      );
}

class Group {
  Group({required this.id, required this.name, required this.parentId, required this.depth});
  final String id;
  final String name;
  final String? parentId;
  final int depth; // 服务端算好，0 起
  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        parentId: j['parentId'] as String?,
        depth: (j['depth'] as num?)?.toInt() ?? 0,
      );
}

class TagCount {
  TagCount({required this.tag, required this.count});
  final String tag;
  final int count;
}

class AppSettings {
  AppSettings({this.themeMode = 'system', this.cardLock = 'keep', this.cardEncrypt = true, this.trashRetentionDays = 30});
  // themeMode: system | light | dark；cardLock: keep | ask
  final String themeMode;
  final String cardLock;
  final bool cardEncrypt;
  final int trashRetentionDays;

  factory AppSettings.fromJson(Map<String, dynamic>? j) => AppSettings(
        themeMode: (j?['themeMode'] as String?) ?? 'system',
        cardLock: (j?['cardLock'] as String?) ?? 'keep',
        cardEncrypt: j?['cardEncrypt'] != false,
        trashRetentionDays: (j?['trashRetentionDays'] as num?)?.toInt() ?? 30,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode,
        'cardLock': cardLock,
        'cardEncrypt': cardEncrypt,
        'trashRetentionDays': trashRetentionDays,
      };
}

class NotePayload {
  NotePayload({
    required this.type,
    required this.title,
    required this.content,
    required this.plainText,
    required this.tags,
    required this.pinned,
    this.groupId,
    this.enc,
    this.expectedVersion,
  });
  final String type;
  final String title;
  final String content;
  final String plainText;
  final List<String> tags;
  final bool pinned;
  final String? groupId;
  final bool? enc;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => {
        'type': type,
        'title': title,
        'content': content,
        'plainText': plainText,
        'tags': tags,
        'pinned': pinned,
        if (groupId != null) 'groupId': groupId,
        if (enc != null) 'enc': enc,
        if (expectedVersion != null) 'expectedVersion': expectedVersion,
      };
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前（今天内）；今年 M月d日；往年 YYYY年M月d日（对齐 Web fmtTime）
String fmtTime(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMilliseconds < 0) return '';
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  if (day == today) return '${diff.inHours} 小时前';
  if (dt.year == now.year) return '${dt.month}月${dt.day}日';
  return '${dt.year}年${dt.month}月${dt.day}日';
}
