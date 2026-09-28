// F0b 编辑器 spike：Tiptap JSON ↔ AppFlowy JSON 往返测试（真实笔记 fixture）
// 验收标准：tt → af → tt 后与原 JSON 语义等价（键序无关；link 的默认 attrs 容错）。
// 运行：dart test test/tiptap_converter_test.dart 或 flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mynotes/editor/tiptap_converter.dart';

/// 规范化：递归排序键、统一 link 标记的默认 attrs、去 null
dynamic canonical(dynamic node) {
  if (node is Map) {
    final out = <String, dynamic>{};
    final keys = node.keys.map((k) => k as String).toList()..sort();
    for (final k in keys) {
      final v = node[k];
      if (v == null) continue;
      out[k] = canonical(v);
    }
    return out;
  }
  if (node is List) return node.map(canonical).toList();
  return node;
}

/// 宽松比较：忽略 link 标记中 target/rel/class 这类 Web 端默认值差异；
/// 标记数组排序（ProseMirror 对 mark 顺序不敏感，AppFlowy delta 合并后顺序必然重排）
dynamic normalizeForCompare(dynamic node) {
  if (node is Map) {
    final out = <String, dynamic>{};
    node.forEach((k, v) {
      if (v == null) return;
      if (k == 'attrs' && node['type'] == 'link') {
        out[k] = {'href': v['href']};
        return;
      }
      out[k] = normalizeForCompare(v);
    });
    if (out['marks'] is List) {
      final marks = (out['marks'] as List).map(_markKey).toList()..sort();
      out['marks'] = marks;
    }
    return out;
  }
  if (node is List) return node.map(normalizeForCompare).toList();
  return node;
}

String _markKey(dynamic mark) => jsonEncode(normalizeForCompare(mark));

void main() {
  // 统一的往返断言：原 → af → 原'，规范化后比较
  void expectRoundtrip(Map<String, dynamic> doc) {
    final back = appflowyToTiptap(tiptapToAppflowy(doc));
    final a = canonical(normalizeForCompare(doc));
    final b = canonical(normalizeForCompare(back));
    expect(b, equals(a),
        reason: '往返后与原 JSON 不等价\n返: ${const JsonEncoder.withIndent(' ').convert(back)}');
  }

  final fixtureDir = Directory('test/fixtures');
  final fixtures = fixtureDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('Tiptap ↔ AppFlowy 往返（真实笔记）', () {
    for (final fixture in fixtures) {
      test(fixture.uri.pathSegments.last, () {
        expectRoundtrip(jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>);
      });
    }
  });

  group('手工构造边界用例', () {
    test('嵌套列表 + 混排待办 + 引用多段', () {
      final doc = {
        'type': 'doc',
        'content': [
          {
            'type': 'bulletList',
            'content': [
              {
                'type': 'listItem',
                'content': [
                  {'type': 'paragraph', 'content': [
                    {'type': 'text', 'text': '外层'},
                  ]},
                  {
                    'type': 'bulletList',
                    'content': [
                      {'type': 'listItem', 'content': [
                        {'type': 'paragraph', 'content': [
                          {'type': 'text', 'text': '内层', 'marks': [{'type': 'bold'}]},
                        ]},
                      ]},
                    ],
                  },
                ],
              },
              {'type': 'listItem', 'content': [
                {'type': 'paragraph', 'content': [
                  {'type': 'text', 'text': '第二项', 'marks': [{'type': 'italic'}]},
                ]},
              ]},
            ],
          },
          {
            'type': 'taskList',
            'content': [
              {'type': 'taskItem', 'attrs': {'checked': true}, 'content': [
                {'type': 'paragraph', 'content': [{'type': 'text', 'text': '已做'}]},
              ]},
              {'type': 'taskItem', 'attrs': {'checked': false}, 'content': [
                {'type': 'paragraph', 'content': [{'type': 'text', 'text': '没做'}]},
              ]},
            ],
          },
          {'type': 'blockquote', 'content': [
            {'type': 'paragraph', 'content': [{'type': 'text', 'text': '引言一'}]},
            {'type': 'paragraph', 'content': [{'type': 'text', 'text': '引言二'}]},
          ]},
          {'type': 'paragraph', 'content': [
            {'type': 'text', 'text': '换行', 'marks': [{'type': 'bold'}]},
            {'type': 'hardBreak'},
            {'type': 'text', 'text': '第二行'},
          ]},
        ],
      };
      expectRoundtrip(doc);
    });

    test('空文档 / 空段落', () {
      final doc = {'type': 'doc', 'content': [
        {'type': 'paragraph'},
        {'type': 'paragraph', 'content': []},
      ]};
      final back = appflowyToTiptap(tiptapToAppflowy(doc));
      // 空段落往返后仍为两个空段落（无 content）
      expect((back['content'] as List).length, 2);
      for (final p in back['content'] as List) {
        expect((p as Map)['type'], 'paragraph');
      }
    });
  });
}
