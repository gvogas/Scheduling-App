import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_pickers.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/features/calendar/application/add_event_controller.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/domain/models/job_template.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/utils/assignee_availability_scope.dart';
import 'package:scheduling/features/calendar/utils/client_booking_context_scope.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/busy_conflict_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/personal_block_clash_dialog.dart';
import 'package:scheduling/features/calendar/widgets/fields/employee_picker.dart';
import 'package:scheduling/features/calendar/widgets/sections/appointment_form_fields.dart';
import 'package:scheduling/features/calendar/widgets/sections/photo_picker_section.dart';
import 'package:scheduling/features/calendar/widgets/sheets/image_source_picker.dart';
import 'package:scheduling/features/calendar/widgets/sheets/inline_add_client_host.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/offline_form_notice.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';

class AddEventSheet extends ConsumerStatefulWidget {
  const AddEventSheet({super.key, this.initialDate, this.prefill});

  final DateTime? initialDate;

  /// Pre-seeds the draft: a client for the book-job flows, a whole job for
  /// "book again".
  final AppointmentPrefill? prefill;

  @override
  ConsumerState<AddEventSheet> createState() => _AddEventSheetState();
}

class _AddEventSheetState extends ConsumerState<AddEventSheet>
    with InlineAddClientHost {
  final _controllers = AppointmentFormControllers(
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
  late final Debouncer _clientSearchDebounce;
  late final _provider = addEventControllerProvider(widget.initialDate);

  // This sheet is only reachable from admin-gated surfaces.
  final _tour = TourSteps(
    const FormTour(TourForm.addAppointment),
    isAdmin: true,
  );

  AddEventController get _notifier => ref.read(_provider.notifier);

  @override
  void initState() {
    super.initState();
    _clientSearchDebounce = Debouncer.tagged(
      kSearchDebounce,
      logger: ref.read(loggerProvider),
      tag: 'CLI-SEARCH debounced client search failed',
    );
    final initialDate = widget.initialDate;
    if (initialDate != null) {
      _controllers.date.text = DateUtilsHelper.formatDate(initialDate);
      _controllers.endDate.text = _controllers.date.text;
    }
    final prefill = widget.prefill;
    if (prefill != null) _seedFrom(prefill);
    // A sheet route carries no name, so the observer skips it — the form
    // reports itself here. Without this the create funnel has no entry step and
    // only its successful completions are visible.
    ref
        .read(analyticsServiceProvider)
        .logScreenView(AnalyticsScreens.addAppointment);
  }

  /// Text lives in the controllers; the rest is state, applied once the family
  /// provider exists.
  void _seedFrom(AppointmentPrefill prefill) {
    final client = prefill.client;
    _controllers.title.text = prefill.title;
    _controllers.notes.text = prefill.notes;
    _controllers.materials.text = prefill.materialsNeeded;
    _controllers.clientSearch.text = client?.displayName ?? '';
    // Submit reads this field even under the client-address pill, so it has to
    // hold the pill's address too, the way picking a client fills it.
    _controllers.address.text = prefill.address.isNotEmpty
        ? AddressParser.canonicalToDisplay(prefill.address)
        : client?.fullAddress ?? '';
    // Defer until the family provider is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_notifier.applyPrefill(prefill));
    });
  }

  @override
  void dispose() {
    _clientSearchDebounce.dispose();
    _controllers.dispose();
    super.dispose();
  }

  void _onClientSearchChanged(String query) {
    if (query.trim().isEmpty) {
      _clientSearchDebounce.cancel();
      _notifier.searchClients('');
      return;
    }
    _clientSearchDebounce.run(() => _notifier.searchClients(query));
  }

  void _onRetryClientSearch() =>
      unawaited(_notifier.searchClients(_controllers.clientSearch.text));

  /// Handles already-picked inline calendar dates.
  void _onStartDateSelected(DateTime picked) {
    // selectDate emits the rebuild after controller updates.
    _controllers.date.text = DateUtilsHelper.formatDate(picked);
    _notifier.selectDate(picked);
    // Keep the end-date controller synced after selectDate.
    final shifted = ref.read(_provider).endDate;
    if (shifted != null) {
      _controllers.endDate.text = DateUtilsHelper.formatDate(shifted);
    }
  }

  void _onEndDateSelected(DateTime picked) {
    _controllers.endDate.text = DateUtilsHelper.formatDate(picked);
    _notifier.selectEndDate(picked);
  }

  Future<void> _pickStartTime() async {
    final stateBefore = ref.read(_provider);
    final picked = await showAdaptiveTimePicker(
      context,
      initialTime: stateBefore.selectedStartTime,
    );
    if (picked == null || !mounted) return;
    _controllers.startTime.text = picked.format(context);
    _notifier.selectStartTime(picked);
    // The auto end is the controller's call (plain default or seeded length).
    _syncEndTimeText();
  }

  void _syncEndTimeText() {
    final end = ref.read(_provider).selectedEndTime;
    if (end != null) _controllers.endTime.text = end.format(context);
  }

  Future<void> _pickEndTime() async {
    final state = ref.read(_provider);
    final picked = await showAdaptiveTimePicker(
      context,
      initialTime: state.selectedEndTime,
    );
    if (picked == null || !mounted) return;
    _controllers.endTime.text = picked.format(context);
    _notifier.selectEndTime(picked);
  }

  // Applies the template title and duration.
  void _applyTemplate(JobTemplate template) {
    _controllers.title.text = jobTemplateLabel(context.l10n, template);
    _notifier.setDurationMinutes(template.defaultDurationMinutes);
    _syncEndTimeText();
  }

  int _spanLength(AddEventState state) =>
      runLengthDays(state.selectedDate, state.endDate);

  bool _isOvernight(AddEventState state) {
    final start = state.selectedStartTime;
    final end = state.selectedEndTime;
    if (state.isAllDay || start == null || end == null) return false;
    return isOvernightWindow(start, end);
  }

  Future<void> _pickImages() => pickAndAddAppointmentImages(
    context,
    ref,
    addImages: _notifier.addImages,
    remainingSlots: () => _notifier.remainingImageSlots,
  );

  Future<void> _submit() async {
    // Blank personal titles save as "Personal".
    final title = _controllers.title.text.trim().isEmpty
        ? (ref.read(_provider).isPersonal ? context.l10n.calendar_personal : '')
        : _controllers.title.text;

    Future<AddEventSubmitOutcome> attempt({bool forceBusy = false}) =>
        _notifier.submit(
          title: title,
          address: AddressParser.toCanonical(_controllers.address.text),
          notes: _controllers.notes.text,
          materialsNeeded: _controllers.materials.text,
          forceBusy: forceBusy,
        );

    final outcome = await retryPastBusyConflict(
      context,
      attempt: attempt,
      busyOf: (o) => o is AddEventBusyEmployees
          ? (busyEmployees: o.busyEmployees, start: o.start, end: o.end)
          : null,
    );
    // The helper already returned null if unmounted; repeated so the
    // analyzer can still see the guard across the await.
    if (outcome == null || !mounted) return;
    switch (outcome) {
      case AddEventSubmitted(
        :final appointment,
        :final futureBookings,
        :final runDays,
      ):
        // Fires on the SUBMITTED branch only. `AddEventBusy` is the reentrancy
        // guard's no-op and `AddEventBusyEmployees` returns to the sheet for a
        // force-through choice — counting either as a creation would report
        // jobs that were never written.
        ref
            .read(analyticsServiceProvider)
            .logAppointmentCreated(
              source: AnalyticsSources.calendar,
              repeat: appointment.repeat.name,
              assigneeCount: appointment.employeeIds.length,
              hasPhotos: appointment.pictureCount > 0,
              isPersonal: appointment.isPersonal,
              isAllDay: appointment.isAllDay,
              isDayOff: appointment.isDayOff,
              isMultiDay: runDays > 1,
            );
        // A run and a repeat series are different things and must not share a
        // sentence: a 5-day job is ONE job over 5 days, not 4 future visits.
        ref.read(noticeServiceProvider).success(switch ((
          runDays,
          futureBookings,
        )) {
          (final days, _) when days > 1 =>
            context.l10n.calendar_appointmentCreatedRunDays(days),
          (_, final repeats) when repeats > 0 =>
            context.l10n.calendar_appointmentCreatedWithRepeats(repeats),
          _ => context.l10n.common_appointmentCreated,
        });
        // Show clashes before closing this sheet.
        await showPersonalBlockClashesIfAny(context, ref, block: appointment);
        if (!mounted) return;
        Navigator.pop(context, appointment);
      case AddEventFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introCreateAppointment,
                error: error,
              ),
            );
      // These outcomes already surfaced or intentionally stay silent.
      case AddEventInvalid() || AddEventBusyEmployees() || AddEventBusy():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_provider);
    // Crew only; dispatchers are not assignable.
    final roster = ref.watch(assignableEmployeesProvider);
    // An assignee is REQUIRED to save, so "still loading" and "the read failed"
    // must not both render as "this business has no staff".
    final allEmployees = roster.asData?.value ?? const [];
    // One span length feeds both the flag and label.
    final spanLength = _spanLength(state);
    final bookingContext = watchClientBookingContext(
      ref,
      client: state.selectedClient,
    );

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: true,
      stepKeys: _tour.keys,
      // The form scrolls, so below-fold targets need building before
      // isTargetRendered looks for them.
      autoScroll: true,
      child: FormSheetFrame(
        title: context.l10n.calendar_newAppointment,
        primaryLabel: context.l10n.common_save,
        isBusy: state.isSubmitting,
        onPrimary: _submit,
        headerTourWrap: (child) => _tour.stepIf(TourStepId.apptSave, child),
        scrollCacheExtent: kTourScrollCacheExtent,
        children: [
          // First, so the person is told BEFORE filling the form in — the
          // submit controller already fails fast, and the app's global offline
          // banner is drawn under the page, behind this sheet.
          const OfflineFormNotice(),
          AppointmentFormFields(
            controllers: _controllers,
            tourWrap: _tour.stepIf,
            allEmployees: allEmployees,
            rosterStatus: rosterStatusOf(roster),
            onRetryRoster: () => ref.invalidate(assignableEmployeesProvider),
            // Nothing is stored yet, so the live selection is the whole of
            // "already on this job".
            assigneeAvailability: watchAssigneeAvailability(
              ref,
              date: state.selectedDate,
              endDate: state.endDate,
              isAllDay: state.isAllDay,
              isPersonal: state.isPersonal,
              startTime: state.selectedStartTime,
              endTime: state.selectedEndTime,
              alreadyAssignedIds: const {},
            ),
            selectedClient: state.selectedClient,
            clientResults: state.clientResults,
            isSearchingClient: state.isSearchingClient,
            clientSearchStatus: state.clientSearchStatus,
            previousAddresses: bookingContext.previousAddresses,
            lastVisitLabel: bookingContext.lastVisitLabel,
            selectedEmployees: state.selectedEmployees,
            repeat: state.repeat,
            useCustomAddress: state.useCustomAddress,
            selectedDate: state.selectedDate,
            endDate: state.endDate,
            isPersonal: state.isPersonal,
            isDayOff: state.isDayOff,
            onPersonalChanged: (value) => _notifier.setPersonal(value: value),
            isAllDay: state.isAllDay,
            errors: state.errors,
            employeeLabel: context.l10n.calendar_assignEmployee,
            employeeRequired: true,
            materialsHint: context.l10n.calendar_typeTheMaterialsHere,
            onApplyTemplate: _applyTemplate,
            onRequestAddClient: requestAddClient,
            isMultiDay: spanLength > 1,
            isOvernight: _isOvernight(state),
            spanLength: spanLength,
            callbacks: AppointmentFormCallbacks(
              onSearchClients: _onClientSearchChanged,
              onRetryClientSearch: _onRetryClientSearch,
              onSelectClient: _notifier.selectClient,
              onClearClient: _notifier.clearClient,
              onToggleEmployee: _notifier.toggleEmployee,
              onSelectStartDate: _onStartDateSelected,
              onSelectEndDate: _onEndDateSelected,
              onPickStartTime: _pickStartTime,
              onPickEndTime: _pickEndTime,
              onSelectRepeat: _notifier.selectRepeat,
              onUseCustomAddress: (value) =>
                  _notifier.setUseCustomAddress(value: value),
              onDayOffChanged: (value) => _notifier.setDayOff(value: value),
              onAllDayChanged: (value) => _notifier.setAllDay(value: value),
            ),
            photosSection: PhotoPickerSection(
              existingImages: const [],
              newImages: state.selectedImages,
              isEditing: true,
              onPickImages: _pickImages,
              onRemoveExisting: (_) {},
              onRemoveNew: _notifier.removeImage,
            ),
          ),
        ],
      ),
    );
  }
}
