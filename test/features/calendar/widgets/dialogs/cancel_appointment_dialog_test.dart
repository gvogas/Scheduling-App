import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/cancel_appointment_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/series_scope_dialog.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The one-off confirm's two buttons must not BOTH start with "Cancel": the
/// dismiss reads "Keep appointment", so backing out and calling off the job are
/// told apart at a glance.
void main() {
  SeriesScopeChoice? choice;
  var returned = false;

  Future<void> open(WidgetTester tester, {required bool isRun}) async {
    choice = null;
    returned = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  choice = await showCancelAppointmentDialog(
                    context,
                    isRun: isRun,
                  );
                  returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a one-off visit dismisses with Keep appointment, not Cancel', (
    tester,
  ) async {
    await open(tester, isRun: false);

    expect(find.widgetWithText(FilledButton, 'Cancel Appointment'), findsOne);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Keep appointment'));
    await tester.pumpAndSettle();

    expect(returned, isTrue);
    expect(choice, isNull);
  });

  testWidgets('confirming a one-off visit maps to thisOnly', (tester) async {
    await open(tester, isRun: false);

    await tester.tap(find.widgetWithText(FilledButton, 'Cancel Appointment'));
    await tester.pumpAndSettle();

    expect(choice, SeriesScopeChoice.thisOnly);
  });

  testWidgets('a run day backs out through Back, never a second Cancel', (
    tester,
  ) async {
    await open(tester, isRun: true);

    expect(find.text('Cancel this day only'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();

    expect(returned, isTrue);
    expect(choice, isNull);
  });
}
