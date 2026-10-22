// Local review demonstrations of CURRENT faulty behavior, not regression tests.
// Convert these to expectations of an accessible tap action when fixing the UI.
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/widgets/fields/appointment_status_picker.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';

Widget host(Widget child) => MaterialApp(
  theme: lightTheme(),
  locale: const Locale('en'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: const [Locale('en'), Locale('fr')],
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'REPRODUCED: picker row is pointer-tappable without semantic tap',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var tapped = false;
      await tester.pumpWidget(
        host(
          SheetFieldRow(
            label: 'Appointment date',
            value: 'October 18',
            onTap: () => tapped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final node = tester.getSemantics(
        find.bySemanticsLabel('Appointment date, October 18'),
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      await tester.tap(find.byType(SheetFieldRow));
      expect(tapped, isTrue);
      semantics.dispose();
    },
  );

  testWidgets('REPRODUCED: status choices omit semantic tap actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        AppointmentStatusPicker(currentStatus: 'pending', onChanged: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    final choices = find.descendant(
      of: find.byType(AppointmentStatusPicker),
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.button == true,
      ),
    );
    expect(choices, findsWidgets);
    for (final element in choices.evaluate()) {
      final node = tester.getSemantics(find.byWidget(element.widget));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    }
    semantics.dispose();
  });
}
