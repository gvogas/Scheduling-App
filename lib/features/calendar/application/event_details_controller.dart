import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/images/images_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/calendar/application/appointment_conflict_checker.dart';
import 'package:scheduling/features/calendar/application/appointment_form_concerns.dart';
import 'package:scheduling/features/calendar/application/appointment_series_editor.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_outcome.dart';
import 'package:scheduling/features/calendar/application/event_details_save_pipeline.dart';
import 'package:scheduling/features/calendar/application/event_series_helpers.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/domain/policies/custom_address_policy.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';

// Re-export for single-source imports.
export 'package:scheduling/features/calendar/application/event_details_outcome.dart';

part 'event_details_controller.freezed.dart';

@freezed
abstract class EventDetailsState
    with _$EventDetailsState
    implements AppointmentFormFields {
  const factory EventDetailsState({
    required DateTime selectedDate,
    required DateTime endDate,
    required TimeOfDay selectedStartTime,
    required TimeOfDay selectedEndTime,
    required String editingStatus,
    @Default(false) bool isEditing,

    /// Existing appointments preserve run length when the start date moves.
    @Default(true) bool endDateTouched,
    @Default(RepeatInterval.none) RepeatInterval repeat,
    // Changing this value triggers repeat rebooking.
    @Default(RepeatInterval.none) RepeatInterval savedRepeat,
    @Default(<EmployeeRecord>[]) List<EmployeeRecord> selectedEmployees,
    @Default(<AppointmentImage>[]) List<AppointmentImage> existingImages,

    /// A subcollection re-read is in flight. Without it the photos section
    /// unmounted between a successful upload dropping the pending count and
    /// the re-read landing, so the crew watched their photo blink away.
    @Default(false) bool isLoadingPictures,
    @Default(<AppointmentImage>[]) List<AppointmentImage> removedExistingImages,
    @Default(<File>[]) List<File> newImages,
    @Default(false) bool isSaving,
    ClientRecord? client,
    ClientRecord? selectedClient,
    @Default(<ClientRecord>[]) List<ClientRecord> clientResults,
    @Default(false) bool isSearchingClient,
    @Default(ClientSearchStatus()) ClientSearchStatus clientSearchStatus,
    @Default(false) bool useCustomAddress,
    @Default(false) bool isPersonal,
    @Default(false) bool isDayOff,
    @Default(false) bool isAllDay,
    // Prevents fallback to the original client.
    @Default(false) bool clientCleared,
    @Default(<String, AppointmentFormError>{})
    Map<String, AppointmentFormError> errors,
  }) = _EventDetailsState;
}

