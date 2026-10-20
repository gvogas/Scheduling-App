import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/settings/widgets/cards/settings_tile.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget tile) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: tile)),
  );

  testWidgets('a tappable row reads as one button to assistive tech', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, SettingsTile(label: 'My details', onTap: () {}));

    expect(
      tester.getSemantics(find.text('My details')),
      isSemantics(isButton: true, hasTapAction: true, label: 'My details'),
    );
    handle.dispose();
  });

  testWidgets('a switch row merges its switch into the row', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      SettingsSwitchTile(
        icon: Icons.notifications,
        label: 'Travel alerts',
        value: true,
        onChanged: ({required value}) {},
      ),
    );

    expect(
      tester.getSemantics(find.text('Travel alerts')),
      isSemantics(isButton: true, isToggled: true, hasTapAction: true),
    );
    handle.dispose();
  });
}
