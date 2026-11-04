// 零知识加密（F0 对拍验证过，与 Web 版 crypto.ts 完全兼容）
// authKey = PBKDF2-SHA256(密码, 盐1hex, 600k, 32B) hex → 登录用
// encKey  = PBKDF2-SHA256(密码, 盐2hex, 600k, 32B) → AES-256-GCM，仅存内存
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

const kIterations = 600000;

/// compute 的入口必须是顶层函数（不可为闭包/实例方法）：参数只传字节
String _pbkdf2HexSync(List<Uint8List> args) {
  final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(args[1], kIterations, 32));
  return bytesToHex(d.process(args[0]));
}

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class Vault {
  Vault._();
  static final Vault instance = Vault._();

  Uint8List? _encKey; // 派生后的 AES 密钥，仅内存（cardLock=ask 语义）

  bool get unlocked => _encKey != null;

  Future<String> deriveHex(String password, String saltHex) async {
    // PBKDF2 600k 迭代是纯 Dart 实现：主 isolate 同步计算在桌面 ~1.6s，
    // 手机上要 5-10 秒——期间用户点屏幕会触发 Android ANR（输入 5 秒无响应）
    // 直接被系统杀进程（登录"卡死然后闪退"的根因）。
    // 派生移到后台 isolate：compute 接顶层函数+参数即可，不需要闭包。
    return compute(_pbkdf2HexSync, [Uint8List.fromList(utf8.encode(password)), hexToBytes(saltHex)]);
  }

  Future<void> unlock(String password, String salt2Hex) async {
    _encKey = hexToBytes(await deriveHex(password, salt2Hex));
  }

  void lock() => _encKey = null;

  /// AES-256-GCM：base64(iv[12] + ct + tag[16])，与 Web vault 相同格式
  String encrypt(String plainJson) {
    final key = _encKey!;
    final iv = Uint8List.fromList(
        List.generate(12, (_) => Random.secure().nextInt(256)));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final ctTag = cipher.process(utf8.encode(plainJson));
    return base64.encode(Uint8List.fromList([...iv, ...ctTag]));
  }

  String decrypt(String payload) {
    final key = _encKey!;
    final data = base64.decode(payload);
    final iv = Uint8List.sublistView(data, 0, 12);
    final ct = Uint8List.sublistView(data, 12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return utf8.decode(cipher.process(ct));
  }
}
