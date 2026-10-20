import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/personal_block_clash_dialog.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

EmployeeRecord _person(String id, String name) => EmployeeRecord(
  id: id,
  name: name,
  status: 'active',
  jobTitle: JobTitle.technician,
);

final _marc = _person('e1', 'Marc Tremblay');
final _nadia = _person('e2', 'Nadia Berger');
final _theo = _person('e3', 'Theo Roy');

final _block = AppointmentRecord(
  id: 'block',
  title: 'Dentist',
  startTime: DateTime(2026, 8, 26),
  endTime: DateTime(2026, 8, 26, 23, 59),
  isPersonal: true,
  isDayOff: true,
  isAllDay: true,
  employeeIds: const ['e1'],
  employeeNames: const ['Marc Tremblay'],
);

AppointmentRecord _clashingJob({
  List<String> employeeIds = const ['e1'],
  List<String> employeeNames = const ['Marc Tremblay'],
}) => AppointmentRecord(
  id: 'job-1',
  clientName: 'Dupont',
  startTime: DateTime(2026, 8, 26, 8),
  endTime: DateTime(2026, 8, 26, 12),
  employeeIds: employeeIds,
  employeeNames: employeeNames,
);

void main() {
  setUpAll(() {
    registerFallbackValue(
      AppointmentRecord(
        id: '_',
        startTime: DateTime(2026),
        endTime: DateTime(2026),
      ),
    );
    registerFallbackValue(<EmployeeRecord>[]);
    registerFallbackValue(DateTime(2026));
  });

  late _MockRepo repository;

  setUp(() {
    repository = _MockRepo();
    when(
      () => repository.updateAppointment(
        any(),
        base: any(named: 'base'),
        checkConflicts: any(named: 'checkConflicts'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => repository.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).thenAnswer((_) async => const []);
  });

  Future<void> pumpAndOpen(
    WidgetTester tester, {
    List<EmployeeRecord> roster = const [],
    AppointmentRecord? block,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(repository),
          employeesStreamProvider.overrideWith((_) => Stream.value(roster)),
          isOfflineProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showPersonalBlockClashesIfAny(
                    context,
                    ref,
                    block: block ?? _block,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('asks for CLIENT jobs only, excluding the block itself', (
    tester,
  ) async {
    when(
      () => repository.findClashingAppointments(
        employeeIds: any(named: 'employeeIds'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
        clientJobsOnly: any(named: 'clientJobsOnly'),
      ),
    ).thenAnswer((_) async => const []);

    await pumpAndOpen(tester);

    final call = verify(
      () => repository.findClashingAppointments(
        employeeIds: any(named: 'employeeIds'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: captureAny(named: 'excludeAppointmentId'),
        clientJobsOnly: captureAny(named: 'clientJobsOnly'),
      ),
    ).captured;
    expect(call, [true, 'block']);
  });

  testWidgets('no clashing client job raises no dialog at all', (tester) async {
    // A personal block overlapping only ANOTHER personal block is correct to
    // pass in silence — there is nothing here to fix.
    when(
      () => repository.findClashingAppointments(
        employeeIds: any(named: 'employeeIds'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
        clientJobsOnly: any(named: 'clientJobsOnly'),
      ),
    ).thenAnswer((_) async => const []);

    await pumpAndOpen(tester);

    expect(find.byType(Dialog), findsNothing);
  });

  group('with one clashing job', () {
    setUp(() {
      when(
        () => repository.findClashingAppointments(
          employeeIds: any(named: 'employeeIds'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
          clientJobsOnly: any(named: 'clientJobsOnly'),
        ),
      ).thenAnswer((_) async => [_clashingJob()]);
    });

    testWidgets('lists the job and offers a swap', (tester) async {
      await pumpAndOpen(tester, roster: [_marc, _nadia]);

      expect(find.text('Marc still has jobs booked'), findsOneWidget);
      expect(find.text('Dupont'), findsOneWidget);
      expect(find.text('Swap'), findsOneWidget);
    });

    testWidgets('dismissing writes nothing — the alert is advisory', (
      tester,
    ) async {
      await pumpAndOpen(tester, roster: [_marc, _nadia]);
      await tester.tap(find.text('Leave them'));
      await tester.pumpAndSettle();

      verifyNever(
        () => repository.updateAppointment(
          any(),
          base: any(named: 'base'),
          checkConflicts: any(named: 'checkConflicts'),
        ),
      );
    });

    testWidgets('never offers "Cancel", which would read as cancelling the '
        'time off', (tester) async {
      await pumpAndOpen(tester, roster: [_marc, _nadia]);

      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Leave them'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('the swap strip excludes everyone booked off with them', (
      tester,
    ) async {
      // The block covers Marc and Theo, so Theo is no more available than Marc.
      final pairBlock = _block.copyWith(
        employeeIds: const ['e1', 'e3'],
        employeeNames: const ['Marc Tremblay', 'Theo Roy'],
      );
      await pumpAndOpen(
        tester,
        roster: [_marc, _nadia, _theo],
        block: pairBlock,
      );
      await tester.tap(find.text('Swap').first);
      await tester.pumpAndSettle();

      expect(find.text('Nadia'), findsOneWidget);
      expect(find.text('Theo'), findsNothing);
    });

    testWidgets('a SECOND swap on the same job builds on the first, never on '
        'the dialog-open snapshot', (tester) async {
      // A team day off puts ONE job under two rows. Built from the opening
      // snapshot, the second swap dropped the first replacement and put the
      // person who is off back on the job — the thing this dialog undoes.
      final ines = _person('e4', 'Ines Colas');
      when(
        () => repository.findClashingAppointments(
          employeeIds: any(named: 'employeeIds'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
          clientJobsOnly: any(named: 'clientJobsOnly'),
        ),
      ).thenAnswer(
        (_) async => [
          _clashingJob(
            employeeIds: const ['e1', 'e2'],
            employeeNames: const ['Marc Tremblay', 'Nadia Berger'],
          ),
        ],
      );

      await pumpAndOpen(
        tester,
        roster: [_marc, _nadia, _theo, ines],
        block: _block.copyWith(
          employeeIds: const ['e1', 'e2'],
          employeeNames: const ['Marc Tremblay', 'Nadia Berger'],
        ),
      );

      await tester.tap(find.text('Swap').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Theo'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Swap').first);
      await tester.pumpAndSettle();
      // The list scrolls between a pinned head and footer, and two groups put
      // the second row's crew strip below the fold.
      await tester.ensureVisible(find.text('Ines'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ines'));
      await tester.pumpAndSettle();

      final written =
          verify(
                () => repository.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                  checkConflicts: any(named: 'checkConflicts'),
                ),
              ).captured.last
              as AppointmentRecord;
      expect(
        written.employeeIds,
        containsAll(<String>['e3', 'e4']),
        reason: 'the second swap must build on the first, not replace it',
      );
      expect(
        written.employeeIds,
        isNot(contains('e1')),
        reason: 'Marc is off and must never be put back',
      );
      expect(written.employeeIds, isNot(contains('e2')));
    });

    testWidgets('Undo on the FIRST of two swaps keeps the second, and never '
        'puts the person who is off back', (tester) async {
      // Undo used to write the whole-record snapshot taken when THAT row
      // swapped. With two people off one job that snapshot predates the second
      // swap, so undoing the first silently reverted the second AND re-added
      // someone who is off — while the second row still read "Ines takes this
      // job". Undo now inverts its own swap against the live record.
      final ines = _person('e4', 'Ines Colas');
      when(
        () => repository.findClashingAppointments(
          employeeIds: any(named: 'employeeIds'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
          clientJobsOnly: any(named: 'clientJobsOnly'),
        ),
      ).thenAnswer(
        (_) async => [
          _clashingJob(
            employeeIds: const ['e1', 'e2'],
            employeeNames: const ['Marc Tremblay', 'Nadia Berger'],
          ),
        ],
      );

      await pumpAndOpen(
        tester,
        roster: [_marc, _nadia, _theo, ines],
        block: _block.copyWith(
          employeeIds: const ['e1', 'e2'],
          employeeNames: const ['Marc Tremblay', 'Nadia Berger'],
        ),
      );

      // Row 1: Marc (off) -> Theo.
      await tester.tap(find.text('Swap').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Theo'));
      await tester.pumpAndSettle();

      // Row 2: Nadia (off) -> Ines.
      await tester.tap(find.text('Swap').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Ines'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ines'));
      await tester.pumpAndSettle();

      // Undo row 1 only.
      await tester.tap(find.text('Undo').first);
      await tester.pumpAndSettle();

      final written =
          verify(
                () => repository.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                  checkConflicts: any(named: 'checkConflicts'),
                ),
              ).captured.last
              as AppointmentRecord;
      expect(
        written.employeeIds,
        contains('e1'),
        reason: 'the undone row puts Marc back',
      );
      expect(
        written.employeeIds,
        contains('e4'),
        reason: "Ines took row 2's job and that swap must survive",
      );
      expect(
        written.employeeIds,
        isNot(contains('e2')),
        reason: 'Nadia is off and must not be resurrected by an unrelated undo',
      );
      expect(written.employeeIds, isNot(contains('e3')));
      expect(
        written.employeeNames,
        containsAll(<String>['Marc Tremblay', 'Ines Colas']),
      );
    });

    testWidgets('picking a replacement writes that occurrence, swapping the '
        'id AND the name positionally', (tester) async {
      await pumpAndOpen(tester, roster: [_marc, _nadia]);
      await tester.tap(find.text('Swap'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nadia'));
      await tester.pumpAndSettle();

      final written =
          verify(
                () => repository.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                  checkConflicts: any(named: 'checkConflicts'),
                ),
              ).captured.single
              as AppointmentRecord;
      expect(written.id, 'job-1', reason: 'this occurrence, never the series');
      expect(written.employeeIds, ['e2']);
      expect(written.employeeNames, ['Nadia Berger']);
      expect(find.text('Nadia Berger takes this one'), findsOneWidget);
    });

    testWidgets('a swap replaces, never removes — the crew is never emptied', (
      tester,
    ) async {
      // `AppointmentFormValidator` rejects an empty crew, so a removal would
      // write a state the form itself forbids.
      await pumpAndOpen(tester, roster: [_marc, _nadia]);
      await tester.tap(find.text('Swap'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nadia'));
      await tester.pumpAndSettle();

      final written =
          verify(
                () => repository.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                  checkConflicts: any(named: 'checkConflicts'),
                ),
              ).captured.single
              as AppointmentRecord;
      expect(written.employeeIds, isNotEmpty);
    });

    testWidgets('Undo writes the original assignee back', (tester) async {
      await pumpAndOpen(tester, roster: [_marc, _nadia]);
      await tester.tap(find.text('Swap'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nadia'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      final writes = verify(
        () => repository.updateAppointment(
          captureAny(),
          base: any(named: 'base'),
          checkConflicts: any(named: 'checkConflicts'),
        ),
      ).captured.cast<AppointmentRecord>();
      expect(writes.last.employeeIds, ['e1']);
      expect(writes.last.employeeNames, ['Marc Tremblay']);
      expect(find.text('Swap'), findsOneWidget, reason: 'back to idle');
    });

    testWidgets('a failed swap puts the row back exactly where it was', (
      tester,
    ) async {
      // Each swap writes immediately, so a refused write has to leave the row
      // offering the same replacement rather than claiming it took the job.
      when(
        () => repository.updateAppointment(
          any(),
          base: any(named: 'base'),
          checkConflicts: any(named: 'checkConflicts'),
        ),
      ).thenThrow(Exception('permission-denied'));

      await pumpAndOpen(tester, roster: [_marc, _nadia]);
      await tester.tap(find.text('Swap'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nadia'));
      await tester.pumpAndSettle();

      verify(
        () => repository.updateAppointment(
          any(),
          base: any(named: 'base'),
          checkConflicts: any(named: 'checkConflicts'),
        ),
      ).called(1);
      expect(find.text('Nadia Berger takes this one'), findsNothing);
      expect(
        find.text('Nadia'),
        findsOneWidget,
        reason: 'the open swap strip is the state the row was in',
      );
      expect(find.text('Undo'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a job nobody else can cover says so and hands off', (
      tester,
    ) async {
      when(
        () => repository.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      ).thenAnswer((_) async => [_nadia]);

      await pumpAndOpen(tester, roster: [_marc, _nadia]);
      await tester.tap(find.text('Swap'));
      await tester.pumpAndSettle();

      expect(find.text('Everyone else is booked'), findsOneWidget);
      expect(find.text('Open job'), findsOneWidget);
    });

    testWidgets('the other assignees on the job keep their places', (
      tester,
    ) async {
      when(
        () => repository.findClashingAppointments(
          employeeIds: any(named: 'employeeIds'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
          clientJobsOnly: any(named: 'clientJobsOnly'),
        ),
      ).thenAnswer(
        (_) async => [
          _clashingJob(
            employeeIds: const ['e3', 'e1'],
            employeeNames: const ['Theo Roy', 'Marc Tremblay'],
          ),
        ],
      );

      await pumpAndOpen(tester, roster: [_marc, _nadia, _theo]);
      await tester.tap(find.text('Swap'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nadia'));
      await tester.pumpAndSettle();

      final written =
          verify(
                () => repository.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                  checkConflicts: any(named: 'checkConflicts'),
                ),
              ).captured.single
              as AppointmentRecord;
      expect(written.employeeIds, ['e3', 'e2']);
      expect(written.employeeNames, ['Theo Roy', 'Nadia Berger']);
    });
  });
}
