import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/shared/widgets/feature_paused_notice.dart';

void main() {
  testWidgets('renders the message without overflow at 260 px and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: FeaturePausedNotice(message: 'Paused for now, sorry'),
          ),
        ),
      ),
    );
    expect(find.text('Paused for now, sorry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
