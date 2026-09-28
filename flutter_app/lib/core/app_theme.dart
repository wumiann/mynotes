// 主题：颜色与 Web 版 style.css 的 CSS 变量一一对齐
import 'package:flutter/material.dart';

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

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.primary,
    onPrimary: Colors.white,
    secondary: p.primary,
    onSecondary: Colors.white,
    error: p.danger,
    onError: Colors.white,
    surface: p.panel,
    onSurface: p.text,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: p.panel,
      foregroundColor: p.text,
      elevation: 0.5,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: p.text, fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel2,
      hintStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.primary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1),
  );
}
