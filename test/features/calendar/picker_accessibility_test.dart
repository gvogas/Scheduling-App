import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/widgets/fields/appointment_status_picker.dart';
import 'package:scheduling/features/calendar/widgets/fields/inline_month_calendar.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';

Widget _host(Widget child, {String language = 'en', double scale = 1}) =>
    MaterialApp(
      theme: lightTheme(),
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

void _semanticTap(WidgetTester tester, Finder finder) {
  final node = tester.getSemantics(finder);
  expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
  node.owner!.performAction(node.id, SemanticsAction.tap);
}

void main() {
  testWidgets('date row supports semantic and pointer activation once each', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      _host(
        SheetFieldRow(
          label: 'Appointment date',
          value: 'October 18',
          onTap: () => activations++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.bySemanticsLabel('Appointment date, October 18');
    expect(row, findsOneWidget);
    _semanticTap(tester, row);
    await tester.pumpAndSettle();
    expect(activations, 1);
    await tester.tap(find.byType(SheetFieldRow));
    await tester.pumpAndSettle();
    expect(activations, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only date row exposes no tap action', (tester) async {
    await tester.pumpWidget(
      _host(
        const SheetFieldRow(label: 'Appointment date', value: 'October 18'),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.text('October 18'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new date validation error is spoken once with the field', (
    tester,
  ) async {
    Widget field(String? error) => _host(
      SheetFieldRow(
        label: 'End date',
        value: '',
        placeholder: 'Select date',
        trailingLabel: '2 days',
        errorText: error,
        onTap: () {},
      ),
    );
    await tester.pumpWidget(field(null));
    await tester.pumpAndSettle();
    await tester.pumpWidget(field('Choose an end date'));
    await tester.pumpAndSettle();

    final row = find.bySemanticsLabel(
      'End date, Select date, 2 days, Choose an end date',
    );
    expect(row, findsOneWidget);
    expect(
      tester.getSemantics(row).getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(find.bySemanticsLabel('Choose an end date'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'fr']) {
    testWidgets(
      '$language status choices activate and expose selection at 2x',
      (tester) async {
        var status = 'pending';
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) => AppointmentStatusPicker(
                currentStatus: status,
                onChanged: (value) => setState(() => status = value),
              ),
            ),
            language: language,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();

        final label = language == 'en' ? 'In Progress' : 'En cours';
        final choice = find.bySemanticsLabel(label);
        _semanticTap(tester, choice);
        await tester.pumpAndSettle();
        expect(status, 'in_progress');
        expect(
          tester
              .getSemantics(choice)
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'inline dates activate semantically and out-of-range dates cannot',
    (tester) async {
      DateTime? picked;
      await tester.pumpWidget(
        _host(
          InlineMonthCalendar(
            selectedDate: DateTime(2026, 10, 18),
            firstDate: DateTime(2026, 10, 18),
            lastDate: DateTime(2026, 10, 31),
            today: DateTime(2026, 10, 18),
            onDateSelected: (value) => picked = value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      _semanticTap(
        tester,
        find.byKey(const ValueKey('inline-date-day-2026-10-19')),
      );
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 19));
      final disabled = find.byKey(const ValueKey('inline-date-day-2026-10-17'));
      await tester.tap(disabled);
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 19));
      expect(find.bySemanticsLabel(RegExp('October 17')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
