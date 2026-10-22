import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/application/add_event_controller.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/widgets/sections/appointment_form_fields.dart';
import 'package:scheduling/features/calendar/widgets/sheets/add_appointment_sheet.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../../support/tour_test_support.dart';

const _client = ClientRecord(
  id: 'c1',
  name: 'Acme Plumbing',
  address: '12 Main St',
);

Widget _harness({AppointmentPrefill? prefill, DateTime? initialDate}) =>
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AddEventSheet(prefill: prefill, initialDate: initialDate),
        ),
      ),
    );

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markFormToursSeen();
  });

  AppointmentFormControllers controllersOf(WidgetTester tester) => tester
      .widget<AppointmentFormFields>(find.byType(AppointmentFormFields))
      .controllers;

  AddEventState draftOf(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(AddEventSheet)),
  ).read(addEventControllerProvider(null));

  testWidgets('a client prefill pre-seeds the client field', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(prefill: const AppointmentPrefill(client: _client)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Acme Plumbing'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a client prefill seeds the address the pill shows', (
    tester,
  ) async {
    // Submit reads the address CONTROLLER even while the client-address pill
    // hides it, so an unseeded one saved a job with no address at all.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(prefill: const AppointmentPrefill(client: _client)),
    );
    await tester.pumpAndSettle();

    expect(controllersOf(tester).address.text, _client.fullAddress);
    expect(draftOf(tester).selectedClient, _client);
    expect(draftOf(tester).useCustomAddress, isFalse);
  });

  testWidgets('a landed prefill is the baseline, so Cancel asks nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(prefill: const AppointmentPrefill(client: _client)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'Leak fix');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
  });

  testWidgets('a failed Save focuses the first errored field', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(draftOf(tester).errors, contains('title'));
    expect(controllersOf(tester).title.text, isEmpty);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'title');
  });

  testWidgets('no prefill leaves the client field empty', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('Acme Plumbing'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a book-again prefill seeds the text fields and the draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // No crew here: the roster resolution is the controller test's.
    await tester.pumpWidget(
      _harness(
        prefill: const AppointmentPrefill(
          client: _client,
          useCustomAddress: true,
          address: '99 Other Rd',
          title: 'Water heater',
          notes: 'Gate code 4821',
          materialsNeeded: 'anode rod',
          durationMinutes: 90,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final controllers = controllersOf(tester);
    expect(controllers.title.text, 'Water heater');
    expect(controllers.notes.text, 'Gate code 4821');
    expect(controllers.materials.text, 'anode rod');
    expect(controllers.address.text, '99 Other Rd');
    // The when is the admin's to pick.
    expect(controllers.date.text, isEmpty);
    expect(controllers.startTime.text, isEmpty);
    expect(controllers.endTime.text, isEmpty);
    final draft = draftOf(tester);
    expect(draft.selectedClient, _client);
    expect(draft.useCustomAddress, isTrue);
    expect(draft.durationMinutes, 90);
    expect(draft.selectedDate, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a later end date turns the draft into a multi-day run', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Aug 1 2026 — the day defaults, so it is left off to satisfy the linter.
    await tester.pumpWidget(_harness(initialDate: DateTime(2026, 8)));
    await tester.pumpAndSettle();

    // The row drops the month down beneath itself rather than opening a modal
    // picker, so the day is one tap inside the form.
    await tester.tap(find.text('End date'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inline-date-day-2026-08-03')));
    await tester.pumpAndSettle();

    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 8, 3))),
      findsOneWidget,
    );
    expect(find.text('3 days'), findsOneWidget);
    expect(find.text('Start time · each day'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
