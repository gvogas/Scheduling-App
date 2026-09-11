import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_pickers.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/application/event_series_helpers.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/utils/assignee_availability_scope.dart';
import 'package:scheduling/features/calendar/utils/client_booking_context_scope.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/busy_conflict_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/delete_appointment_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/personal_block_clash_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/series_scope_dialog.dart';
import 'package:scheduling/features/calendar/widgets/fields/employee_picker.dart';
import 'package:scheduling/features/calendar/widgets/fields/repeat_interval_picker.dart';
import 'package:scheduling/features/calendar/widgets/sections/appointment_form_fields.dart';
import 'package:scheduling/features/calendar/widgets/sections/photo_picker_section.dart';
import 'package:scheduling/features/calendar/widgets/sheets/image_source_picker.dart';
import 'package:scheduling/features/calendar/widgets/sheets/inline_add_client_host.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';

class DetailsEditBody extends ConsumerStatefulWidget {
  const DetailsEditBody({
    required this.appointment,
    required this.controllers,
    required this.onSaved,
    required this.onClose,
    super.key,
  });

  final AppointmentRecord appointment;
  final AppointmentFormControllers controllers;
  final ValueChanged<AppointmentRecord> onSaved;
  final VoidCallback onClose;

  @override
  ConsumerState<DetailsEditBody> createState() => _DetailsEditBodyState();
}

