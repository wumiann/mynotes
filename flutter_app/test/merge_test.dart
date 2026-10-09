// 三路合并判定单测：decideMerge（本地优先改造的核心纯函数）
import 'package:flutter_test/flutter_test.dart';
import 'package:mynotes/core/models.dart';
import 'package:mynotes/core/sync.dart';

Note note(String id, String updatedAt, {bool deleted = false}) => Note(
      id: id,
      type: 'text',
      title: 't-$id',
      content: '{"type":"doc"}',
      plainText: 'p-$id',
      tags: const [],
      pinned: false,
      groupId: null,
      enc: false,
      version: 1,
      createdAt: '2026-01-01T00:00:00.000',
      updatedAt: updatedAt,
      deletedAt: deleted ? updatedAt : null,
    );

void main() {
  group('decideMerge 三路合并判定', () {
    test('本地没有该笔记（服务器独有）→ 插入本地', () {
      expect(decideMerge(null, note('a', '2026-10-09T10:00:00.000')),
          MergeDecision.insertLocal);
    });

    test('服务器较新 → 覆盖本地（服务器胜出）', () {
      final d = decideMerge(
          note('a', '2026-10-09T08:00:00.000'), note('a', '2026-10-09T09:00:00.000'));
      expect(d, MergeDecision.overwriteLocal);
    });

    test('本地较新（离线期间的修改）→ 入队补推（本地胜出）', () {
      final d = decideMerge(
          note('a', '2026-10-09T12:00:00.000'), note('a', '2026-10-09T09:00:00.000'));
      expect(d, MergeDecision.enqueuePush);
    });

    test('两端时间完全相同 → 跳过', () {
      final d = decideMerge(
          note('a', '2026-10-09T09:00:00.000'), note('a', '2026-10-09T09:00:00.000'));
      expect(d, MergeDecision.skip);
    });

    test('本地已删除但服务器更新 → 仍以服务器为准覆盖（恢复由服务器端决定）', () {
      final d = decideMerge(
          note('a', '2026-10-09T08:00:00.000', deleted: true), note('a', '2026-10-09T09:00:00.000'));
      expect(d, MergeDecision.overwriteLocal);
    });

    test('本地删除时间更新 → 入队补推删除操作', () {
      final d = decideMerge(
          note('a', '2026-10-09T12:00:00.000', deleted: true), note('a', '2026-10-09T09:00:00.000'));
      expect(d, MergeDecision.enqueuePush);
    });

    test('毫秒级时间差也能比较（ISO 字符串序）', () {
      final d = decideMerge(
          note('a', '2026-10-09T09:00:00.000'), note('a', '2026-10-09T09:00:00.001'));
      expect(d, MergeDecision.overwriteLocal);
    });
  });
}
