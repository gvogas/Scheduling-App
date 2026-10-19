import 'dart:io';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/application/appointment_conflict_checker.dart';
import 'package:scheduling/features/calendar/application/appointment_form_concerns.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/utils/appointment_draft_defaults.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

part 'add_event_controller.freezed.dart';

@freezed
abstract class AddEventState
    with _$AddEventState
    implements AppointmentFormFields {
  const factory AddEventState({
    DateTime? selectedDate,
    DateTime? endDate,

    /// Whether the end date should move with later start-date changes.
    @Default(false) bool endDateTouched,
    TimeOfDay? selectedStartTime,
    TimeOfDay? selectedEndTime,
    @Default(false) bool endTimeWasPickedManually,

    /// Seeded job length; the end follows the start by this many minutes.
    int? durationMinutes,
    ClientRecord? selectedClient,
    @Default(<ClientRecord>[]) List<ClientRecord> clientResults,
    @Default(false) bool isSearchingClient,
    @Default(ClientSearchStatus()) ClientSearchStatus clientSearchStatus,
    @Default(false) bool useCustomAddress,
    @Default(false) bool isPersonal,
    @Default(false) bool isDayOff,
    @Default(false) bool isAllDay,
    @Default(<EmployeeRecord>[]) List<EmployeeRecord> selectedEmployees,
    @Default(RepeatInterval.none) RepeatInterval repeat,
    @Default(<File>[]) List<File> selectedImages,
    @Default(false) bool isSubmitting,
    @Default(<String, AppointmentFormError>{})
    Map<String, AppointmentFormError> errors,
  }) = _AddEventState;
}

sealed class AddEventSubmitOutcome {
  const AddEventSubmitOutcome();
}

class AddEventInvalid extends AddEventSubmitOutcome {
  const AddEventInvalid();
}

/// A submit skipped by the reentrancy guard.
class AddEventBusy extends AddEventSubmitOutcome {
  const AddEventBusy();
}

class AddEventBusyEmployees extends AddEventSubmitOutcome {
  const AddEventBusyEmployees({
    required this.busyEmployees,
    required this.start,
    required this.end,
  });
  final List<EmployeeRecord> busyEmployees;
  final DateTime start;
  final DateTime end;
}

class AddEventSubmitted extends AddEventSubmitOutcome {
  const AddEventSubmitted(
    this.appointment, {
    this.futureBookings = 0,
    this.runDays = 1,
  });
  final AppointmentRecord appointment;

  /// Pre-booked REPEAT occurrences created alongside [appointment].
  final int futureBookings;

  /// How many days the booked run covers; 1 for an ordinary single-day job.
  final int runDays;
}

class AddEventFailed extends AddEventSubmitOutcome {
  const AddEventFailed(this.error);
  final Object error;
}

