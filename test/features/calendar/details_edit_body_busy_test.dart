import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/notice_listener.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/sections/appointment_form_fields.dart';
import 'package:scheduling/features/calendar/widgets/views/details_edit_body.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/offline_form_notice.dart';

import '../../support/tour_test_support.dart';

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

class _MockClientsRepo extends Mock implements ClientsRepository {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

/// Returns Busy from both actions, which is what the reentrancy guards do when
/// a second tap lands on a write already in flight.
class _BusyController extends EventDetailsController {
  _BusyController(super.key);

  @override
  Future<EventDetailsSaveOutcome> save(
    AppointmentRecord appointment, {
    required String title,
    required String address,
    required String notes,
    required String materialsNeeded,
    bool applyToSeries = false,
    bool forceBusy = false,
  }) async => const EventDetailsSaveBusy();

  @override
  Future<EventDetailsActionOutcome> deleteAppointment(
    AppointmentRecord appointment, {
    bool includeFuture = false,
  }) async => const EventDetailsActionBusy();
}

const _client = ClientRecord(id: 'c1', name: 'Existing Client');

const _employee = EmployeeRecord(id: 'e1', name: 'Alex');

final _open = AppointmentRecord(
  id: 'appt-1',
  title: 'Leak fix',
  startTime: DateTime(2026, 5, 10, 9),
  endTime: DateTime(2026, 5, 10, 10),
  clientId: 'c1',
  clientName: 'Existing Client',
  employeeIds: const ['e1'],
  employeeNames: const ['Alex'],
);

/// A skipped write must announce NOTHING — not a success notice, not an error.
/// Both branches were unexercised, and the success one is the dangerous half:
/// the sheet would say "saved" over a write the guard threw away.
void main() {
  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late AppointmentFormControllers controllers;
  late List<AppointmentRecord> savedRecords;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markFormToursSeen();
    savedRecords = [];
    appointments = _MockAppointmentsRepo();
    clients = _MockClientsRepo();
    employees = _MockEmployeesRepo();
    controllers = AppointmentFormControllers(
      title: TextEditingController(text: 'Leak fix'),
      date: TextEditingController(),
      endDate: TextEditingController(),
      startTime: TextEditingController(),
      endTime: TextEditingController(),
      clientSearch: TextEditingController(),
      address: TextEditingController(),
      notes: TextEditingController(),
      materials: TextEditingController(),
    );
    addTearDown(controllers.dispose);

    when(() => clients.getClientById(any())).thenAnswer((_) async => _client);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const [_employee]));
    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => appointments.fetchAppointmentPictures(any()),
    ).thenAnswer((_) async => const <AppointmentImage>[]);
    when(
      () => appointments.fetchClientHistory(
        clientId: any(named: 'clientId'),
        limit: any(named: 'limit'),
        cap: any(named: 'cap'),
      ),
    ).thenAnswer((_) async => const <AppointmentRecord>[]);
    when(
      () => appointments.findClashingAppointments(
        employeeIds: any(named: 'employeeIds'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
        clientJobsOnly: any(named: 'clientJobsOnly'),
      ),
    ).thenAnswer((_) async => const <AppointmentRecord>[]);
  });

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onClose,
    bool offline = false,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(clients),
          employeesRepositoryProvider.overrideWithValue(employees),
          photoUploadNotifierProvider.overrideWithValue(PhotoUploadNotifier()),
          isOfflineProvider.overrideWithValue(offline),
          eventDetailsControllerProvider(
            EventDetailsKey(_open),
          ).overrideWith(() => _BusyController(EventDetailsKey(_open))),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          builder: (context, child) => NoticeListener(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: DetailsEditBody(
              appointment: _open,
              controllers: controllers,
              onSaved: savedRecords.add,
              onClose: onClose ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a save skipped by the guard announces nothing', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Changes saved'), findsNothing);
    expect(find.textContaining("Couldn't save"), findsNothing);
    expect(savedRecords, isEmpty);
  });

  testWidgets('offline, the edit form says so up front', (tester) async {
    await pump(tester, offline: true);

    expect(find.byType(OfflineFormNotice), findsOneWidget);
  });

  testWidgets('Cancel asks only once the draft differs from the record', (
    tester,
  ) async {
    var closed = false;
    await pump(tester, onClose: () => closed = true);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(closed, isTrue);

    closed = false;
    await tester.enterText(find.byType(TextField).first, 'Leak fix, urgent');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(closed, isFalse);
  });

  testWidgets('a delete skipped by the guard neither closes nor announces', (
    tester,
  ) async {
    var closed = false;
    await pump(tester, onClose: () => closed = true);

    await tester.ensureVisible(find.text('Delete Appointment'));
    await tester.pumpAndSettle();

    // Fixed pumps, not pumpAndSettle: the frame parks its primary button on a
    // spinner for the whole dialog, and a spinner never settles.
    await tester.tap(find.text('Delete Appointment'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The confirm dialog's own destructive verb.
    await tester.tap(find.text('Delete').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(closed, isFalse);
    expect(find.text('Appointment deleted'), findsNothing);
    expect(find.textContaining("Couldn't delete"), findsNothing);
  });
}
