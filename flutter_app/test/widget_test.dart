// F0 冒烟：验证页可构建渲染
import 'package:flutter_test/flutter_test.dart';
import 'package:mynotes/main.dart';

void main() {
  testWidgets('F0 编辑器验证页可渲染', (tester) async {
    await tester.pumpWidget(const F0App());
    await tester.pumpAndSettle();
    expect(find.text('F0 编辑器验证'), findsOneWidget);
    expect(find.text('往返校验'), findsOneWidget);
  });
}
