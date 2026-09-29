// 待办列表工具栏项（AppFlowy 预置 list 菜单只有无序/有序，补 todo_list）
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

final todoMobileToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (context, editorState, __) {
    final node = _currentNode(editorState);
    final selected = node?.type == TodoListBlockKeys.type;
    return Icon(
      selected ? Icons.check_box : Icons.check_box_outline_blank,
      size: 20,
      color: selected
          ? MobileToolbarTheme.of(context).primaryColor
          : MobileToolbarTheme.of(context).iconColor,
    );
  },
  actionHandler: (context, editorState) {
    final selection = editorState.selection;
    if (selection == null) return;
    final node = _currentNode(editorState);
    final isTodo = node?.type == TodoListBlockKeys.type;
    editorState.formatNode(
      selection,
      (n) => n.copyWith(
        type: isTodo ? ParagraphBlockKeys.type : TodoListBlockKeys.type,
        attributes: {
          if (!isTodo) TodoListBlockKeys.checked: false,
          ParagraphBlockKeys.delta: (n.delta ?? Delta()).toJson(),
        },
      ),
    );
  },
);

Node? _currentNode(EditorState editorState) {
  final selection = editorState.selection;
  if (selection == null) return null;
  return editorState.getNodeAtPath(selection.start.path);
}
