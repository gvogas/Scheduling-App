import 'package:flutter/foundation.dart' show listEquals;

import 'package:scheduling/features/calendar/application/event_series_helpers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';

/// Result counts for a repeat-series rewrite.
typedef SeriesRewriteResult = ({
  AppointmentRecord updated,
  int futureBookings,
  int removedBookings,
});

typedef SeriesRewritePlan = ({
  AppointmentRecord base,
  List<AppointmentRecord> deleteBases,
  AppointmentRecord updated,
  List<String> deleteIds,
  List<AppointmentRecord> copies,
});

typedef SeriesPropagatePlan = ({
  List<AppointmentRecord> bases,
  AppointmentRecord updated,
  List<AppointmentRecord> propagated,
});

/// Plans and commits series rewrites or future-occurrence propagation.
class AppointmentSeriesEditor {
  const AppointmentSeriesEditor(this._repo);

  final AppointmentsRepository _repo;

  Future<SeriesRewritePlan> planRewrite({
    required AppointmentRecord updated,
    required AppointmentRecord appointment,
    required String id,
    required DateTime start,
    required DateTime end,
    required RepeatInterval repeat,
  }) async {
    final seriesId = appointment.seriesId.isEmpty ? id : appointment.seriesId;
    final withSeries = updated.copyWith(seriesId: seriesId);
    final existing = appointment.seriesId.isEmpty
        ? const <AppointmentRecord>[]
        : await _repo.getSeries(seriesId);
    final deleteIds = futureSeriesIds(
      existing.where((record) => !record.isClosed).toList(),
      excludeId: id,
      after: start,
    );
    final deleteBases = existing
        .where((record) => deleteIds.contains(record.id))
        .toList();
    final copies = [
      for (final copyStart in repeat.occurrenceStartsAfter(start))
        withSeries.copyWith(
          id: _repo.newDocId(),
          startTime: copyStart,
          endTime: occurrenceEnd(
            originalStart: start,
            originalEnd: end,
            copyStart: copyStart,
          ),
          status: 'pending',
          // New repeat copies start without photo subcollection documents.
        ),
    ];
    return (
      base: appointment,
      deleteBases: deleteBases,
      updated: withSeries,
      deleteIds: deleteIds,
      copies: copies,
    );
  }

  Future<SeriesRewriteResult> commitRewrite(
    SeriesRewritePlan plan, {
    bool checkConflicts = false,
  }) async {
    await _repo.rewriteSeries(
      updated: plan.updated,
      deleteIds: plan.deleteIds,
      copies: plan.copies,
      base: plan.base,
      deleteBases: plan.deleteBases,
      checkConflicts: checkConflicts,
    );
    return (
      updated: _repo.takeAcknowledgedWrite(plan.updated.id!) ?? plan.updated,
      futureBookings: plan.copies.length,
      removedBookings: plan.deleteIds.length,
    );
  }

  Future<SeriesPropagatePlan> planPropagate({
    required AppointmentRecord updated,
    required AppointmentRecord appointment,
    required String id,
    required DateTime start,
    required DateTime end,
  }) async {
    final series = await _repo.getSeries(appointment.seriesId);
    final siblings = futureSeriesRecords(
      series,
      excludeId: id,
      after: appointment.startTime,
      anchor: appointment,
    );
    final propagated = siblings.map((v) {
      final original = appointment.toMap();
      final desired = updated.toMap();
      bool changed(String field) {
        final before = original[field];
        final after = desired[field];
        return before is List && after is List
            ? !listEquals(before, after)
            : before != after;
      }

      final copyStart = withTimeOfDay(v.startTime, start);
      return v.copyWith(
        title: changed('title') ? updated.title : v.title,
        clientId: changed('clientId') ? updated.clientId : v.clientId,
        clientName: changed('clientName') ? updated.clientName : v.clientName,
        clientPhone: changed('clientPhone')
            ? updated.clientPhone
            : v.clientPhone,
        address: changed('address') ? updated.address : v.address,
        employeeIds: changed('employeeIds')
            ? updated.employeeIds
            : v.employeeIds,
        employeeNames: changed('employeeNames')
            ? updated.employeeNames
            : v.employeeNames,
        notes: changed('notes') ? updated.notes : v.notes,
        materialsNeeded: changed('materialsNeeded')
            ? updated.materialsNeeded
            : v.materialsNeeded,
        repeat: changed('repeat') ? updated.repeat : v.repeat,
        // Editable schedule flags travel with the propagated instants.
        isAllDay: changed('isAllDay') ? updated.isAllDay : v.isAllDay,
        isPersonal: changed('isPersonal') ? updated.isPersonal : v.isPersonal,
        isDayOff: changed('isDayOff') ? updated.isDayOff : v.isDayOff,
        startTime: changed('startTime') ? copyStart : v.startTime,
        endTime: changed('startTime')
            ? occurrenceEnd(
                originalStart: start,
                originalEnd: end,
                copyStart: copyStart,
              )
            // A sibling keeping its own start shifts its end by the anchor's.
            : changed('endTime')
            ? v.endTime.add(end.difference(appointment.endTime))
            : v.endTime,
        // Normalize each sibling's status so legacy values stay writable.
        status: AppointmentStatus.storedRaw(v.status),
      );
    }).toList();
    return (
      bases: [appointment, ...siblings],
      updated: updated,
      propagated: propagated,
    );
  }

  Future<int> commitPropagate(
    SeriesPropagatePlan plan, {
    bool checkConflicts = false,
  }) async {
    await _repo.updateAppointments(
      [plan.updated, ...plan.propagated],
      bases: plan.bases,
      checkConflicts: checkConflicts,
    );
    return plan.propagated.length;
  }
}
