import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/screens/history_screen.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockAppointmentsRepository extends Mock
    implements AppointmentsRepository {}

AppointmentRecord _appt({
  required String id,
  required String title,
  required DateTime start,
  required String employeeId,
  required String employeeName,
}) => AppointmentRecord(
  id: id,
  title: title,
  startTime: start,
  endTime: start.add(const Duration(hours: 1)),
  clientName: 'Client $title',
  clientPhone: '514-555-0101',
  employeeIds: [employeeId],
  employeeNames: [employeeName],
  status: 'done',
);

final _history = [
  _appt(
    id: '1',
    title: 'Alice Job',
    start: DateTime(2025, 5, 1, 9),
    employeeId: 'e1',
    employeeName: 'Alice',
  ),
  _appt(
    id: '2',
    title: 'Bob Job',
    start: DateTime(2024, 8, 3, 9),
    employeeId: 'e2',
    employeeName: 'Bob',
  ),
];

Widget _wrap(AppointmentsRepository repo) => ProviderScope(
  overrides: [
    appointmentsRepositoryProvider.overrideWithValue(repo),
    employeeColorMapProvider.overrideWithValue(
      const {'e1': Color(0xFF6366F1), 'e2': Color(0xFF10B981)},
    ),
  ],
  child: ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: 2,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const HistoryScreen(isAdmin: false, employeeId: 'e1'),
    ),
  ),
);

void main() {
  testWidgets('history screen does not overflow on phone width at 2x text', (
    tester,
  ) async {
    final repo = _MockAppointmentsRepository();
    when(() => repo.onLocalWrite).thenAnswer((_) => const Stream<void>.empty());
    when(
      () => repo.fetchHistoryPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
      ),
    ).thenAnswer((_) async => _history);

    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
