import 'package:flutter_test/flutter_test.dart';

import 'package:pipe_layout_flutter/main.dart';

void main() {
  testWidgets('App loads home scaffold', (WidgetTester tester) async {
    await tester.pumpWidget(const PipeLayoutApp());
    await tester.pumpAndSettle();

    expect(find.text('Pipe Layout Scanner'), findsWidgets);
    expect(find.text('Backend URL'), findsOneWidget);
  });
}