class EventDetailsController extends Notifier<EventDetailsState>
    with AppointmentFormConcerns<EventDetailsState> {
  EventDetailsController(EventDetailsKey key) : appointment = key.appointment;

  final AppointmentRecord appointment;

  // Settles when employee enrichment completes, so save() runs on warm data.
  Future<void>? _seedFuture;

  /// Last photo list adopted by this controller.
  List<AppointmentImage> _lastKnownImages = const [];

  @override
  EventDetailsState build() {
    // Reset the photo baseline for this build.
    _lastKnownImages = const [];
    Future.microtask(() => _loadClientIfNeeded(appointment.clientId));
    Future.microtask(_loadStoredPictures);
    // A background photo upload appends its rows through this same singleton
    // repository, so its local-write poke is how this sheet learns the photo
    // landed. Without it the crew saw nothing until they closed and reopened.
    // Resolved here (before any await) rather than inside `onError`: `ref` is
    // not safe to touch once this notifier may be disposed.
    final logger = ref.read(loggerProvider);
    final writes = ref
        .read(appointmentsRepositoryProvider)
        .onLocalWrite
        .listen(
          // `showLoading` holds the section on screen across the gap between
          // the pending count dropping to 0 and the refreshed list arriving.
          // The BUILD-time read passes false: a job with no photos would
          // otherwise raise the PHOTOS header over an empty strip on every
          // open and collapse it a round trip later.
          (_) => unawaited(_loadStoredPictures(showLoading: true)),
          onError: (Object e, StackTrace st) =>
              logger.warn('APPT-IMG local write poke', e, st),
        );
    ref.onDispose(writes.cancel);
    _seedFuture = Future.microtask(_enrichSelectedEmployees);
    return EventDetailsState(
      selectedDate: appointment.startTime,
      endDate: lastWorkDayOf(appointment),
      selectedStartTime: TimeOfDay.fromDateTime(appointment.startTime),
      selectedEndTime: TimeOfDay.fromDateTime(appointment.endTime),
      // Normalize status before later writes.
      editingStatus: AppointmentStatus.storedRaw(appointment.status),
      repeat: appointment.repeat,
      savedRepeat: appointment.repeat,
      isPersonal: appointment.isPersonal,
      isDayOff: appointment.isDayOff,
      isAllDay: appointment.isAllDay,
      // Seed assignees before async enrichment.
      selectedEmployees: _assigneesFromRecord(appointment),
    );
  }

  /// Reads this job's photos from `appointments/{id}/images`.
  Future<void> _loadStoredPictures({bool showLoading = false}) async {
    if (!ref.mounted) return;
    final id = appointment.id;
    if (id == null || id.isEmpty) return;
    final repo = ref.read(appointmentsRepositoryProvider);
    // Read the logger before this notifier can be disposed.
    final logger = ref.read(loggerProvider);
    if (showLoading && ref.mounted) {
      state = state.copyWith(isLoadingPictures: true);
    }
    List<AppointmentImage> stored;
    try {
      stored = await repo.fetchAppointmentPictures(id);
    } catch (e, st) {
      logger.warn('APPT-IMG subcollection read failed', e, st);
      return;
    } finally {
      if (showLoading && ref.mounted) {
        state = state.copyWith(isLoadingPictures: false);
      }
    }
    if (stored.isEmpty || !ref.mounted) return;
    // Adopt only if the user has not edited the photo list.
    if (!listEquals(state.existingImages, _lastKnownImages)) return;
    state = state.copyWith(existingImages: _lastKnownImages = stored);
  }

  /// Builds assignee placeholders from stored ids and names.
  static List<EmployeeRecord> _assigneesFromRecord(AppointmentRecord a) => [
    for (var i = 0; i < a.employeeIds.length; i++)
      EmployeeRecord(
        id: a.employeeIds[i],
        name: assigneeNameAt(a.employeeNames, i) ?? '',
      ),
  ];

  /// Enriches placeholder assignees for display.
  Future<void> _enrichSelectedEmployees() async {
    if (!ref.mounted) return;
    if (state.selectedEmployees.isEmpty) return;
    final logger = ref.read(loggerProvider);
    try {
      final all = await _resolveActiveEmployees();
      if (!ref.mounted) return;
      final byId = {for (final e in all) e.id: e};
      state = state.copyWith(
        selectedEmployees: [
          for (final e in state.selectedEmployees) byId[e.id] ?? e,
        ],
      );
    } catch (e, st) {
      logger.warn('APPT-LOAD enrichSelectedEmployees failed', e, st);
    }
  }

  /// Resolves active staff for seeding and assignee saves.
  Future<List<EmployeeRecord>> _resolveActiveEmployees() =>
      ref.read(employeesRepositoryProvider).watchEmployees().first;

  Future<void> _loadClientIfNeeded(String clientId) async {
    if (!ref.mounted) return;
    final id = clientId.trim();
    if (id.isEmpty || state.client != null) return;
    // Resolved BEFORE the first await: `ref.read` on an unmounted consumer
    // throws under Riverpod 3, and the role gate below now awaits.
    final logger = ref.read(loggerProvider);
    final clientsRepo = ref.read(clientsRepositoryProvider);
    // Employees cannot read client documents.
    if (ref.exists(currentUserDocProvider)) {
      final docState = ref.read(currentUserDocProvider);
      if (docState.hasError) return;
      final Map<String, dynamic> doc;
      try {
        doc = docState.isLoading
            ? await ref.read(currentUserDocProvider.future)
            : (docState.value ?? const <String, dynamic>{});
      } on Object catch (e, st) {
        // `.future` genuinely rejects when the stream errors before its first
        // value — the `hasError` guard above only covers an ALREADY-settled
        // error, not one arriving during this await.
        logger.warn('APPT-OPEN user doc read failed', e, st);
        return;
      }
      if (!ref.mounted) return;
      final role = (doc['role'] ?? '').toString().trim();
      if (role != 'admin') return;
    }
    try {
      final client = await clientsRepo.getClientById(id);
      // Do not overwrite a client picked during the read.
      if (!ref.mounted) return;
      if (client == null || state.client != null) return;
      if (state.selectedClient == null && !state.clientCleared) {
        state = state.copyWith(
          client: client,
          selectedClient: client,
          useCustomAddress: usesCustomAddress(
            appointmentAddress: appointment.address,
            client: client,
          ),
        );
      } else {
        state = state.copyWith(client: client);
      }
    } catch (e, st) {
      logger.warn('APPT-LOAD loadClientIfNeeded failed', e, st);
    }
  }

  void enterEditing() =>
      state = state.copyWith(isEditing: true, errors: const {});

  void selectDate(DateTime date) {
    final length = calendarDaysBetween(state.selectedDate, state.endDate);
    state = state.copyWith(
      selectedDate: date,
      endDate: addCalendarDays(date, length < 0 ? 0 : length),
      errors: withoutKeys(state.errors, const ['date', 'endDate']),
    );
  }

  void selectEndDate(DateTime date) {
    state = state.copyWith(
      endDate: date,
      endDateTouched: true,
      errors: withoutKey(state.errors, 'endDate'),
    );
  }

  void selectStartTime(TimeOfDay time) {
    state = state.copyWith(
      selectedStartTime: time,
      errors: withoutKey(state.errors, 'startTime'),
    );
  }

  void selectEndTime(TimeOfDay time) {
    state = state.copyWith(
      selectedEndTime: time,
      errors: withoutKey(state.errors, 'endTime'),
    );
  }

  void setAllDay({required bool value}) {
    state = state.copyWith(
      isAllDay: value,
      errors: withoutKeys(state.errors, const ['startTime', 'endTime']),
    );
  }

  void setStatus(String status) {
    state = state.copyWith(editingStatus: status);
  }

  void selectRepeat(RepeatInterval value) {
    state = state.copyWith(repeat: value);
  }

  /// Marks a personal block as all-day time off.
  void setDayOff({required bool value}) {
    state = state.copyWith(
      isDayOff: value,
      isAllDay: value || state.isAllDay,
      errors: withoutKeys(state.errors, const ['startTime', 'endTime']),
    );
  }

  /// Toggles personal mode and clears hidden client-only fields.
  void setPersonal({required bool value}) {
    state = state.copyWith(
      isPersonal: value,
      // Client visits cannot keep a hidden day-off flag.
      isDayOff: value && state.isDayOff,
      selectedClient: value ? null : state.selectedClient,
      client: value ? null : state.client,
      clientCleared: value || state.clientCleared,
      clientResults: value ? const [] : state.clientResults,
      useCustomAddress: !value && state.useCustomAddress,
      // All-day stays user-controlled for every job type.
      errors: withoutKey(state.errors, 'client'),
    );
  }

  // --- AppointmentFormConcerns adapters ---

  @override
  EventDetailsState applyFormUpdate(
    EventDetailsState current,
    AppointmentFormUpdate update,
  ) {
    var next = current.copyWith(
      clientResults: update.clientResults ?? current.clientResults,
      isSearchingClient: update.isSearchingClient ?? current.isSearchingClient,
      clientSearchStatus:
          update.clientSearchStatus ?? current.clientSearchStatus,
      useCustomAddress: update.useCustomAddress ?? current.useCustomAddress,
      selectedEmployees: update.selectedEmployees ?? current.selectedEmployees,
      errors: update.errors ?? current.errors,
      newImages: update.pendingImages ?? current.newImages,
    );
    // Keep the loaded client and explicit-clear flag in sync.
    if (update.selectedClient != null) {
      next = next.copyWith(
        selectedClient: update.selectedClient,
        client: update.selectedClient,
        clientCleared: false,
      );
    } else if (update.clearSelectedClient) {
      next = next.copyWith(
        selectedClient: null,
        client: null,
        clientCleared: true,
      );
    }
    return next;
  }

  @override
  int get usedImageCount =>
      state.existingImages.length + state.newImages.length;

  @override
  List<File> get pendingImages => state.newImages;

  void removeNewImage(int index) => removePendingImageAt(index);

  void removeExistingImage(int index) {
    final removed = state.existingImages[index];
    final remaining = [...state.existingImages]..removeAt(index);
    state = state.copyWith(
      existingImages: remaining,
      removedExistingImages: [...state.removedExistingImages, removed],
    );
  }

  Future<EventDetailsActionOutcome> markAsDone(AppointmentRecord appointment) {
    return _setStatusOnRepo(appointment, 'done');
  }

  /// Moves an open job into `in_progress`.
  Future<EventDetailsActionOutcome> startJob(AppointmentRecord appointment) {
    return _setStatusOnRepo(appointment, 'in_progress');
  }

  /// Shifts the whole job later by [minutes], keeping its length.
  Future<EventDetailsSaveOutcome> delayAppointment(
    AppointmentRecord appointment, {
    required int minutes,
    bool forceBusy = false,
  }) async {
    final id = appointment.id;
    if (id == null) {
      return EventDetailsFailed(
        StateError('Cannot push back an appointment without an id.'),
      );
    }
    if (state.isSaving) return const EventDetailsSaveBusy();
    // Offline writes would wait forever for a server ack.
    if (ref.read(isOfflineProvider)) {
      return const EventDetailsFailed(SocketException('offline'));
    }
    state = state.copyWith(isSaving: true);
    // Read dependencies before any await.
    final repo = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    final selectedEmployees = state.selectedEmployees;
    final shift = Duration(minutes: minutes);
    final updated = appointment.copyWith(
      startTime: appointment.startTime.add(shift),
      endTime: appointment.endTime.add(shift),
      // A legacy status re-serialized verbatim is refused by the rules.
      status: AppointmentStatus.storedRaw(appointment.status),
    );
    try {
      if (!forceBusy && !appointment.isPersonal) {
        final conflict = await findFirstAppointmentConflict(
          repo: repo,
          candidates: selectedEmployees,
          bookings: [updated],
          excludeOwnBookingIds: true,
        );
        if (conflict != null) return _busyEmployees(conflict);
      }
      await repo.updateAppointment(updated);
      return EventDetailsSaved(updated);
    } catch (e, st) {
      logger.warn('APPT-SAVE delayAppointment failed', e, st);
      return EventDetailsFailed(e);
    } finally {
      if (ref.mounted) state = state.copyWith(isSaving: false);
    }
  }

  Future<EventDetailsActionOutcome> cancelAppointment(
    AppointmentRecord appointment, {
    bool includeFuture = false,
  }) async {
    final id = appointment.id;
    if (id == null) {
      return EventDetailsActionFailed(StateError('appointment has no id'));
    }
    if (!includeFuture || appointment.seriesId.isEmpty) {
      return await _setStatusOnRepo(appointment, 'cancelled');
    }
    if (state.isSaving) return const EventDetailsActionBusy();
    // Offline writes would wait forever for a server ack.
    if (ref.read(isOfflineProvider)) {
      return const EventDetailsActionFailed(SocketException('offline'));
    }
    state = state.copyWith(isSaving: true);
    // Read dependencies before any await.
    final repo = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    try {
      final series = await repo.getSeries(appointment.seriesId);
      final futureIds = futureSeriesIds(
        series,
        excludeId: id,
        after: appointment.startTime,
        anchor: appointment,
      );
      await repo.updateAppointmentStatuses(
        ids: [id, ...futureIds],
        status: 'cancelled',
      );
      return const EventDetailsActionOk();
    } catch (e, st) {
      logger.warn('APPT-STATUS cancel run tail failed', e, st);
      return EventDetailsActionFailed(e);
    } finally {
      // One owner for the flag: an early return added to the try body used to
      // leak it and disable this sheet's actions for good.
      if (ref.mounted) state = state.copyWith(isSaving: false);
    }
  }

  Future<EventDetailsActionOutcome> _setStatusOnRepo(
    AppointmentRecord appointment,
    String status,
  ) async {
    final id = appointment.id;
    if (id == null) {
      return EventDetailsActionFailed(StateError('appointment has no id'));
    }
    // Reject duplicate status writes.
    if (state.isSaving) return const EventDetailsActionBusy();
    // Offline writes would wait forever for a server ack, so Mark as complete
    // would spin until reconnect — the one action a technician out of signal is
    // most likely to press.
    if (ref.read(isOfflineProvider)) {
      return const EventDetailsActionFailed(SocketException('offline'));
    }
    state = state.copyWith(isSaving: true);
    final repo = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    try {
      await repo.updateAppointmentStatus(id: id, status: status);
      // Live activity cleanup is server-owned.
      return const EventDetailsActionOk();
    } catch (e, st) {
      logger.warn('APPT-STATUS updateAppointmentStatus($status) failed', e, st);
      return EventDetailsActionFailed(e);
    } finally {
      if (ref.mounted) state = state.copyWith(isSaving: false);
    }
  }

  void setSaving({required bool busy}) {
    if (!ref.mounted) return;
    state = state.copyWith(isSaving: busy);
  }

  EventDetailsSavePipeline _pipeline() => EventDetailsSavePipeline(
    repo: ref.read(appointmentsRepositoryProvider),
    resolveStorage: () => ref.mounted ? ref.read(imageStorageProvider) : null,
    logger: ref.read(loggerProvider),
  );

  /// Resolves final assignees against the active staff list.
  Future<({List<String> ids, List<String> names})> _resolveAssignees(
    AppointmentRecord appointment,
    EventDetailsSavePipeline pipeline,
    List<EmployeeRecord> selectedEmployees,
  ) async {
    final activeEmployees = await _resolveActiveEmployees();
    return pipeline.resolveAssignees(
      appointment: appointment,
      selected: selectedEmployees,
      activeEmployees: activeEmployees,
    );
  }

  Future<EventDetailsSaveOutcome> save(
    AppointmentRecord appointment, {
    required String title,
    required String address,
    required String notes,
    required String materialsNeeded,
    bool applyToSeries = false,
    bool forceBusy = false,
  }) async {
    // Duplicate saves are busy, not invalid.
    if (state.isSaving) return const EventDetailsSaveBusy();

    // Offline writes would wait forever for a server ack.
    if (ref.read(isOfflineProvider)) {
      return const EventDetailsFailed(SocketException('offline'));
    }
    state = state.copyWith(isSaving: true);

    final isAllDay = state.isAllDay;

    // Read dependencies before any await.
    final repo = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    final pipeline = _pipeline();
    // Avoid touching Storage when no new photos exist.
    final uploader = state.newImages.isEmpty
        ? null
        : ref.read(appointmentImageUploadProvider);

    // Guarded because `isSaving` is already true: the seed settle awaits a
    // `Future.microtask` that throws when the notifier is disposed under it,
    // and an un-caught throw here leaves Save disabled for the sheet's life.
    final EventDetailsSaveOutcome? invalid;
    try {
      invalid = await _settleAndValidate(
        appointment,
        title: title,
        isAllDay: isAllDay,
      );
    } on Object catch (e, st) {
      logger.warn('APPT-SAVE validation failed', e, st);
      if (ref.mounted) state = state.copyWith(isSaving: false);
      return EventDetailsFailed(e);
    }
    if (invalid != null) return invalid;

    final id = appointment.id;
    if (id == null) {
      state = state.copyWith(isSaving: false);
      return EventDetailsFailed(
        StateError('Cannot save an appointment without an id.'),
      );
    }

    final (:start, :end) = appointmentSpan(
      date: state.selectedDate,
      endDate: state.endDate,
      isAllDay: isAllDay,
      startTime: state.selectedStartTime,
      endTime: state.selectedEndTime,
    );

    // Snapshot form state before async writes.
    final removedImages = state.removedExistingImages;
    final newImages = state.newImages;
    final selectedEmployees = state.selectedEmployees;
    final selectedClient = state.selectedClient;
    final editingStatus = state.editingStatus;
    final repeat = state.repeat;
    final savedRepeat = state.savedRepeat;
    final isPersonal = state.isPersonal;
    final isDayOff = state.isDayOff;

    try {
      final assignees = await _resolveAssignees(
        appointment,
        pipeline,
        selectedEmployees,
      );
      final updated = pipeline.buildUpdatedRecord(
        appointment,
        id: id,
        title: title,
        address: address,
        notes: notes,
        materialsNeeded: materialsNeeded,
        start: start,
        end: end,
        assignees: assignees,
        selectedClient: selectedClient,
        status: editingStatus,
        repeat: repeat,
        isPersonal: isPersonal,
        isDayOff: isDayOff,
        isAllDay: isAllDay,
      );

      final saved = await _applySeriesChange(
        appointment,
        repo: repo,
        updated: updated,
        id: id,
        start: start,
        end: end,
        applyToSeries: applyToSeries,
        repeat: repeat,
        savedRepeat: savedRepeat,
        selectedEmployees: selectedEmployees,
        checkConflicts: !forceBusy && !isPersonal,
      );
      if (saved is! EventDetailsSaved) {
        if (ref.mounted) state = state.copyWith(isSaving: false);
        return saved;
      }

      await pipeline.applyPhotoChanges(
        id: id,
        uploader: uploader,
        removedImages: removedImages,
        newImages: newImages,
        // Move the repeat baseline after the record write.
        onRecordWritten: () {
          if (ref.mounted) state = state.copyWith(savedRepeat: repeat);
        },
      );

      if (ref.mounted) state = state.copyWith(isSaving: false);
      return saved;
    } catch (e, st) {
      logger.warn('APPT-SAVE saveChanges failed', e, st);
      if (ref.mounted) state = state.copyWith(isSaving: false);
      return EventDetailsFailed(e);
    }
  }

  Future<EventDetailsSaveOutcome> _applySeriesChange(
    AppointmentRecord appointment, {
    required AppointmentsRepository repo,
    required AppointmentRecord updated,
    required String id,
    required DateTime start,
    required DateTime end,
    required bool applyToSeries,
    required RepeatInterval repeat,
    required RepeatInterval savedRepeat,
    required List<EmployeeRecord> selectedEmployees,
    required bool checkConflicts,
  }) async {
    final seriesEditor = AppointmentSeriesEditor(repo);
    // A run member never rewrites its series.
    if (repeat != savedRepeat && !appointment.isRunMember) {
      final plan = await seriesEditor.planRewrite(
        updated: updated,
        appointment: appointment,
        id: id,
        start: start,
        end: end,
        repeat: repeat,
      );
      if (checkConflicts) {
        final conflict = await findFirstAppointmentConflict(
          repo: repo,
          candidates: selectedEmployees,
          bookings: [plan.updated, ...plan.copies],
          excludeAppointmentIds: plan.deleteIds.toSet(),
          excludeOwnBookingIds: true,
        );
        if (conflict != null) return _busyEmployees(conflict);
      }
      final result = await seriesEditor.commitRewrite(plan);
      return EventDetailsSaved(
        result.updated,
        futureBookings: result.futureBookings,
        removedBookings: result.removedBookings,
      );
    }

    if (applyToSeries && appointment.seriesId.isNotEmpty) {
      final plan = await seriesEditor.planPropagate(
        updated: updated,
        appointment: appointment,
        id: id,
        start: start,
        end: end,
      );
      if (checkConflicts) {
        final conflict = await findFirstAppointmentConflict(
          repo: repo,
          candidates: selectedEmployees,
          bookings: [plan.updated, ...plan.propagated],
          excludeOwnBookingIds: true,
        );
        if (conflict != null) return _busyEmployees(conflict);
      }
      final updatedSiblings = await seriesEditor.commitPropagate(plan);
      return EventDetailsSaved(updated, updatedSiblings: updatedSiblings);
    }

    if (checkConflicts) {
      final conflict = await findFirstAppointmentConflict(
        repo: repo,
        candidates: selectedEmployees,
        bookings: [updated],
        excludeOwnBookingIds: true,
      );
      if (conflict != null) return _busyEmployees(conflict);
    }

    await repo.updateAppointment(updated);
    return EventDetailsSaved(updated);
  }

  EventDetailsBusyEmployees _busyEmployees(AppointmentConflictHit conflict) =>
      EventDetailsBusyEmployees(
        busyEmployees: conflict.busyEmployees,
        start: conflict.start,
        end: conflict.end,
      );

  /// Waits for seeding, validates the saved snapshot, and returns a stop
  /// outcome on errors.
  Future<EventDetailsSaveOutcome?> _settleAndValidate(
    AppointmentRecord appointment, {
    required String title,
    required bool isAllDay,
  }) async {
    await _seedFuture;
    if (!ref.mounted) return const EventDetailsInvalid();

    final clientForValidation = state.isPersonal
        ? null
        : state.selectedClient ??
              (!state.clientCleared && appointment.clientId.trim().isNotEmpty
                  ? state.client ?? placeholderClient(appointment)
                  : null);

    final errors = AppointmentFormValidator.validate(
      AppointmentFormInput(
        title: title,
        date: state.selectedDate,
        endDate: state.endDate,
        startTime: state.selectedStartTime,
        endTime: state.selectedEndTime,
        client: clientForValidation,
        selectedEmployees: state.selectedEmployees,
        isPersonal: state.isPersonal,
        isAllDay: isAllDay,
      ),
    );
    state = state.copyWith(errors: errors);
    if (errors.isNotEmpty) {
      state = state.copyWith(isSaving: false);
      return const EventDetailsInvalid();
    }
    return null;
  }

  /// Deletes this appointment, optionally including future series visits.
  Future<EventDetailsActionOutcome> deleteAppointment(
    AppointmentRecord appointment, {
    bool includeFuture = false,
  }) async {
    final id = appointment.id;
    if (id == null) {
      return EventDetailsActionFailed(
        StateError('Cannot delete an appointment without an id.'),
      );
    }
    // Reuse the save/status busy guard for delete taps.
    if (state.isSaving) return const EventDetailsActionBusy();
    // Offline writes would wait forever for a server ack.
    if (ref.read(isOfflineProvider)) {
      return const EventDetailsActionFailed(SocketException('offline'));
    }
    state = state.copyWith(isSaving: true);
    // Resolve these before the first await, so they survive the sheet being dismissed.
    final repo = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    try {
      // Server cascade deletes appointment photo documents and bytes.
      if (includeFuture && appointment.seriesId.isNotEmpty) {
        final series = await repo.getSeries(appointment.seriesId);
        final futureIds = futureSeriesIds(
          series,
          excludeId: id,
          after: appointment.startTime,
          anchor: appointment,
        );
        await repo.deleteAppointments([id, ...futureIds]);
      } else {
        await repo.deleteAppointment(id);
      }

      return const EventDetailsActionOk();
    } catch (e, st) {
      logger.warn('APPT-DEL deleteAppointment failed', e, st);
      return EventDetailsActionFailed(e);
    } finally {
      if (ref.mounted) state = state.copyWith(isSaving: false);
    }
  }
}

final eventDetailsControllerProvider = NotifierProvider.autoDispose
    .family<EventDetailsController, EventDetailsState, EventDetailsKey>(
      EventDetailsController.new,
    );
