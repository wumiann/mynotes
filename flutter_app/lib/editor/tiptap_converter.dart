// Tiptap(ProseMirror) JSON ↔ AppFlowy Editor JSON 双向转换器
// 目标：Web 版笔记内容（Tiptap JSON）在 Flutter 端无损编辑后转回，Web 端可直接打开。
// 结构差异要点：Tiptap 列表/引用/待办是嵌套模型（一个父节点包多个子项），
// AppFlowy 是扁平模型（每项一个同级节点）——正向展开、反向合并相邻同类节点。
// 节点覆盖：doc/paragraph/heading/bulletList/orderedList/taskList/blockquote/
// codeBlock/image/hardBreak + marks bold/italic/underline/strike/code/link。
library;

class TiptapConvertException implements Exception {
  TiptapConvertException(this.message, this.node);
  final String message;
  final Map<String, dynamic> node;
  @override
  String toString() => 'TiptapConvertException: $message\nnode=$node';
}

/// Tiptap JSON → AppFlowy JSON
Map<String, dynamic> tiptapToAppflowy(Map<String, dynamic> doc) {
  if (doc['type'] != 'doc') {
    throw TiptapConvertException('根节点必须是 doc', doc);
  }
  final children = <Map<String, dynamic>>[];
  for (final node in doc['content'] as List? ?? []) {
    children.addAll(_ttToAfList(node as Map<String, dynamic>));
  }
  // 空文档补一个空段落：AppFlowy 对零子节点的页面不渲染任何内容（新建笔记传空 doc 会整页空白）
  if (children.isEmpty) children.add(_afBlock('paragraph', delta: []));
  return {'type': 'page', 'children': children};
}

List<Map<String, dynamic>> _ttToAfList(Map<String, dynamic> node) {
  final type = node['type'] as String;
  switch (type) {
    case 'paragraph':
      return [_afBlock('paragraph', delta: _ttRunsToDelta(node['content']))];
    case 'heading':
      final attrs = node['attrs'] as Map<String, dynamic>? ?? {};
      return [
        _afBlock('heading', data: {
          'level': (attrs['level'] as num?)?.toInt() ?? 2,
          'delta': _ttRunsToDelta(node['content']),
        }),
      ];
    case 'bulletList':
      return _afListItems(node, 'bulleted_list');
    case 'orderedList':
      return _afListItems(node, 'numbered_list');
    case 'taskList':
      final items = <Map<String, dynamic>>[];
      for (final item in node['content'] as List? ?? []) {
        final m = item as Map<String, dynamic>;
        final attrs = m['attrs'] as Map<String, dynamic>? ?? {};
        final para = _firstParagraph(m['content']);
        items.add(_afBlock('todo_list', data: {
          'checked': attrs['checked'] == true,
          'delta': para != null ? _ttRunsToDelta(para['content']) : [],
        }));
      }
      return items;
    case 'blockquote':
      return (node['content'] as List? ?? [])
          .map((p) => _afBlock('quote', delta: _ttRunsToDelta((p as Map<String, dynamic>)['content'])))
          .toList();
    case 'codeBlock':
      return [_afBlock('code_block', delta: _ttRunsToDelta(node['content']))];
    case 'image':
      final attrs = node['attrs'] as Map<String, dynamic>? ?? {};
      return [
        {
          'type': 'image',
          'data': {
            'url': attrs['src'] ?? '',
            'align': 'center',
            if (attrs['width'] != null) 'width': attrs['width'],
            if (attrs['height'] != null) 'height': attrs['height'],
          },
        },
      ];
    default:
      throw TiptapConvertException('不支持的 Tiptap 节点类型: $type', node);
  }
}

Map<String, dynamic> _afBlock(String type, {List<Map<String, dynamic>>? delta, Map<String, dynamic>? data}) {
  return {
    'type': type,
    'data': {if (delta != null) 'delta': delta, ...?data},
  };
}

Map<String, dynamic>? _firstParagraph(dynamic content) {
  for (final n in content as List? ?? []) {
    if ((n as Map<String, dynamic>)['type'] == 'paragraph') return n;
  }
  return null;
}

