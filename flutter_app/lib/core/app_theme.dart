// 主题：颜色与 Web 版 style.css 的 CSS 变量一一对齐；
// 组件样式统一从这里的令牌取（圆角/字号/字重），页面里不再散落硬编码
import 'package:flutter/material.dart';

/// 形状/尺寸令牌：全应用圆角只有这几档
class AppDimens {
  static const rCard = 14.0; // 列表卡片/设置卡片
  static const rField = 12.0; // 输入框/按钮/列表项胶囊
  static const rDialog = 16.0; // 对话框
  static const rPill = 999.0; // 标签 chip/徽标
}

class AppColors {
  // 浅色（:root）
  static const light = (
    bg: Color(0xFFF3F5F8),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFFAFBFC),
    border: Color(0xFFE5E9EF),
    borderStrong: Color(0xFFD6DCE5),
    text: Color(0xFF1B2129),
    muted: Color(0xFF66707D),
    primary: Color(0xFF2C7BE5),
    primaryStrong: Color(0xFF1F68CC),
    primaryWeak: Color(0xFFE9F1FC),
    danger: Color(0xFFD93025),
    hover: Color(0xFFF1F4F8),
    chip: Color(0xFFECEFF4),
  );

  // 暗色（data-theme=dark）
  static const dark = (
    bg: Color(0xFF0F1114),
    panel: Color(0xFF181B20),
    panel2: Color(0xFF1D2127),
    border: Color(0xFF262B33),
    borderStrong: Color(0xFF333A45),
    text: Color(0xFFE8EAEE),
    muted: Color(0xFF939DAB),
    primary: Color(0xFF5C9CF5),
    primaryStrong: Color(0xFF79AEF8),
    primaryWeak: Color(0xFF16233A),
    danger: Color(0xFFF0716A),
    hover: Color(0xFF21262D),
    chip: Color(0xFF232830),
  );

  // 主题无关
  static const accentOrange = Color(0xFFF5A623); // 置顶星 / 待办勾选
}

typedef Palette = ({
  Color bg, Color panel, Color panel2, Color border, Color borderStrong,
  Color text, Color muted, Color primary, Color primaryStrong,
  Color primaryWeak, Color danger, Color hover, Color chip,
});

Palette paletteOf(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? AppColors.dark : AppColors.light;

/// 二级页面转场：淡入 + 轻微上移（比默认横滑更轻，匹配工具风）
PageRouteBuilder<T> fadeUpRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    );

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.primary,
    onPrimary: Colors.white,
    primaryContainer: p.primaryWeak,
    onPrimaryContainer: p.primaryStrong,
    secondary: p.primary,
    onSecondary: Colors.white,
    secondaryContainer: p.primaryWeak,
    onSecondaryContainer: p.primaryStrong,
    error: p.danger,
    onError: Colors.white,
    surface: p.panel,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    outline: p.border,
    outlineVariant: p.border,
    surfaceContainerHighest: p.chip,
    surfaceContainer: p.panel2,
    surfaceContainerLow: p.panel2,
    surfaceContainerLowest: p.panel,
    inverseSurface: p.text,
    onInverseSurface: p.panel,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    splashFactory: InkRipple.splashFactory, // 克制的水波纹
    textTheme: TextTheme(
      // 五档字号体系：11 辅助 / 12.5 时间摘要 / 13.5 次要正文 / 15 列表标题 / 17 页面标题
      headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: p.text, height: 1.3),
      titleLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text, height: 1.35),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.text, height: 1.4),
      titleSmall: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.text, height: 1.4),
      bodyLarge: TextStyle(fontSize: 15, color: p.text, height: 1.5),
      bodyMedium: TextStyle(fontSize: 13.5, color: p.text, height: 1.5),
      bodySmall: TextStyle(fontSize: 12.5, color: p.muted, height: 1.45),
      labelLarge: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.text, height: 1.3),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.muted, height: 1.3),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: p.muted, height: 1.3, letterSpacing: 0.4),
    ),
    iconTheme: IconThemeData(size: 22, color: p.text),
    appBarTheme: AppBarTheme(
      backgroundColor: p.panel,
      foregroundColor: p.text,
      elevation: 0.4,
      shadowColor: p.border,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text, height: 1.35),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDimens.rCard),
        side: BorderSide(color: p.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppDimens.rDialog)),
      titleTextStyle: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: p.text, height: 1.35),
      contentTextStyle: TextStyle(fontSize: 13.5, color: p.text, height: 1.55),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.text,
      contentTextStyle: TextStyle(fontSize: 13, color: p.panel),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppDimens.rField)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.chip,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: p.muted, height: 1.25),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      labelPadding: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppDimens.rField)),
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.muted,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppDimens.rField)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel2,
      hintStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppDimens.rField),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppDimens.rField),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppDimens.rField),
        borderSide: BorderSide(color: p.primary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1),
  );
}
