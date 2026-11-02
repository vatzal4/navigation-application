import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_nav/main.dart';

void main() {
  testWidgets('NavApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const NavApp());
    expect(find.text('SOS Indoor Navigation'), findsOneWidget);
  });
}
