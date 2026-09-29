// 图片工具栏项：选图 → 压缩（最长边1600/JPEG 0.8）→ 上传 → 插入 image 节点
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'dart:io';

import '../core/api.dart';
import '../core/sync.dart';

final imageMobileToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (context, __, ___) => Icon(
    Icons.image_outlined,
    size: 20,
    color: MobileToolbarTheme.of(context).iconColor,
  ),
  actionHandler: (context, editorState) async {
    final res = await fp.FilePicker.platform.pickFiles(type: fp.FileType.image);
    final path = res?.files.single.path;
    if (path == null) return;
    try {
      // 压缩（对齐 Web：最长边 1600、JPEG 0.8）
      final compressed = await FlutterImageCompress.compressWithFile(
        path,
        minWidth: 1600, minHeight: 1600,
        quality: 80,
        format: CompressFormat.jpeg,
      );
      final bytes = compressed ?? await File(path).readAsBytes();
      final url = await api.uploadAttachment(bytes, 'img.jpg', 'image/jpeg');
      if (url.isEmpty) return;
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('图片已上传'), duration: Duration(milliseconds: 800)));
      }
      // 在当前选区后插入 image 节点
      final selection = editorState.selection;
      if (selection == null) return;
      _insertImageNode(editorState, url);
      // 图片立即同步（附件不入本地库队列，直接推）
      schedulePush();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('图片上传失败：$e')));
      }
    }
  },
);

void _insertImageNode(EditorState editorState, String url) {
  final selection = editorState.selection;
  if (selection == null) return;
  final path = selection.end.path.next;
  final image = Node(
    type: ImageBlockKeys.type,
    attributes: {ImageBlockKeys.url: url, ImageBlockKeys.align: 'center'},
  );
  final transaction = editorState.transaction;
  transaction.insertNode(path, image);
  editorState.apply(transaction);
}
