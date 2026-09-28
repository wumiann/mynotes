// API 客户端：Bearer 令牌 + 服务器地址（首启引导页配置）
// 在线优先；错误统一 ApiError(status, message)
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ApiError implements Exception {
  ApiError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class Api {
  String? _baseUrl;
  String? _token;
  String? _username;

  // 单例复用：每次新建 Client 不关闭会泄漏连接，移动端很快耗尽句柄导致请求全挂
  static final http.Client _client = http.Client();

  String? get baseUrl => _baseUrl;
  String? get username => _username;
  bool get configured => _baseUrl != null && _token != null;

  static const _kBase = 'mynotes-server-addr';
  static const _kToken = 'mynotes-token';
  static const _kUser = 'mynotes-username';

  Future<void> loadSaved() async {
    final sp = await SharedPreferences.getInstance();
    _baseUrl = sp.getString(_kBase);
    _token = sp.getString(_kToken);
    _username = sp.getString(_kUser);
  }

  Future<void> saveConfig(String baseUrl) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kBase, baseUrl);
    _baseUrl = baseUrl;
  }

  Future<void> saveAuth(String token, String username) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kToken, token);
    await sp.setString(_kUser, username);
    _token = token;
    _username = username;
  }

  Future<void> clearAuth() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kToken);
    await sp.remove(_kUser);
    _token = null;
    _username = null;
  }

  Future<dynamic> _req(String method, String path, {Object? body, int? timeoutSec}) async {
    if (_baseUrl == null) throw ApiError(0, '未配置服务器地址');
    final uri = Uri.parse('$_baseUrl$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };
    final res = await _client
        .send(http.Request(method, uri)
              ..headers.addAll(headers)
              ..body = body != null ? jsonEncode(body) : '')
        .then(http.Response.fromStream)
        .then((r) {
      debugPrint('API $method $path -> ${r.statusCode}');
      return r;
    })
        .timeout(Duration(seconds: timeoutSec ?? 15));
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      data = null;
    }
    if (res.statusCode >= 400) {
      // 服务端业务错误用 error；Fastify 框架错误（如 JSON 解析失败）用 message
      final msg = (data?['error'] as String?) ?? (data?['message'] as String?) ?? '请求失败(${res.statusCode})';
      throw ApiError(res.statusCode, msg);
    }
    if (data == null) throw ApiError(502, '服务器响应异常，请检查服务器地址');
    return data;
  }

  // ---------- 认证 ----------
  Future<Map<String, dynamic>> health(String base) async {
    final res = await http.get(Uri.parse('$base/api/health')).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw ApiError(res.statusCode, '服务不可用(${res.statusCode})');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSalts(String username) async =>
      (await _req('GET', '/api/auth/salts?username=${Uri.encodeComponent(username)}')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> setup(Map<String, dynamic> payload) async =>
      (await _req('POST', '/api/auth/setup', body: payload)) as Map<String, dynamic>;

  Future<Map<String, dynamic>> login(String username, String authKey) async =>
      (await _req('POST', '/api/auth/login', body: {'username': username, 'authKey': authKey}))
          as Map<String, dynamic>;

  Future<void> logout() async {
    try {
      await _req('POST', '/api/auth/logout');
    } finally {
      await clearAuth();
    }
  }

  // ---------- 笔记 ----------
  Future<List<Note>> listNotes({String? q, String? tag, bool? pinned, bool? trash, String? group}) async {
    final qs = <String>[];
    if (q != null && q.isNotEmpty) qs.add('q=${Uri.encodeComponent(q)}');
    if (tag != null) qs.add('tag=${Uri.encodeComponent(tag)}');
    if (pinned == true) qs.add('pinned=1');
    if (trash == true) qs.add('trash=1');
    if (group != null) qs.add('group=$group');
    final data = await _req('GET', '/api/notes${qs.isEmpty ? '' : '?${qs.join('&')}'}');
    return ((data['notes'] as List?) ?? []).map((e) => Note.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Note> getNote(String id) async =>
      Note.fromJson((await _req('GET', '/api/notes/$id'))['note'] as Map<String, dynamic>);

  Future<Note> createNote(NotePayload p) async =>
      Note.fromJson((await _req('POST', '/api/notes', body: p.toJson()))['note'] as Map<String, dynamic>);

  Future<Note> updateNote(String id, NotePayload p) async =>
      Note.fromJson((await _req('PUT', '/api/notes/$id', body: p.toJson()))['note'] as Map<String, dynamic>);

  Future<void> deleteNote(String id) async => _req('DELETE', '/api/notes/$id');

  Future<void> restoreNote(String id) async => _req('POST', '/api/notes/$id/restore');

  Future<void> purgeNote(String id) async => _req('POST', '/api/notes/$id/purge');

  Future<void> moveNote(String id, String? groupId) async =>
      _req('POST', '/api/notes/$id/move', body: {'groupId': groupId});

  // ---------- 分组 / 设置 ----------
  Future<List<Group>> listGroups() async {
    final data = await _req('GET', '/api/groups');
    return ((data['groups'] as List?) ?? []).map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<AppSettings> getSettings() async =>
      AppSettings.fromJson((await _req('GET', '/api/settings')) as Map<String, dynamic>);

  Future<void> updateSettings(Map<String, dynamic> s) async => _req('PUT', '/api/settings', body: s);
}

final api = Api();
