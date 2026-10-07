import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/widgets/views/agenda_sliver_list.dart';
import 'package:scheduling/l10n/l10n.dart';

const _delegates = <LocalizationsDelegate<Object?>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

Future<void> _pump(WidgetTester tester, {required double width}) async {
  tester.view
    ..physicalSize = Size(width, 800)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: _delegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      home: const Scaffold(
        body: AgendaHeader(
          dayTitle: 'Friday, September 11',
          dayTitleShort: 'Fri, Sep 11',
          jobLabel: '3 JOBS · 1 DONE',
          trailing: SizedBox(width: 80, height: 38),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The count and the toggle are laid out first, so on a phone the full date
  // lost and ellipsised to "Friday, Septe…".
  testWidgets('falls back to the short date when the full one will not fit', (
    tester,
  ) async {
    await _pump(tester, width: 440);

    expect(find.text('Fri, Sep 11'), findsOneWidget);
    expect(find.text('Friday, September 11'), findsNothing);
  });

  testWidgets('keeps the full date where there is room for it', (tester) async {
    await _pump(tester, width: 900);

    expect(find.text('Friday, September 11'), findsOneWidget);
  });
}
