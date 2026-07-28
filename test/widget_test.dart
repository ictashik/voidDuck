import 'package:flutter_test/flutter_test.dart';

import 'package:voidduck/app.dart';

void main() {
  testWidgets('Scaffold boot shows the build tag', (WidgetTester tester) async {
    await tester.pumpWidget(const VoidDuckApp());
    expect(find.text('voidduck v0.1'), findsOneWidget);
  });

  testWidgets('Triple-tap top-left opens the debug overlay',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VoidDuckApp());
    expect(find.text('VOIDDUCK DEBUG'), findsNothing);
    // Three sequential taps on the top-left hot zone.
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(4, 4));
    }
    await tester.pumpAndSettle();
    expect(find.text('VOIDDUCK DEBUG'), findsOneWidget);
  });
}