class AddEventController extends Notifier<AddEventState>
    with AppointmentFormConcerns<AddEventState> {
  AddEventController(this.initialDate);

  final DateTime? initialDate;

  @override
  AddEventState build() {
    return AddEventState(selectedDate: initialDate, endDate: initialDate);
  }

  @override
  AddEventState applyFormUpdate(
    AddEventState current,
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
      selectedImages: update.pendingImages ?? current.selectedImages,
    );
    if (update.selectedClient != null) {
      next = next.copyWith(selectedClient: update.selectedClient);
    } else if (update.clearSelectedClient) {
      next = next.copyWith(selectedClient: null);
    }
    return next;
  }

  @override
  int get usedImageCount => state.selectedImages.length;

  @override
  List<File> get pendingImages => state.selectedImages;

  void removeImage(int index) => removePendingImageAt(index);

  void selectDate(DateTime date) {
    final endDate = _shiftedEndDate(date);
    state = state.copyWith(
      selectedDate: date,
      endDate: endDate,
      repeat: _repeatForSpan(date, endDate),
      errors: withoutKeys(state.errors, const ['date', 'endDate']),
    );
  }

  /// A multi-day draft cannot carry a hidden repeat rule.
  RepeatInterval _repeatForSpan(DateTime? start, DateTime? end) =>
      runLengthDays(start, end) > 1 ? RepeatInterval.none : state.repeat;

  /// Returns the end date after moving the start to [date].
  DateTime _shiftedEndDate(DateTime date) {
    final previousStart = state.selectedDate;
    final previousEnd = state.endDate;
    if (!state.endDateTouched || previousStart == null || previousEnd == null) {
      return date;
    }
    final length = calendarDaysBetween(previousStart, previousEnd);
    return addCalendarDays(date, length < 0 ? 0 : length);
  }

  void selectEndDate(DateTime date) {
    state = state.copyWith(
      endDate: date,
      endDateTouched: true,
      repeat: _repeatForSpan(state.selectedDate, date),
      errors: withoutKey(state.errors, 'endDate'),
    );
  }

  void selectStartTime(TimeOfDay time) {
    final auto = !state.endTimeWasPickedManually;
    var errors = withoutKey(state.errors, 'startTime');
    if (auto) errors = withoutKey(errors, 'endTime');
    state = state.copyWith(
      selectedStartTime: time,
      selectedEndTime: auto ? _seededEndTime(time) : state.selectedEndTime,
      errors: errors,
    );
  }

  TimeOfDay _seededEndTime(TimeOfDay start) {
    final duration = state.durationMinutes;
    return duration == null
        ? AppointmentDraftDefaults.defaultEndTime(start)
        : AppointmentDraftDefaults.endTimeFor(start, duration);
  }

  /// Seeds the job length: the end lands [minutes] after the start, clamped
  /// inside the day — now if a start is picked, else when one is.
  void setDurationMinutes(int minutes) {
    final start = state.selectedStartTime;
    if (start == null) {
      state = state.copyWith(durationMinutes: minutes);
      return;
    }
    // Seeding over a picked start re-owns the end, so it follows the start from
    // here on even if it had been picked by hand before.
    state = state.copyWith(
      durationMinutes: minutes,
      selectedEndTime: AppointmentDraftDefaults.endTimeFor(start, minutes),
      endTimeWasPickedManually: false,
      errors: withoutKey(state.errors, 'endTime'),
    );
  }

  /// Seeds a draft from [prefill]: the client, whether the source used its own
  /// address, the job length, and whichever of its crew is still assignable —
  /// resolved against the roster STREAM's first value, so a cold provider
  /// cannot make a carried assignee silently vanish.
  Future<void> applyPrefill(AppointmentPrefill prefill) async {
    final client = prefill.client;
    if (client != null) selectClient(client);
    // selectClient already forces custom for a client with no address; the
    // source's own choice can only add to that, never undo it.
    if (prefill.useCustomAddress) setUseCustomAddress(value: true);
    final duration = prefill.durationMinutes;
    if (duration != null) setDurationMinutes(duration);
    if (prefill.employeeIds.isEmpty) return;
    // Read before the await: `ref` may be unmounted by the time it resolves.
    final logger = ref.read(loggerProvider);
    // The roster stream is autoDispose, so this HOLDS it for the length of the
    // read rather than trusting whatever else happens to be watching it.
    final subscription = ref.listen(employeesStreamProvider, (_, _) {});
    try {
      final roster = await ref.read(employeesStreamProvider.future);
      if (!ref.mounted) return;
      state = state.copyWith(
        selectedEmployees: [
          for (final e in roster)
            if (e.isAssignable && prefill.employeeIds.contains(e.id)) e,
        ],
      );
    } catch (e, st) {
      logger.warn('APPT-CREATE prefill roster read failed', e, st);
    } finally {
      subscription.close();
    }
  }

  void selectEndTime(TimeOfDay time) {
    state = state.copyWith(
      selectedEndTime: time,
      endTimeWasPickedManually: true,
      errors: withoutKey(state.errors, 'endTime'),
    );
  }

  void selectRepeat(RepeatInterval value) {
    state = state.copyWith(repeat: value);
  }

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
      clientResults: value ? const [] : state.clientResults,
      useCustomAddress: !value && state.useCustomAddress,
      // Personal drafts cannot carry a hidden repeat rule.
      repeat: value ? RepeatInterval.none : state.repeat,
      // Untimed personal drafts default to all-day.
      isAllDay: value
          ? state.selectedStartTime == null && state.selectedEndTime == null
          : state.isAllDay,
      errors: withoutKeys(state.errors, const [
        'client',
        'startTime',
        'endTime',
      ]),
    );
  }

  void setAllDay({required bool value}) {
    state = state.copyWith(
      isAllDay: value,
      errors: withoutKeys(state.errors, const ['startTime', 'endTime']),
    );
  }

  Future<AddEventSubmitOutcome> submit({
    required String title,
    required String address,
    required String notes,
    required String materialsNeeded,
    bool forceBusy = false,
  }) async {
    // Double-taps are busy, not invalid form submissions.
    if (state.isSubmitting) return const AddEventBusy();
    final errors = AppointmentFormValidator.validate(
      AppointmentFormInput(
        title: title,
        date: state.selectedDate,
        endDate: state.endDate ?? state.selectedDate,
        startTime: state.selectedStartTime,
        endTime: state.selectedEndTime,
        client: state.selectedClient,
        selectedEmployees: state.selectedEmployees,
        isPersonal: state.isPersonal,
        isAllDay: state.isAllDay,
      ),
    );
    state = state.copyWith(errors: errors);
    if (errors.isNotEmpty) return const AddEventInvalid();

    // Offline writes would wait forever for a server ack.
    if (ref.read(isOfflineProvider)) {
      return const AddEventFailed(SocketException('offline'));
    }

    final repo = ref.read(appointmentsRepositoryProvider);
    final ownsWrite = repo.captureWriteOwner();
    // Read dependencies before any await.
    final logger = ref.read(loggerProvider);
    final uploader = ref.read(appointmentImageUploadProvider);
    // Snapshot form state before async work starts.
    final images = state.selectedImages;
    final client = state.selectedClient;
    final isPersonal = state.isPersonal;
    final isDayOff = state.isDayOff;
    final isAllDay = state.isAllDay;
    final selectedEmployees = state.selectedEmployees;
    final repeat = state.repeat;

    final (:start, :end) = appointmentSpan(
      date: state.selectedDate!,
      endDate: state.endDate ?? state.selectedDate!,
      isAllDay: isAllDay,
      startTime: state.selectedStartTime,
      endTime: state.selectedEndTime,
    );

    // Disable Save before the conflict check starts.
    state = state.copyWith(isSubmitting: true);

    try {
      final docId = repo.newDocId();
      final appointment = AppointmentRecord(
        id: docId,
        title: title.trim(),
        startTime: start,
        endTime: end,
        clientId: client?.id ?? '',
        clientName: client?.displayName ?? '',
        clientPhone: client?.phone ?? '',
        // Day off hides the address field, so it saves blank.
        address: isDayOff ? '' : address.trim(),
        isPersonal: isPersonal,
        isDayOff: isDayOff,
        isAllDay: isAllDay,
        employeeIds: selectedEmployees.map((e) => e.id).toList(),
        employeeNames: selectedEmployees.map((e) => e.name).toList(),
        notes: notes.trim(),
        materialsNeeded: materialsNeeded.trim(),
        repeat: repeat,
        seriesId: repeat == RepeatInterval.none ? '' : docId,
      );

      // Multi-day client jobs split into daily documents; personal blocks stay wide.
      final runWindows = isPersonal
          ? [(start: start, end: end)]
          : expandRunWindows(start, end);
      final dayCount = runWindows.length;

      final days = [
        for (var i = 0; i < dayCount; i++)
          appointment.copyWith(
            id: i == 0 ? docId : repo.newDocId(),
            startTime: runWindows[i].start,
            endTime: runWindows[i].end,
            // Real runs use day one as their series id.
            seriesId: dayCount > 1 ? docId : appointment.seriesId,
            dayIndex: dayCount > 1 ? i + 1 : 0,
            dayCount: dayCount > 1 ? dayCount : 0,
          ),
      ];

      // Only single-day client jobs can repeat.
      final repeatCopies = dayCount > 1
          ? const <AppointmentRecord>[]
          : [
              for (final copyStart in repeat.occurrenceStartsAfter(start))
                days.first.copyWith(
                  id: repo.newDocId(),
                  startTime: copyStart,
                  endTime: occurrenceEnd(
                    originalStart: start,
                    originalEnd: end,
                    copyStart: copyStart,
                  ),
                ),
            ];

      final toWrite = [...days, ...repeatCopies];
      // Personal clashes are handled by the time-off alert after write.
      if (!forceBusy && !isPersonal) {
        final conflict = await findFirstAppointmentConflict(
          repo: repo,
          candidates: selectedEmployees,
          bookings: toWrite,
        );
        if (ownsWrite?.call() == false) return const AddEventBusy();
        if (conflict != null) {
          // Conflicts return to the sheet for a force-through choice.
          if (ref.mounted) state = state.copyWith(isSubmitting: false);
          return AddEventBusyEmployees(
            busyEmployees: conflict.busyEmployees,
            start: conflict.start,
            end: conflict.end,
          );
        }
      }

      if (ownsWrite?.call() == false) return const AddEventBusy();
      if (toWrite.length == 1) {
        await repo.addAppointment(toWrite.single);
      } else {
        await repo.addAppointments(toWrite);
      }

      // Draft photos attach to day one.
      if (ownsWrite?.call() == false) return const AddEventBusy();
      if (images.isNotEmpty) {
        await uploader.enqueuePhotos(appointmentId: docId, newImages: images);
      }

      return AddEventSubmitted(
        days.first,
        futureBookings: repeatCopies.length,
        runDays: dayCount,
      );
    } catch (e, st) {
      logger.warn('APPT-CREATE submit failed', e, st);
      if (ref.mounted) state = state.copyWith(isSubmitting: false);
      return AddEventFailed(e);
    }
  }
}

final addEventControllerProvider = NotifierProvider.autoDispose
    .family<AddEventController, AddEventState, DateTime?>(
      AddEventController.new,
    );
