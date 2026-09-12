import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/domain/models/job_template.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/widgets/fields/appointment_address_field.dart';
import 'package:scheduling/features/calendar/widgets/fields/repeat_interval_picker.dart';
import 'package:scheduling/features/calendar/widgets/sections/appointment_form_fields.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';

void main() {
  Future<AppointmentFormControllers> pumpAppointmentForm(
    WidgetTester tester, {
    required double width,
    String clientQuery = '',
    List<ClientRecord> clientResults = const [],
    ValueChanged<ClientRecord>? onSelectClient,
    ClientRecord? selectedClient,
    bool useCustomAddress = true,
    Future<ClientRecord?> Function(String initialName)? onRequestAddClient,
    ValueChanged<JobTemplate>? onApplyTemplate,
    Map<String, AppointmentFormError> errors = const {},
    bool isPersonal = false,
    bool isDayOff = false,
    ValueChanged<bool>? onPersonalChanged,
    ValueChanged<bool>? onDayOffChanged,
    bool showPersonalSwitch = true,
    bool isAllDay = false,
    ValueChanged<bool>? onAllDayChanged,
    bool isMultiDay = false,
    bool isRunMember = false,
    bool canSpanDays = true,
    bool isOvernight = false,
    int spanLength = 1,
    DateTime? selectedDate,
    DateTime? endDate,
    ValueChanged<DateTime>? onSelectStartDate,
    ValueChanged<DateTime>? onSelectEndDate,
    ClientSearchStatus clientSearchStatus = const ClientSearchStatus(),
    Widget Function(TourStepId, Widget)? tourWrap,
  }) async {
    tester.view.physicalSize = Size(width, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controllers = AppointmentFormControllers(
      title: TextEditingController(),
      date: TextEditingController(),
      endDate: TextEditingController(),
      startTime: TextEditingController(),
      endTime: TextEditingController(),
      clientSearch: TextEditingController(),
      address: TextEditingController(),
      notes: TextEditingController(),
      materials: TextEditingController(),
    );
    controllers.clientSearch.text = clientQuery;
    addTearDown(controllers.dispose);

    await tester.pumpWidget(
      // The address field is a ConsumerStatefulWidget that resolves its logger
      // in initState, so the tree needs a real scope.
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AppointmentFormFields(
                controllers: controllers,
                allEmployees: const [],
                selectedClient: selectedClient,
                clientResults: clientResults,
                isSearchingClient: false,
                clientSearchStatus: clientSearchStatus,
                selectedEmployees: const [],
                repeat: RepeatInterval.none,
                useCustomAddress: useCustomAddress,
                selectedDate: selectedDate,
                endDate: endDate,
                isPersonal: isPersonal,
                isDayOff: isDayOff,
                onPersonalChanged: showPersonalSwitch
                    ? (onPersonalChanged ?? (_) {})
                    : null,
                isAllDay: isAllDay,
                isMultiDay: isMultiDay,
                isRunMember: isRunMember,
                canSpanDays: canSpanDays,
                isOvernight: isOvernight,
                spanLength: spanLength,
                errors: errors,
                employeeLabel: 'Employee',
                employeeRequired: false,
                materialsHint: 'Materials',
                photosSection: const SizedBox.shrink(),
                callbacks: AppointmentFormCallbacks(
                  onSearchClients: (_) {},
                  onRetryClientSearch: () {},
                  onSelectClient: onSelectClient ?? (_) {},
                  onClearClient: () {},
                  onToggleEmployee: (_) {},
                  onSelectStartDate: onSelectStartDate ?? (_) {},
                  onSelectEndDate: onSelectEndDate ?? (_) {},
                  onPickStartTime: () {},
                  onPickEndTime: () {},
                  onSelectRepeat: (_) {},
                  onUseCustomAddress: (_) {},
                  onDayOffChanged: onDayOffChanged ?? (_) {},
                  onAllDayChanged: onAllDayChanged ?? (_) {},
                ),
                onRequestAddClient: onRequestAddClient,
                onApplyTemplate: onApplyTemplate,
                tourWrap: tourWrap,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controllers;
  }

  testWidgets('time fields stack vertically on narrow phone widths', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 320);

    final startLabel = tester.getTopLeft(find.text('Start time'));
    final endLabel = tester.getTopLeft(find.text('End time'));

    expect(endLabel.dy, greaterThan(startLabel.dy + 20));
    expect((endLabel.dx - startLabel.dx).abs(), lessThan(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('job template chips fire onApplyTemplate with the picked type', (
    tester,
  ) async {
    JobTemplate? picked;
    await pumpAppointmentForm(
      tester,
      width: 400,
      onApplyTemplate: (t) => picked = t,
    );

    await tester.tap(find.text('Water heater'));
    await tester.pumpAndSettle();
    expect(picked, JobTemplate.waterHeater);
  });

  testWidgets('no template chips render without onApplyTemplate (edit flow)', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400);
    expect(find.text('TEMPLATES'), findsNothing);
    expect(find.text('Water heater'), findsNothing);
  });

  testWidgets('inline add-client auto-selects the created client', (
    tester,
  ) async {
    const created = ClientRecord(
      id: 'c-new',
      name: 'New Guy',
      address: '9 Rue Test',
    );
    final selected = <ClientRecord>[];
    final controllers = await pumpAppointmentForm(
      tester,
      width: 400,
      clientQuery: 'New', // typed text that matched nothing
      onSelectClient: selected.add,
      onRequestAddClient: (name) async => created,
    );

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    // The returned client is selected and its name fills the search box.
    expect(selected.single.id, 'c-new');
    expect(controllers.clientSearch.text, 'New Guy');
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the mono section labels', (tester) async {
    await pumpAppointmentForm(tester, width: 400, onApplyTemplate: (_) {});

    // TEMPLATES is gone — the chips live under the field they fill now.
    expect(find.text('TEMPLATES'), findsNothing);
    expect(find.text('WHO'), findsOneWidget);
    expect(find.text('SCHEDULE'), findsOneWidget);
    expect(find.text('DETAILS'), findsOneWidget);
  });

  testWidgets('the date and time pickers render as panel rows', (tester) async {
    await pumpAppointmentForm(tester, width: 400);

    // Start/end date, start/end time and repeat — pickers, not text entry, and
    // all in the one schedule panel.
    expect(find.byType(SheetFieldRow), findsNWidgets(5));
    expect(find.byType(SheetPanel), findsOneWidget);
  });

  testWidgets('the schedule panel offers a start and an end date', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400);

    expect(find.text('Start date'), findsOneWidget);
    expect(find.text('End date'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the all-day switch renders on a client job too', (tester) async {
    await pumpAppointmentForm(tester, width: 400);

    expect(find.text('All day'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a multi-day job labels its times as a daily window', (
    tester,
  ) async {
    await pumpAppointmentForm(
      tester,
      width: 400,
      isMultiDay: true,
      spanLength: 3,
    );

    expect(find.text('Start time · each day'), findsOneWidget);
    expect(find.text('End time · each day'), findsOneWidget);
    expect(find.text('3 days'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overnight multi-day job counts nights', (tester) async {
    await pumpAppointmentForm(
      tester,
      width: 400,
      isMultiDay: true,
      isOvernight: true,
      spanLength: 2,
    );

    expect(find.text('Start time · each night'), findsOneWidget);
    expect(find.text('End time · next morning'), findsOneWidget);
    expect(find.text('2 nights'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single-day job shows no run length beside the end date', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400, spanLength: 3);

    expect(find.text('3 days'), findsNothing);
    expect(find.text('3 nights'), findsNothing);
    expect(find.text('Start time'), findsOneWidget);
    expect(find.text('End time'), findsOneWidget);
  });

  testWidgets(
    'a personal job hides the client picker but keeps the address, optional',
    (tester) async {
      await pumpAppointmentForm(tester, width: 400, isPersonal: true);

      expect(find.text('Personal job'), findsOneWidget);
      expect(find.text('Client'), findsNothing);
      // A personal block can still have somewhere to be — the field stays, and
      // says so rather than reading as an unfinished required one.
      expect(find.text('Job address'), findsWidgets);
      expect(
        tester
            .widget<AppointmentAddressField>(
              find.byType(AppointmentAddressField),
            )
            .optional,
        isTrue,
      );
      // The rest of the form is untouched.
      expect(find.text('WHO'), findsOneWidget);
      expect(find.text('DETAILS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the Day off chip is offered only on a personal job', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400);
    expect(find.widgetWithText(FilterChip, 'Day off'), findsNothing);

    await pumpAppointmentForm(tester, width: 400, isPersonal: true);
    expect(find.widgetWithText(FilterChip, 'Day off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the Day off chip reports the new value', (tester) async {
    final changes = <bool>[];
    await pumpAppointmentForm(
      tester,
      width: 400,
      isPersonal: true,
      onDayOffChanged: changes.add,
    );

    await tester.tap(find.widgetWithText(FilterChip, 'Day off'));
    await tester.pumpAndSettle();

    expect(changes, [true]);
  });

  testWidgets('a client visit does not mark its address optional', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400);

    expect(
      tester
          .widget<AppointmentAddressField>(find.byType(AppointmentAddressField))
          .optional,
      isFalse,
    );
  });

  testWidgets('switching a job to personal clears the hidden fields', (
    tester,
  ) async {
    final toggled = <bool>[];
    final controllers = await pumpAppointmentForm(
      tester,
      width: 400,
      clientQuery: 'Acme Ltd',
      onPersonalChanged: toggled.add,
    );
    controllers.address.text = '9 Rue Test';

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(toggled, [true]);
    // The client picker is gone, so it may not keep its value.
    expect(controllers.clientSearch.text, isEmpty);
    // A HAND-TYPED address survives: a personal block may well have somewhere
    // to be, and this is the case the field exists for.
    expect(controllers.address.text, '9 Rue Test');
  });

  testWidgets('switching to personal drops the CLIENT address', (tester) async {
    // `_selectClient` writes the client's address into the controller and it
    // renders as a read-only pill, so the admin never typed it. The switch is
    // the first row of WHO while the field is far below in DETAILS, so leaving
    // it behind silently gave the personal block a client's street — which the
    // travel sweep then uses as the crew's destination.
    final controllers = await pumpAppointmentForm(
      tester,
      width: 400,
      selectedClient: const ClientRecord(
        id: 'c1',
        name: 'Marchetti',
        address: '12 Rue Principale',
      ),
      useCustomAddress: false,
      onPersonalChanged: (_) {},
    );
    controllers.address.text = '12 Rue Principale';

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(controllers.address.text, isEmpty);
  });

  testWidgets('an address typed before any client is picked survives', (
    tester,
  ) async {
    // `useCustomAddress` is still false at this point — it only flips when the
    // admin taps "Change" on the pill — so testing that flag ALONE would wipe
    // an address the user typed themselves. Both halves of the guard matter.
    final controllers = await pumpAppointmentForm(
      tester,
      width: 400,
      useCustomAddress: false,
      onPersonalChanged: (_) {},
    );
    controllers.address.text = '400 Rue Mine';

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(controllers.address.text, '400 Rue Mine');
  });

  testWidgets('an all-day personal job drops the start and end rows', (
    tester,
  ) async {
    await pumpAppointmentForm(
      tester,
      width: 400,
      isPersonal: true,
      isAllDay: true,
    );

    expect(find.text('All day'), findsOneWidget);
    // Only the date pair is left in the schedule panel.
    expect(find.byType(SheetFieldRow), findsNWidgets(2));
    expect(find.text('Start time'), findsNothing);
    expect(find.text('End time'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the job-template chips sit under Service / Title, above Client', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400, onApplyTemplate: (_) {});

    // A template fills the title and the duration and nothing else, so it
    // belongs beside the field it fills, not in a section above the form.
    final title = tester.getBottomLeft(find.text('Service / Title')).dy;
    final chip = tester.getTopLeft(find.text('Water heater')).dy;
    final client = tester.getTopLeft(find.text('Client')).dy;

    expect(chip, greaterThan(title));
    expect(chip, lessThan(client));
    expect(find.text('Tap one to fill the title and duration'), findsOneWidget);
  });

  testWidgets('the apptTemplates tour step targets the title and the chips', (
    tester,
  ) async {
    await pumpAppointmentForm(
      tester,
      width: 400,
      onApplyTemplate: (_) {},
      tourWrap: (id, child) =>
          KeyedSubtree(key: ValueKey('tour-${id.name}'), child: child),
    );

    // The member is KEPT and only its target moves: the name IS the tour's
    // storage key, so renaming or retiring it would replay or orphan the
    // walkthrough on every installed device.
    final target = find.byKey(const ValueKey('tour-apptTemplates'));
    expect(target, findsOneWidget);
    expect(
      find.descendant(of: target, matching: find.text('Service / Title')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: target, matching: find.text('Water heater')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a personal job drops the templates, repeat and job-site fields',
    (tester) async {
      await pumpAppointmentForm(
        tester,
        width: 400,
        isPersonal: true,
        onApplyTemplate: (_) {},
      );

      expect(find.text('Water heater'), findsNothing);
      expect(find.text('Repeat'), findsNothing);
      expect(find.text('Materials needed'), findsNothing);
      expect(find.text('Pictures'), findsNothing);
    },
  );

  testWidgets('the personal switch is hidden without a change callback', (
    tester,
  ) async {
    // The edit flow passes null on a job that was never personal.
    await pumpAppointmentForm(tester, width: 400, showPersonalSwitch: false);
    expect(find.text('Personal job'), findsNothing);
    expect(find.text('Client'), findsOneWidget);
  });

  testWidgets('a picker row surfaces its validation error', (tester) async {
    await pumpAppointmentForm(
      tester,
      width: 400,
      errors: const {'date': AppointmentFormError.dateRequired},
    );

    // The row surfaces the validator's message inline, not a bare red border.
    expect(find.text('Please select a date'), findsOneWidget);
  });

  testWidgets('the repeat picker is hidden once the job spans days', (
    tester,
  ) async {
    await pumpAppointmentForm(tester, width: 400, isMultiDay: true);
    expect(find.byType(RepeatIntervalPicker), findsNothing);
  });

  testWidgets('the repeat picker is offered on a one-day job', (tester) async {
    await pumpAppointmentForm(tester, width: 400);
    expect(find.byType(RepeatIntervalPicker), findsOneWidget);
  });

  testWidgets('a run member does not offer an end date', (tester) async {
    // Each day of a run IS one appointment, so its length is not editable.
    await pumpAppointmentForm(tester, width: 400, isRunMember: true);
    expect(find.text('End date'), findsNothing);
    expect(find.text('Start date'), findsOneWidget);
  });

  testWidgets('an ordinary job still offers an end date', (tester) async {
    await pumpAppointmentForm(tester, width: 400);
    expect(find.text('End date'), findsOneWidget);
  });

  testWidgets('editing a client job cannot widen it into a run', (
    tester,
  ) async {
    // Only the ADD path fans a span into one document per day. Offering the
    // row on edit wrote the single WIDE document the split exists to remove —
    // it renders "Day 3 of 5" but marking one day complete closes the week.
    await pumpAppointmentForm(tester, width: 400, canSpanDays: false);
    expect(find.text('End date'), findsNothing);
    expect(find.text('Start date'), findsOneWidget);
  });

  const withAddress = ClientRecord(
    id: 'c1',
    name: 'Groupe Lemieux',
    phone: '5145550142',
    address: '4188 Rue Sainte-Catherine E',
  );
  const noAddress = ClientRecord(
    id: 'c2',
    name: 'Anne Roy',
    phone: '5145550199',
  );

  testWidgets('the toggle ON hides the Job address section', (tester) async {
    await pumpAppointmentForm(
      tester,
      width: 400,
      selectedClient: withAddress,
      useCustomAddress: false,
    );
    expect(find.text('Job address'), findsNothing);
  });

  testWidgets('the toggle OFF shows the Job address section', (tester) async {
    await pumpAppointmentForm(tester, width: 400, selectedClient: withAddress);
    // Label and placeholder both, now the field carries the section's name.
    expect(find.text('Job address'), findsWidgets);
  });

  testWidgets('a client with NO address on file keeps the field', (
    tester,
  ) async {
    // This client sits at useCustomAddress == false too, and shows no toggle -
    // hiding here would make the job unable to get an address at all.
    await pumpAppointmentForm(
      tester,
      width: 400,
      selectedClient: noAddress,
      useCustomAddress: false,
    );
    expect(find.text('Job address'), findsOneWidget);
  });
}
