// F0 UI 验证页：合成 Tiptap 文档（覆盖全部节点类型）→ AppFlowy 渲染 → 编辑 →
// 「往返校验」按钮把当前文档转回 Tiptap 与初始文档比对（规范化）。
// 这是 spike 验证页，正式 UI 在 F1 重写。
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import 'editor/code_block_component.dart';
import 'editor/tiptap_converter.dart';

// 合成文档：不使用真实用户数据
final Map<String, dynamic> kSampleTiptap = {
  'type': 'doc',
  'content': [
    {
      'type': 'heading',
      'attrs': {'level': 2},
      'content': [
        {'type': 'text', 'text': 'F0 编辑器验证'}
      ]
    },
    {
      'type': 'paragraph',
      'content': [
        {'type': 'text', 'text': '普通文字，'},
        {'type': 'text', 'text': '加粗', 'marks': [{'type': 'bold'}]},
        {'type': 'text', 'text': '、'},
        {'type': 'text', 'text': '斜体', 'marks': [{'type': 'italic'}]},
        {'type': 'text', 'text': '、'},
        {'type': 'text', 'text': '下划线', 'marks': [{'type': 'underline'}]},
        {'type': 'text', 'text': '、'},
        {'type': 'text', 'text': '删除线', 'marks': [{'type': 'strike'}]},
        {'type': 'text', 'text': '、'},
        {'type': 'text', 'text': '行内代码', 'marks': [{'type': 'code'}]},
        {'type': 'text', 'text': '、'},
        {
          'type': 'text',
          'text': '链接',
          'marks': [
            {
              'type': 'link',
              'attrs': {
                'href': 'https://example.com',
                'target': '_blank',
                'rel': 'noopener noreferrer nofollow',
                'class': null
              }
            }
          ]
        },
        {'type': 'hardBreak'},
        {'type': 'text', 'text': '换行后的第二行'}
      ]
    },
    {
      'type': 'bulletList',
      'content': [
        {
          'type': 'listItem',
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '无序列表一'}
              ]
            }
          ]
        },
        {
          'type': 'listItem',
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '无序列表二'}
              ]
            },
            {
              'type': 'bulletList',
              'content': [
                {
                  'type': 'listItem',
                  'content': [
                    {
                      'type': 'paragraph',
                      'content': [
                        {'type': 'text', 'text': '嵌套子项'}
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    },
    {
      'type': 'orderedList',
      'content': [
        {
          'type': 'listItem',
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '有序一'}
              ]
            }
          ]
        },
        {
          'type': 'listItem',
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '有序二'}
              ]
            }
          ]
        }
      ]
    },
    {
      'type': 'taskList',
      'content': [
        {
          'type': 'taskItem',
          'attrs': {'checked': true},
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '已完成的待办'}
              ]
            }
          ]
        },
        {
          'type': 'taskItem',
          'attrs': {'checked': false},
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '未完成的待办'}
              ]
            }
          ]
        }
      ]
    },
    {
      'type': 'blockquote',
      'content': [
        {
          'type': 'paragraph',
          'content': [
            {'type': 'text', 'text': '引用段落一'}
          ]
        },
        {
          'type': 'paragraph',
          'content': [
            {'type': 'text', 'text': '引用段落二'}
          ]
        }
      ]
    },
    {
      'type': 'paragraph',
      'content': [
        {'type': 'text', 'text': '图片块（占位图）下方：'}
      ]
    },
    {
      'type': 'image',
      'attrs': {
        'src': 'https://dummyimage.com/320x120/4a90d9/fff&text=MyNotes',
        'alt': null,
        'title': null
      }
    },
    {
      'type': 'paragraph',
      'content': [
        {'type': 'text', 'text': '代码块：'}
      ]
    },
    {
      'type': 'codeBlock',
      'attrs': {'language': null},
      'content': [
        {'type': 'text', 'text': 'fn main() {\n    println!("代码块内换行");\n}'}
      ]
    },
  ]
};

void main() {
  runApp(const F0App());
}

