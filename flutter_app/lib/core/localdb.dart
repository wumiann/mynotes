// 本地数据库（离线缓存 + 变更队列）：sqflite
// 表：notes（全量缓存）/ groups / kv（设置等）/ queue（待推送操作）
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final path = '${await getDatabasesPath()}/mynotes.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            plain_text TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '[]',
            pinned INTEGER NOT NULL DEFAULT 0,
            group_id TEXT,
            enc INTEGER NOT NULL DEFAULT 0,
            version INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT '',
            deleted_at TEXT
          )
        ''');
        await db.execute('CREATE TABLE groups (id TEXT PRIMARY KEY, name TEXT, parent_id TEXT, depth INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('''
          CREATE TABLE queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            note_id TEXT,
            payload TEXT,
            group_id TEXT,
            seq INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  // ---------- notes ----------
  Future<List<Note>> allNotes() async {
    final rows = await (await db).query('notes', orderBy: 'updated_at DESC');
    return rows.map(_noteFromRow).toList();
  }

  Future<Note?> getNote(String id) async {
    final rows = await (await db).query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _noteFromRow(rows.first);
  }

  Future<void> upsertNote(Note n) async {
    await (await db).insert('notes', _noteToRow(n), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertNotes(List<Note> notes) async {
    final d = await db;
    final batch = d.batch();
    for (final n in notes) {
      batch.insert('notes', _noteToRow(n), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> replaceAllNotes(List<Note> notes) async {
    final d = await db;
    final batch = d.batch();
    batch.delete('notes');
    for (final n in notes) {
      batch.insert('notes', _noteToRow(n));
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteNote(String id) async {
    await (await db).delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- groups ----------
  Future<List<Group>> allGroups() async {
    final rows = await (await db).query('groups', orderBy: 'depth, name');
    return rows
        .map((r) => Group(
              id: r['id'] as String,
              name: (r['name'] ?? '') as String,
              parentId: r['parent_id'] as String?,
              depth: (r['depth'] as int?) ?? 0,
            ))
        .toList();
  }

  Future<void> replaceAllGroups(List<Group> groups) async {
    final d = await db;
    final batch = d.batch();
    batch.delete('groups');
    for (final g in groups) {
      batch.insert('groups', {'id': g.id, 'name': g.name, 'parent_id': g.parentId, 'depth': g.depth});
    }
    await batch.commit(noResult: true);
  }

  // ---------- kv ----------
  Future<String?> getKv(String k) async {
    final rows = await (await db).query('kv', where: 'k = ?', whereArgs: [k], limit: 1);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  Future<void> setKv(String k, String v) async {
    await (await db).insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------- queue ----------
  Future<void> enqueue(QueueOp op) async {
    final seqRow = await (await db).rawQuery('SELECT COALESCE(MAX(seq), 0) + 1 AS s FROM queue');
    final seq = (seqRow.first['s'] as int?) ?? 1;
    await (await db).insert('queue', {
      'kind': op.kind,
      'note_id': op.noteId,
      'payload': op.payload != null ? jsonEncode(op.payload) : null,
      'group_id': op.groupId,
      'seq': seq,
    });
  }

  Future<List<QueueOp>> allQueue() async {
    final rows = await (await db).query('queue', orderBy: 'seq ASC');
    return rows
        .map((r) => QueueOp(
              id: r['id'] as int,
              kind: r['kind'] as String,
              noteId: r['note_id'] as String?,
              payload: r['payload'] != null ? jsonDecode(r['payload'] as String) as Map<String, dynamic> : null,
              groupId: r['group_id'] as String?,
            ))
        .toList();
  }

  Future<void> dequeue(int id) async {
    await (await db).delete('queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateQueueNoteId(String oldId, String newId) async {
    await (await db).update('queue', {'note_id': newId}, where: 'note_id = ?', whereArgs: [oldId]);
  }

  Map<String, dynamic> _noteToRow(Note n) => {
        'id': n.id,
        'type': n.type,
        'title': n.title,
        'content': n.content,
        'plain_text': n.plainText,
        'tags': jsonEncode(n.tags),
        'pinned': n.pinned ? 1 : 0,
        'group_id': n.groupId,
        'enc': n.enc ? 1 : 0,
        'version': n.version,
        'created_at': n.createdAt,
        'updated_at': n.updatedAt,
        'deleted_at': n.deletedAt,
      };

  Note _noteFromRow(Map<String, Object?> r) => Note(
        id: r['id'] as String,
        type: r['type'] as String,
        title: r['title'] as String,
        content: r['content'] as String,
        plainText: r['plain_text'] as String,
        tags: ((jsonDecode(r['tags'] as String) as List?) ?? []).map((e) => e as String).toList(),
        pinned: (r['pinned'] as int?) == 1,
        groupId: r['group_id'] as String?,
        enc: (r['enc'] as int?) == 1,
        version: (r['version'] as int?) ?? 1,
        createdAt: r['created_at'] as String,
        updatedAt: r['updated_at'] as String,
        deletedAt: r['deleted_at'] as String?,
      );
}

/// 变更队列操作（对齐 Web 版 QueueOp：create/update/delete/restore/purge/move/emptyTrash）
class QueueOp {
  QueueOp({required this.kind, this.noteId, this.payload, this.groupId, this.id});
  final int? id; // 行 id（推送后删除用）
  final String kind;
  final String? noteId;
  final Map<String, dynamic>? payload; // NotePayload.toJson
  final String? groupId;
}
