import 'package:flutter_test/flutter_test.dart';

import 'package:voidduck/app.dart';

void main() {
  testWidgets('Scaffold boots to the camera permission gate',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VoidDuckApp());
    // Stage 2: the first thing a fresh install sees is the permission gate
    // — "I need to see you." Prior to granting camera, we never start the
    // pipeline.
    expect(find.text('I need to see you.'), findsOneWidget);
    expect(find.text('Grant camera'), findsOneWidget);
  });

  testWidgets('Triple-tap top-left opens the debug overlay',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VoidDuckApp());
    expect(find.text('TUNING'), findsNothing);
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(4, 4));
    }
    await tester.pumpAndSettle();
    expect(find.text('TUNING'), findsOneWidget);
  });
}