// Tiptap 列表 → af 列表项序列；listItem 首段为文本，其余内容转嵌套 children
List<Map<String, dynamic>> _afListItems(Map<String, dynamic> list, String afType) {
  final items = <Map<String, dynamic>>[];
  for (final item in list['content'] as List? ?? []) {
    final m = item as Map<String, dynamic>;
    Map<String, dynamic>? textPara;
    final nested = <Map<String, dynamic>>[];
    for (final n in m['content'] as List? ?? []) {
      final c = n as Map<String, dynamic>;
      if (c['type'] == 'paragraph' && textPara == null) {
        textPara = c;
      } else {
        nested.addAll(_ttToAfList(c));
      }
    }
    items.add({
      'type': afType,
      'data': {'delta': textPara != null ? _ttRunsToDelta(textPara['content']) : []},
      if (nested.isNotEmpty) 'children': nested,
    });
  }
  return items;
}

/// AppFlowy JSON → Tiptap JSON；相邻同类列表/待办/引用合并回单个嵌套父节点
Map<String, dynamic> appflowyToTiptap(Map<String, dynamic> af) {
  if (af['type'] != 'page') {
    throw TiptapConvertException('根节点必须是 page', af);
  }
  final children = (af['children'] as List? ?? []).cast<Map<String, dynamic>>();
  final content = <Map<String, dynamic>>[];
  var i = 0;
  while (i < children.length) {
    final type = children[i]['type'] as String;
    final parentType = _groupableParent(type);
    if (parentType != null) {
      final group = <Map<String, dynamic>>[];
      while (i < children.length && _groupableParent(children[i]['type'] as String) == parentType) {
        group.add(children[i]);
        i++;
      }
      content.add(_afGroupToTt(group, parentType));
      continue;
    }
    content.addAll(_afSingleToTt(children[i]));
    i++;
  }
  return {'type': 'doc', 'content': content};
}

// af 扁平类型 → tiptap 父节点类型（可分组的才返回非 null）
String? _groupableParent(String afType) {
  switch (afType) {
    case 'bulleted_list':
      return 'bulletList';
    case 'numbered_list':
      return 'orderedList';
    case 'todo_list':
      return 'taskList';
    case 'quote':
      return 'blockquote';
    default:
      return null;
  }
}

Map<String, dynamic> _afGroupToTt(List<Map<String, dynamic>> group, String parentType) {
  final items = <Map<String, dynamic>>[];
  for (final node in group) {
    final data = node['data'] as Map<String, dynamic>? ?? {};
    switch (parentType) {
      case 'bulletList':
      case 'orderedList':
        items.add(_afListItemToTt(node));
      case 'taskList':
        items.add(_ttBlock('taskItem', attrs: {'checked': data['checked'] == true}, content: [
          _ttBlock('paragraph', content: _deltaToTtRuns(data['delta'])),
        ]));
      case 'blockquote':
        items.add(_ttBlock('paragraph', content: _deltaToTtRuns(data['delta'])));
    }
  }
  return _ttBlock(parentType, content: items);
}

Map<String, dynamic> _afListItemToTt(Map<String, dynamic> node) {
  final data = node['data'] as Map<String, dynamic>? ?? {};
  final content = <Map<String, dynamic>>[
    _ttBlock('paragraph', content: _deltaToTtRuns(data['delta'])),
  ];
  // 嵌套子块（嵌套列表等）：相邻同类合并
  final kids = (node['children'] as List? ?? []).cast<Map<String, dynamic>>();
  var i = 0;
  while (i < kids.length) {
    final parentType = _groupableParent(kids[i]['type'] as String);
    if (parentType != null) {
      final group = <Map<String, dynamic>>[];
      while (i < kids.length && _groupableParent(kids[i]['type'] as String) == parentType) {
        group.add(kids[i]);
        i++;
      }
      content.add(_afGroupToTt(group, parentType));
      continue;
    }
    content.addAll(_afSingleToTt(kids[i]));
    i++;
  }
  return _ttBlock('listItem', content: content);
}