class F0App extends StatelessWidget {
  const F0App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyNotes F0',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const F0EditorPage(),
    );
  }
}

class F0EditorPage extends StatefulWidget {
  const F0EditorPage({super.key});

  @override
  State<F0EditorPage> createState() => _F0EditorPageState();
}

class _F0EditorPageState extends State<F0EditorPage> {
  late final EditorState editorState;
  String result = '点「往返校验」检查当前文档转回 Tiptap 是否与初始一致';

  @override
  void initState() {
    super.initState();
    final af = tiptapToAppflowy(kSampleTiptap);
    // Document.fromJson 期望 {'document': root} 包装
    editorState = EditorState(document: Document.fromJson({'document': af}));
  }

  void verifyRoundtrip() {
    try {
      final afNow = editorState.document.toJson();
      // Document.toJson = {'document': root}
      final root = (afNow['document'] ?? afNow) as Map<String, dynamic>;
      final back = appflowyToTiptap(root);
      final a = canonicalize(kSampleTiptap);
      final b = canonicalize(back);
      setState(() {
        result = identicalJson(a, b)
            ? 'PASS ✓ 往返一致（节点数 ${countNodes(back)}）'
            : 'FAIL ✗ 往返后不一致\n${firstDiff(a, b)}';
      });
    } catch (e) {
      setState(() => result = 'FAIL ✗ 转换异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('F0 编辑器验证'),
        actions: [
          TextButton(
            onPressed: verifyRoundtrip,
            child: const Text('往返校验'),
          ),
          TextButton(
            onPressed: dumpJson,
            child: const Text('导出JSON'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AppFlowyEditor(
              editorState: editorState,
              editorStyle: const EditorStyle.mobile(),
              blockComponentBuilders: {
                ...standardBlockComponentBuilderMap,
                CodeBlockKeys.type: CodeBlockComponentBuilder(),
              },
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.black12,
            padding: const EdgeInsets.all(10),
            child: Text(result, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  void dumpJson() {
    final afNow = editorState.document.toJson();
    final root = (afNow['document'] ?? afNow) as Map<String, dynamic>;
    final back = appflowyToTiptap(root);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Tiptap JSON')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(back),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
    ));
  }
}

// ---------- 比较辅助（与测试同语义的规范化） ----------

dynamic canonicalize(dynamic node) {
  if (node is Map) {
    final out = <String, dynamic>{};
    final keys = node.keys.map((k) => k as String).toList()..sort();
    for (final k in keys) {
      final v = node[k];
      if (v == null) continue;
      if (k == 'attrs' && node['type'] == 'link') {
        out[k] = {'href': v['href']};
        continue;
      }
      out[k] = canonicalize(v);
    }
    if (out['marks'] is List) {
      final marks = (out['marks'] as List).map((m) => jsonEncode(canonicalize(m))).toList()..sort();
      out['marks'] = marks;
    }
    return out;
  }
  if (node is List) return node.map(canonicalize).toList();
  return node;
}

bool identicalJson(dynamic a, dynamic b) => jsonEncode(a) == jsonEncode(b);

int countNodes(dynamic n) => n is Map
    ? 1 + (n['content'] as List? ?? []).fold<int>(0, (p, c) => p + countNodes(c))
    : n is List
        ? n.fold<int>(0, (p, c) => p + countNodes(c))
        : 0;

String firstDiff(dynamic a, dynamic b, [String path = r'$']) {
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      if (!b.containsKey(k)) return '$path.$k 缺失';
      if (!a.containsKey(k)) return '$path.$k 多出';
      final d = firstDiff(a[k], b[k], '$path.$k');
      if (d.isNotEmpty) return d;
    }
    return '';
  }
  if (a is List && b is List) {
    if (a.length != b.length) return '$path 长度 ${a.length}≠${b.length}';
    for (var i = 0; i < a.length; i++) {
      final d = firstDiff(a[i], b[i], '$path[$i]');
      if (d.isNotEmpty) return d;
    }
    return '';
  }
  return a == b ? '' : '$path: $a ≠ $b';
}
