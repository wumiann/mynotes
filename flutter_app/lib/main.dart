// MyNotes Flutter 版入口
// F1：引导 → 登录 → 列表/编辑（文本笔记全功能，在线模式）
import 'package:flutter/material.dart';

import 'core/api.dart';
import 'core/app_theme.dart';
import 'core/store.dart';
import 'core/sync.dart' show localdb, releaseSync, bootSync;
import 'pages/home_page.dart';

void main() {
  runApp(const MyNotesApp());
}

class MyNotesApp extends StatefulWidget {
  const MyNotesApp({super.key});

  @override
  State<MyNotesApp> createState() => _MyNotesAppState();
}

class _MyNotesAppState extends State<MyNotesApp> {
  bool _booted = false;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _boot();
    store.addListener(_onStoreChanged);
  }

  Future<void> _boot() async {
    await api.loadSaved();
    // 全局字号（设备级偏好，存本机 kv）
    store.fontScale = double.tryParse(await localdb.getKv('settings.fontScale') ?? '') ?? 1.0;
    if (api.configured) {
      // 令牌存在即视为已登录（历史语义）；本地缓存立即可用，同步全异步不阻塞启动
      store.authed = true;
      releaseSync(); // 解除向导挂起（正常用户路径）
      bootSync();
      // 设置在线拉取，取回后回填主题（失败用本地默认）
      api.getSettings().then((s) {
        store.settings = s;
        store.notifyListeners();
      }).catchError((_) {});
    }
    // 未配置服务器 → 本地模式：直接进主界面（数据仅存本机，可在设置里配置同步）
    setState(() => _booted = true);
  }

  void _onStoreChanged() {
    if (store.authed) bootSync(); // 登录路径进入（内部幂等守卫）
    if (store.settings.themeMode != _themeModeName) _applyTheme(store.settings.themeMode);
    // 登出时无需处理：_MyNotes 根据store.authed重建
    setState(() {});
  }

  String get _themeModeName => switch (_themeMode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      };

  void _applyTheme(String mode) {
    setState(() {
      _themeMode = switch (mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyNotes',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: _themeMode,
      // 全局字号：用 textScaler 线性缩放全部文字（设置→字号，存本机 kv）
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(store.fontScale)),
          child: child!,
        );
      },
      home: !_booted
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : AnimatedBuilder(
              animation: store,
              builder: (context, _) {
                // 本地优先：无论是否配置服务器都直接进主界面；
                // 未登录状态由设置页的同步区引导配置/登录
                // 不能加 const：常量组件会让 AnimatedBuilder 的重建整棵子树短路，
                // store 通知全部被吞（表现为列表转圈不停、切视图不刷新）
                return HomePage();
              },
            ),
    );
  }
}