List<Map<String, dynamic>> _afSingleToTt(Map<String, dynamic> node) {
  final type = node['type'] as String;
  final data = node['data'] as Map<String, dynamic>? ?? {};
  switch (type) {
    case 'paragraph':
      return [_ttBlock('paragraph', content: _deltaToTtRuns(data['delta']))];
    case 'heading':
      return [
        _ttBlock('heading', attrs: {'level': (data['level'] as num?)?.toInt() ?? 2},
            content: _deltaToTtRuns(data['delta'])),
      ];
    case 'code_block':
      return [
        _ttBlock('codeBlock', attrs: {'language': null},
            content: _deltaToTtRuns(data['delta'], keepNewlines: true)),
      ];
    case 'image':
      return [
        _ttBlock('image', attrs: {'src': data['url'] ?? '', 'alt': null, 'title': null}),
      ];
    default:
      throw TiptapConvertException('不支持的 AppFlowy 节点类型: $type', node);
  }
}

// Tiptap 文本 runs（含 marks）→ AppFlowy delta（hardBreak → '\n'）
List<Map<String, dynamic>> _ttRunsToDelta(dynamic content) {
  final delta = <Map<String, dynamic>>[];
  for (final run in content as List? ?? []) {
    final m = run as Map<String, dynamic>;
    if (m['type'] == 'hardBreak') {
      delta.add({'insert': '\n'});
      continue;
    }
    if (m['type'] != 'text') {
      throw TiptapConvertException('段落内不支持的节点: ${m['type']}', m);
    }
    final attrs = <String, dynamic>{};
    for (final mark in m['marks'] as List? ?? []) {
      final mk = mark as Map<String, dynamic>;
      switch (mk['type']) {
        case 'bold':
          attrs['bold'] = true;
        case 'italic':
          attrs['italic'] = true;
        case 'underline':
          attrs['underline'] = true;
        case 'strike':
          attrs['strikethrough'] = true;
        case 'code':
          attrs['code'] = true;
        case 'link':
          attrs['href'] = (mk['attrs'] as Map<String, dynamic>? ?? {})['href'] ?? '';
        default:
          throw TiptapConvertException('不支持的文本标记: ${mk['type']}', m);
      }
    }
    delta.add({'insert': m['text'] ?? '', if (attrs.isNotEmpty) 'attributes': attrs});
  }
  return delta;
}

// AppFlowy delta → Tiptap 文本 runs；keepNewlines=代码块场景，'\n' 是文本内容不拆 hardBreak
List<Map<String, dynamic>> _deltaToTtRuns(dynamic delta, {bool keepNewlines = false}) {
  final runs = <Map<String, dynamic>>[];
  for (final op in delta as List? ?? []) {
    final m = op as Map<String, dynamic>;
    final insert = m['insert'] as String? ?? '';
    if (insert.isEmpty) continue;
    final attrs = m['attributes'] as Map<String, dynamic>? ?? {};
    if (keepNewlines) {
      if (insert.isNotEmpty) {
        runs.add({'type': 'text', 'text': insert});
      }
      continue;
    }
    final parts = insert.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) runs.add({'type': 'hardBreak'});
      if (parts[i].isEmpty) continue;
      final marks = <Map<String, dynamic>>[];
      if (attrs['bold'] == true) marks.add({'type': 'bold'});
      if (attrs['italic'] == true) marks.add({'type': 'italic'});
      if (attrs['underline'] == true) marks.add({'type': 'underline'});
      if (attrs['strikethrough'] == true) marks.add({'type': 'strike'});
      if (attrs['code'] == true) marks.add({'type': 'code'});
      if (attrs['href'] != null && (attrs['href'] as String).isNotEmpty) {
        marks.add({
          'type': 'link',
          'attrs': {'href': attrs['href'], 'target': '_blank', 'rel': 'noopener noreferrer nofollow', 'class': null},
        });
      }
      runs.add({'type': 'text', 'text': parts[i], if (marks.isNotEmpty) 'marks': marks});
    }
  }
  return runs;
}

Map<String, dynamic> _ttBlock(String type, {Map<String, dynamic>? attrs, List<Map<String, dynamic>>? content}) {
  return {
    'type': type,
    if (attrs != null) 'attrs': attrs,
    if (content != null && content.isNotEmpty) 'content': content,
  };
}
