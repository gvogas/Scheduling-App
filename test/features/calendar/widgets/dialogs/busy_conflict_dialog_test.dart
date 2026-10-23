import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/widgets/dialogs/busy_conflict_dialog.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

const _marc = EmployeeRecord(id: 'e1', name: 'Marc Tremblay', status: 'active');

BusyConflict _conflict() => (
  busyEmployees: const [_marc],
  start: DateTime(2026, 8, 26, 8),
  end: DateTime(2026, 8, 26, 12),
);

void main() {
  late BuildContext hostContext;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold();
          },
        ),
      ),
    );
  }

  testWidgets('a non-busy outcome is returned and no dialog opens', (
    tester,
  ) async {
    await pumpHost(tester);
    final attempts = <bool>[];

    final result = await retryPastBusyConflict<String>(
      hostContext,
      attempt: ({forceBusy = false}) async {
        attempts.add(forceBusy);
        return 'saved';
      },
      busyOf: (_) => null,
    );
    await tester.pumpAndSettle();

    expect(result, 'saved');
    expect(find.byType(Dialog), findsNothing);
    expect(attempts, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('declining the dialog returns null after one attempt', (
    tester,
  ) async {
    await pumpHost(tester);
    final attempts = <bool>[];
    final l10n = AppLocalizations.of(hostContext);

    final future = retryPastBusyConflict<String>(
      hostContext,
      attempt: ({forceBusy = false}) async {
        attempts.add(forceBusy);
        return 'busy';
      },
      busyOf: (_) => _conflict(),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.calendar_scheduleConflict), findsOneWidget);
    await tester.tap(find.text(l10n.common_cancel));
    await tester.pumpAndSettle();

    expect(await future, isNull);
    expect(attempts, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming re-runs the attempt with forceBusy true', (
    tester,
  ) async {
    await pumpHost(tester);
    final attempts = <bool>[];
    final l10n = AppLocalizations.of(hostContext);

    final future = retryPastBusyConflict<String>(
      hostContext,
      attempt: ({forceBusy = false}) async {
        attempts.add(forceBusy);
        return forceBusy ? 'forced' : 'busy';
      },
      busyOf: (outcome) => outcome == 'busy' ? _conflict() : null,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.calendar_scheduleAnyway));
    await tester.pumpAndSettle();

    expect(await future, 'forced');
    expect(attempts, [false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmounting during the first attempt returns null, no dialog', (
    tester,
  ) async {
    await pumpHost(tester);
    final gate = Completer<void>();

    final future = retryPastBusyConflict<String>(
      hostContext,
      attempt: ({forceBusy = false}) async {
        await gate.future;
        return 'busy';
      },
      busyOf: (_) => _conflict(),
    );
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();

    expect(await future, isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
