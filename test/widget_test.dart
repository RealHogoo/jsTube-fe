import 'package:flutter_test/flutter_test.dart';

import 'package:jstube_fe/main.dart';

void main() {
  testWidgets('jsTube Flutter app renders', (tester) async {
    await tester.pumpWidget(const JsTubeApp());
    await tester.pump();
    expect(find.text('jsTube 미디어'), findsOneWidget);
  });
}
