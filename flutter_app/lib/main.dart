// MyNotes Flutter 版入口
// F1：引导 → 登录 → 列表/编辑（文本笔记全功能，在线模式）
import 'package:flutter/material.dart';

import 'core/api.dart';
import 'core/app_theme.dart';
import 'core/store.dart';
import 'pages/bootstrap_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';

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
    if (api.configured) {
      try {
        store.settings = await api.getSettings();
      } catch (_) {}
      _applyTheme(store.settings.themeMode);
      store.authed = true;
    }
    setState(() => _booted = true);
  }

  void _onStoreChanged() {
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
      home: !_booted
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : AnimatedBuilder(
              animation: store,
              builder: (context, _) {
                if (!store.authed) {
                  if (!api.configured) return BootstrapPage(onDone: () => setState(() {}));
                  return LoginPage(onLoggedIn: () {
                    store.authed = true;
                    store.notifyListeners();
                  });
                }
                return const HomePage();
              },
            ),
    );
  }
}