class _DetailsEditBodyState extends ConsumerState<DetailsEditBody>
    with InlineAddClientHost {
  late final Debouncer _clientSearchDebounce;

  @override
  void initState() {
    super.initState();
    _clientSearchDebounce = Debouncer.tagged(
      kSearchDebounce,
      logger: ref.read(loggerProvider),
      tag: 'CLI-SEARCH debounced client search failed',
    );
  }

  @override
  void dispose() {
    _clientSearchDebounce.dispose();
    super.dispose();
  }

  // Debounce so comprehensive client search doesn't fire a Firestore read on every keystroke.
  void _onClientSearchChanged(String query) {
    final notifier = ref.read(
      eventDetailsControllerProvider(
        EventDetailsKey(widget.appointment),
      ).notifier,
    );
    if (query.trim().isEmpty) {
      _clientSearchDebounce.cancel();
      notifier.searchClients('');
      return;
    }
    _clientSearchDebounce.run(() => notifier.searchClients(query));
  }

  EventDetailsController get _notifier => ref.read(
    eventDetailsControllerProvider(
      EventDetailsKey(widget.appointment),
    ).notifier,
  );

  void _onRetryClientSearch() =>
      unawaited(_notifier.searchClients(widget.controllers.clientSearch.text));

  @override
  Widget build(BuildContext context) {
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(widget.appointment),
    );
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);

    return FormSheetFrame(
      title: context.l10n.calendar_editAppointment,
      primaryLabel: context.l10n.common_saveChanges,
      isBusy: state.isSaving,
      onPrimary: () => _save(context, ref),
      onCancel: widget.onClose,
      children: [
        _formFields(context, state, notifier),
        const SizedBox(height: AppSpacing.sp24),
        // Destructive actions live in the footer, never in the bar.
        _DeleteButton(
          isSaving: state.isSaving,
          onDelete: () => _confirmDelete(context, ref),
        ),
      ],
    );
  }

  Widget _formFields(
    BuildContext context,
    EventDetailsState state,
    EventDetailsController notifier,
  ) {
    final appointment = widget.appointment;
    // Crew, plus anyone already on the job who is active but no longer
    // offerable by title — see `offerableAssignees`, which owns the rule and
    // the reason a DISABLED assignee must stay unoffered.
    final roster = ref.watch(employeesStreamProvider);
    final allEmployees = offerableAssignees(
      active: roster.asData?.value ?? const [],
      alreadyAssignedIds: appointment.employeeIds,
    );
    // One length feeds both the flag and the label, so they can't disagree: the
    // run-length string is a plain interpolation, and a multi-day flag paired
    // with a length of 1 would render "1 days".
    final spanLength = runLengthDays(state.selectedDate, state.endDate);
    final bookingContext = watchClientBookingContext(
      ref,
      client: state.selectedClient,
    );

    return AppointmentFormFields(
      controllers: widget.controllers,
      allEmployees: allEmployees,
      rosterStatus: rosterStatusOf(roster),
      onRetryRoster: () => ref.invalidate(employeesStreamProvider),
      // Excluding this doc, or its own assignees read as clashing with
      // themselves.
      assigneeAvailability: watchAssigneeAvailability(
        ref,
        date: state.selectedDate,
        endDate: state.endDate,
        isAllDay: state.isAllDay,
        isPersonal: state.isPersonal,
        startTime: state.selectedStartTime,
        endTime: state.selectedEndTime,
        alreadyAssignedIds: appointment.employeeIds.toSet(),
        excludeAppointmentId: appointment.id,
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
      isAllDay: state.isAllDay,
      // Offered only on a job that was already personal, so an ordinary client
      // visit can't be converted mid-life (which would wipe its client).
      onPersonalChanged: appointment.isPersonal
          ? (value) => notifier.setPersonal(value: value)
          : null,
      errors: state.errors,
      employeeLabel: context.l10n.calendar_assignedEmployee,
      employeeRequired: false,
      materialsHint: context.l10n.calendar_eGPipeWrenchTapeCommaSeparated,
      editingStatus: state.editingStatus,
      onStatusChanged: notifier.setStatus,
      onRequestAddClient: requestAddClient,
      isMultiDay: spanLength > 1,
      // One day of a multi-day RUN: the end date goes away, because the run's
      // length is fixed at booking.
      isRunMember: appointment.isRunMember,
      // Editing may not widen a ONE-DAY client job into a multi-day one: only
      // the ADD path splits a span into per-day documents, so this would write
      // the wide document that closes every day at once.
      canSpanDays: appointment.isPersonal || spanLength > 1,
      isOvernight:
          !state.isAllDay &&
          isOvernightWindow(state.selectedStartTime, state.selectedEndTime),
      spanLength: spanLength,
      callbacks: _callbacks(context, state, notifier),
      photosSection: _EditPhotosSection(appointment: appointment),
    );
  }

  AppointmentFormCallbacks _callbacks(
    BuildContext context,
    EventDetailsState state,
    EventDetailsController notifier,
  ) => AppointmentFormCallbacks(
    onSearchClients: _onClientSearchChanged,
    onRetryClientSearch: _onRetryClientSearch,
    onSelectClient: notifier.selectClient,
    onClearClient: notifier.clearClient,
    onToggleEmployee: notifier.toggleEmployee,
    onSelectStartDate: (picked) => _onStartDateSelected(notifier, picked),
    onSelectEndDate: (picked) => _onEndDateSelected(notifier, picked),
    onPickStartTime: () => _pickStartTime(context, state, notifier),
    onPickEndTime: () => _pickEndTime(context, state, notifier),
    onSelectRepeat: notifier.selectRepeat,
    onUseCustomAddress: (value) => notifier.setUseCustomAddress(value: value),
    onDayOffChanged: (value) => notifier.setDayOff(value: value),
    onAllDayChanged: (value) => notifier.setAllDay(value: value),
  );

  /// The date rows drop an inline month calendar down beneath themselves, so a
  /// date arrives already picked — no modal to await, no cancelled outcome.
  void _onStartDateSelected(EventDetailsController notifier, DateTime picked) {
    // No setState around the controller writes: the body watches the controller
    // provider and `selectDate` always emits a new state, so the rebuild is
    // already coming.
    widget.controllers.date.text = DateUtilsHelper.formatDate(picked);
    notifier.selectDate(picked);
    // selectDate shifts the end date to preserve the run's length, and the end
    // row renders the controller text — so it has to follow, or it goes stale.
    final shifted = ref
        .read(
          eventDetailsControllerProvider(EventDetailsKey(widget.appointment)),
        )
        .endDate;
    widget.controllers.endDate.text = DateUtilsHelper.formatDate(shifted);
  }

  void _onEndDateSelected(EventDetailsController notifier, DateTime picked) {
    widget.controllers.endDate.text = DateUtilsHelper.formatDate(picked);
    notifier.selectEndDate(picked);
  }

  Future<void> _pickStartTime(
    BuildContext context,
    EventDetailsState state,
    EventDetailsController notifier,
  ) async {
    final picked = await showAdaptiveTimePicker(
      context,
      initialTime: state.selectedStartTime,
    );
    if (picked == null || !context.mounted) return;
    widget.controllers.startTime.text = picked.format(context);
    notifier.selectStartTime(picked);
  }

  Future<void> _pickEndTime(
    BuildContext context,
    EventDetailsState state,
    EventDetailsController notifier,
  ) async {
    final picked = await showAdaptiveTimePicker(
      context,
      initialTime: state.selectedEndTime,
    );
    if (picked == null || !context.mounted) return;
    widget.controllers.endTime.text = picked.format(context);
    notifier.selectEndTime(picked);
  }

  /// The occurrences a "this and all future" save would touch.
  Future<({int count, DateTime? last})> _seriesOutlook(
    WidgetRef ref,
    AppointmentRecord appointment,
  ) async {
    // Both reads happen before the await: this method promises to degrade to an
    // empty outlook rather than block the edit, and a `ref.read` in the catch
    // would defeat exactly that once the sheet has been dismissed mid-fetch
    // (Riverpod 3 throws on an unmounted consumer).
    final repository = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    try {
      final series = await repository.getSeries(appointment.seriesId);
      return seriesOutlook(
        series,
        anchor: appointment,
        excludeId: appointment.id ?? '',
      );
    } on Object catch (e, st) {
      logger.warn('APPT-SAVE series outlook failed', e, st);
      return (count: 0, last: null);
    }
  }

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final appointment = widget.appointment;
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(appointment),
    );
    final notifier = ref.read(provider.notifier);

    final state = ref.read(provider);
    if (state.isSaving) return; // a save (or its prompt) is already in flight

    final applyToSeries = await _resolveSeriesScope(context, ref, state);
    // null means the admin dismissed the scope dialog, or the sheet went away
    // while it was open — either way there is nothing to save.
    if (applyToSeries == null || !context.mounted) return;

    // An unnamed personal block saves as "Personal" — same rule as the add
    // flow, since the stored title is what every read surface falls back to.
    final title =
        widget.controllers.title.text.trim().isEmpty && state.isPersonal
        ? context.l10n.calendar_personal
        : widget.controllers.title.text;

    Future<EventDetailsSaveOutcome> attempt({bool forceBusy = false}) =>
        notifier.save(
          appointment,
          title: title,
          address: AddressParser.toCanonical(widget.controllers.address.text),
          notes: widget.controllers.notes.text,
          materialsNeeded: widget.controllers.materials.text,
          applyToSeries: applyToSeries,
          forceBusy: forceBusy,
        );

    final outcome = await retryPastBusyConflict(
      context,
      attempt: attempt,
      busyOf: (o) => o is EventDetailsBusyEmployees
          ? (busyEmployees: o.busyEmployees, start: o.start, end: o.end)
          : null,
    );
    // The helper already returned null if unmounted; repeated so the
    // analyzer can still see the guard across the await.
    if (outcome == null || !context.mounted) return;
    // Editing a day off's DATES re-runs the check on the days that were added —
    // extending Mon–Tue to Friday is the common case — because the span this
    // reads is the saved record's, not the one it had before.
    if (outcome case EventDetailsSaved(:final appointment)) {
      await showPersonalBlockClashesIfAny(context, ref, block: appointment);
      if (!context.mounted) return;
    }
    _announce(context, ref, outcome);
  }

  /// Asks whether an edit to a repeating visit applies to this visit only or to
  /// future ones too, and returns that as `applyToSeries`.
  Future<bool?> _resolveSeriesScope(
    BuildContext context,
    WidgetRef ref,
    EventDetailsState state,
  ) async {
    final appointment = widget.appointment;
    if (appointment.seriesId.isEmpty ||
        (state.repeat != state.savedRepeat && !appointment.isRunMember)) {
      return false;
    }
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(appointment),
    );
    // Busied for the whole dialog, so a second tap can't stack a duplicate.
    final notifier = ref.read(provider.notifier)..setSaving(busy: true);
    // One extra read per series edit — an admin action — so the dialog's
    // consequence line and button count are true rather than decorative.
    final outlook = await _seriesOutlook(ref, appointment);
    if (!context.mounted) {
      notifier.setSaving(busy: false);
      return null;
    }
    // A run member and a repeat occurrence take the same dialog with different
    // words: one is "the rest of this job", the other "the visits after this
    // one".
    final isRun = appointment.isRunMember;
    final choice = await showSeriesScopeDialog(
      context,
      title: context.l10n.calendar_applyChangesTo,
      contextLabel: isRun
          ? context.l10n.calendar_runDayLabel(
              appointment.dayIndex,
              appointment.dayCount,
            )
          : context.l10n.calendar_repeatsEveryLabel(
              repeatIntervalLabel(context.l10n, state.repeat).toUpperCase(),
            ),
      thisOnlyLabel: isRun
          ? context.l10n.calendar_editThisDayOnly
          : context.l10n.calendar_editThisVisitOnly,
      thisAndFutureLabel: isRun
          ? context.l10n.calendar_editThisAndFollowingDays
          : context.l10n.calendar_editThisAndFutureVisits,
      thisOnlyDetail: isRun
          ? context.l10n.calendar_thisDayKeepsRun(
              DateUtilsHelper.formatDate(appointment.startTime),
            )
          : context.l10n.calendar_thisVisitKeepsSeries(
              DateUtilsHelper.formatDate(appointment.startTime),
            ),
      thisAndFutureDetail: outlook.last == null
          ? null
          : (isRun
                ? context.l10n.calendar_remainingDaysThrough(
                    outlook.count,
                    DateUtilsHelper.formatDate(outlook.last!),
                  )
                : context.l10n.calendar_remainingVisitsThrough(
                    outlook.count,
                    DateUtilsHelper.formatDate(outlook.last!),
                  )),
      primaryLabelFor: (choice) => switch ((isRun, choice)) {
        (true, SeriesScopeChoice.thisOnly) => context.l10n.calendar_saveThisDay,
        (true, _) => context.l10n.calendar_saveNDays(outlook.count),
        (false, SeriesScopeChoice.thisOnly) =>
          context.l10n.calendar_saveThisVisit,
        (false, _) => context.l10n.calendar_saveNVisits(outlook.count),
      },
    );
    // Reset before the mounted guard — the notifier is context-free, and
    // bailing while still busy would wedge a surviving controller.
    notifier.setSaving(busy: false);
    if (!context.mounted || choice == null) return null;
    return choice == SeriesScopeChoice.thisAndFuture;
  }

  /// Turns a settled save outcome into the one notice it earns.
  void _announce(
    BuildContext context,
    WidgetRef ref,
    EventDetailsSaveOutcome outcome,
  ) {
    switch (outcome) {
      // Each surfaces nothing: the form already shows its own field errors, the
      // conflict prompt owns `BusyEmployees`, and `SaveBusy` is a skipped
      // duplicate save rather than a failure.
      case EventDetailsInvalid() ||
          EventDetailsBusyEmployees() ||
          EventDetailsSaveBusy():
        return;
      case EventDetailsSaved(
        :final appointment,
        :final futureBookings,
        :final removedBookings,
        :final updatedSiblings,
      ):
        final l10n = context.l10n;
        final message = futureBookings > 0
            ? l10n.calendar_changesSavedWithRepeats(futureBookings)
            : removedBookings > 0
            ? l10n.calendar_changesSavedWithRemoved(removedBookings)
            : updatedSiblings > 0
            ? l10n.calendar_changesAppliedToSeries(updatedSiblings)
            : l10n.common_appointmentChangesSaved;
        // `updatedSiblings`/`futureBookings` are what a series edit actually
        // wrote, so they — not the dialog's answer — say whether the scope was
        // a series.
        ref
            .read(analyticsServiceProvider)
            .logAppointmentEdited(
              scope: updatedSiblings > 0 || futureBookings > 0
                  ? AnalyticsScopes.series
                  : AnalyticsScopes.single,
              assigneeCount: appointment.employeeIds.length,
            );
        ref.read(noticeServiceProvider).success(message);
        widget.onSaved(appointment);
      case EventDetailsFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introSaveAppointment,
                error: error,
              ),
            );
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final appointment = widget.appointment;
    // Busied for the whole dialog, so a second tap can't stack a duplicate —
    // the same handoff [_resolveSeriesScope] does.
    final notifier = ref.read(
      eventDetailsControllerProvider(EventDetailsKey(appointment)).notifier,
    )..setSaving(busy: true);
    final choice = await showDeleteAppointmentDialog(
      context,
      isSeries: appointment.seriesId.isNotEmpty,
      isRun: appointment.isRunMember,
    );
    // Cleared before the mounted guard (the notifier is context-free, and
    // bailing while busy would wedge a surviving controller) and before the
    // call below, which now refuses while the flag is set.
    notifier.setSaving(busy: false);
    if (choice == null || !context.mounted) return;
    final outcome = await notifier.deleteAppointment(
      appointment,
      includeFuture: choice == SeriesScopeChoice.thisAndFuture,
    );
    if (!context.mounted) return;
    switch (outcome) {
      // A delete skipped by the reentrancy guard wrote nothing, so it must
      // announce nothing — neither the success notice nor an error.
      case EventDetailsActionBusy():
        return;
      case EventDetailsActionOk():
        ref
            .read(analyticsServiceProvider)
            .logAppointmentDeleted(
              scope: choice == SeriesScopeChoice.thisAndFuture
                  ? AnalyticsScopes.series
                  : AnalyticsScopes.single,
            );
        ref
            .read(noticeServiceProvider)
            .success(context.l10n.common_appointmentDeleted);
        widget.onClose();
      case EventDetailsActionFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introDeleteAppointment,
                error: error,
              ),
            );
    }
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.isSaving, required this.onDelete});

  final bool isSaving;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: destructiveOutlinedButtonStyle(
      context,
      minimumSize: const Size(double.infinity, 48),
    ),
    onPressed: isSaving ? null : onDelete,
    child: Text(context.l10n.calendar_deleteAppointment),
  );
}

class _EditPhotosSection extends ConsumerWidget {
  const _EditPhotosSection({required this.appointment});

  final AppointmentRecord appointment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(appointment),
    );
    final existingImages = ref.watch(provider.select((s) => s.existingImages));
    final newImages = ref.watch(provider.select((s) => s.newImages));
    final notifier = ref.read(provider.notifier);
    return PhotoPickerSection(
      existingImages: existingImages,
      newImages: newImages,
      isEditing: true,
      onPickImages: () => pickAndAddAppointmentImages(
        context,
        ref,
        addImages: notifier.addImages,
        remainingSlots: () => notifier.remainingImageSlots,
      ),
      onRemoveExisting: notifier.removeExistingImage,
      onRemoveNew: notifier.removeNewImage,
    );
  }
}
