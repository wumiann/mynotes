// F1 冒烟：App 入口可构建
import 'package:flutter_test/flutter_test.dart';
import 'package:mynotes/main.dart';

void main() {
  testWidgets('MyNotes App 可启动到引导页', (tester) async {
    await tester.pumpWidget(const MyNotesApp());
    await tester.pumpAndSettle();
    expect(find.text('MyNotes'), findsWidgets);
  });
}
