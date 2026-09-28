// F1 冒烟：App 入口可构建（_boot 有真实 IO，不 pumpAndSettle）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mynotes/main.dart';

void main() {
  testWidgets('MyNotes App 可启动', (tester) async {
    await tester.pumpWidget(const MyNotesApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsWidgets); // 启动转圈
  });
}
