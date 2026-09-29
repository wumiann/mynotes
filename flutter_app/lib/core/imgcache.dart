// 图片离线缓存（对齐 Web lib/imgcache.ts）：/a/xxx 下载到本地缓存，显示用本地路径，保存还原
import 'dart:io';

import 'api.dart';

class ImgCache {
  ImgCache._();
  static final ImgCache instance = ImgCache._();

  final _map = <String, String>{}; // /a/xxx → 本地绝对路径

  Future<String> resolve(String src) async {
    if (!src.startsWith('/a/')) return src;
    final hit = _map[src];
    if (hit != null && await File(hit).exists()) return hit;
    try {
      final bytes = await api.getAttachmentBytes(src);
      final dir = Directory.systemTemp;
      final f = File('${dir.path}/mynotes_img${src.replaceAll('/', '_')}');
      await f.writeAsBytes(bytes);
      _map[src] = f.path;
      return f.path;
    } catch (_) {
      return src; // 离线且未缓存：原样（显示失败但不阻断）
    }
  }

  String restore(String src) {
    for (final e in _map.entries) {
      if (e.value == src) return e.key;
    }
    return src;
  }
}
