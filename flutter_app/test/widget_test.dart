import 'package:flutter_test/flutter_test.dart';

import 'package:intercom_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const IntercomApp());
    await tester.pump();
    // App should render without errors
    expect(find.byType(IntercomApp), findsOneWidget);
  });
}
