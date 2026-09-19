import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

abstract class AppointmentsRepository {
  /// Drops every cached appointment this repository is holding.
  void clearCaches();

  String newDocId();

  Future<AppointmentRecord?> getAppointmentById(String id);

  /// How many not-yet-started jobs this employee is still assigned to.
  Future<int> countFutureAssignments(String employeeId);

  Future<void> addAppointment(AppointmentRecord appointment);

  /// Creates every appointment in [appointments] atomically (all-or-nothing).
  Future<void> addAppointments(List<AppointmentRecord> appointments);

  /// All appointments belonging to one repeat series.
  Future<List<AppointmentRecord>> getSeries(String seriesId);

  /// Atomically rewrites a series — saves, deletes, and creates all happen in
  /// one batch.
  Future<void> rewriteSeries({
    required AppointmentRecord updated,
    required List<String> deleteIds,
    required List<AppointmentRecord> copies,
  });

  Future<void> updateAppointment(AppointmentRecord appointment);

  /// Atomically update series to propagate edit across visit and future siblings.
  Future<void> updateAppointments(List<AppointmentRecord> appointments);

  /// Adds [pictures] to `appointments/{id}/images`.
  Future<void> appendAppointmentPictures(
    String id,
    List<AppointmentImage> pictures,
  );

  /// Deletes [pictures] from `appointments/{id}/images`, by the same derived
  /// ids, leaving photos this caller never saw untouched.
  Future<void> removeAppointmentPictures(
    String id,
    List<AppointmentImage> pictures,
  );

  /// This appointment's photos.
  Future<List<AppointmentImage>> fetchAppointmentPictures(String id);

  /// Writes what the CREW recorded on site.
  Future<void> updateFieldNotes({required String id, required String notes});

  /// Appends one crew note to `appointments/{id}/fieldNotes`.
  ///
  /// [authorId] must be the caller's own users-doc id — `firestore.rules`
  /// refuses anything else. [authorName] is NOT pinned by the rules, so the
  /// reader resolves the display name from [authorId] rather than trusting it.
  Future<void> appendFieldNote({
    required String appointmentId,
    required String text,
    required String authorId,
    required String authorName,
  });

  /// This job's crew notes, oldest first, and whether older ones were dropped.
  Future<FieldNoteThread> fetchFieldNotes(String appointmentId);

  Future<void> updateAppointmentStatus({
    required String id,
    required String status,
  });

  Future<void> restoreAppointmentStatus({
    required String id,
    required String previousStatus,
  });

  /// Writes one status across several appointments in a single batch.
  Future<void> updateAppointmentStatuses({
    required List<String> ids,
    required String status,
  });

  Future<void> deleteAppointment(String id);

  /// Deletes every appointment in [ids] atomically (all-or-nothing).
  Future<void> deleteAppointments(List<String> ids);

  Stream<List<AppointmentRecord>> watchInRange(AppointmentDateRange range);

  /// The jobs overdue at [now] (`overdueJobsAt`), oldest first and capped.
  /// Admin-only: the query is not narrowed by `employeeIds`.
  Stream<List<AppointmentRecord>> watchOverdueOpen(DateTime now);

  /// The same query as [watchInRange], read ONCE.
  Future<List<AppointmentRecord>> fetchInRange(AppointmentDateRange range);

  /// One newest-first page of terminal appointments.
  Future<List<AppointmentRecord>> fetchHistoryPage({
    required int limit,
    AppointmentRecord? after,
    String? employeeId,
  });

  /// Search terminal appointments by client/employee name or phone,
  /// newest-first.
  Future<List<AppointmentRecord>> searchHistory(
    String query, {
    String? employeeId,
  });

  /// This client's appointments in any status, newest-first.
  ///
  /// [limit] is the PAGE size; [cap] is how far the scan will page in total.
  /// A caller that only needs a recent slice passes both, so it doesn't buy
  /// the whole archive to render two lines.
  Future<List<AppointmentRecord>> fetchClientHistory({
    required String clientId,
    int limit,
    int? cap,
  });

  /// Fires after local writes so search providers invalidate stale results immediately.
  Stream<void> get onLocalWrite;

  Stream<List<AppointmentRecord>> watchForEmployeeInRange(
    String employeeId,
    AppointmentDateRange range,
  );

  /// [excludeAppointmentId] drops one doc from the overlap scan — an edit must
  /// not collide with the very appointment being edited.
  Future<List<EmployeeRecord>> findBusyEmployees({
    required List<EmployeeRecord> candidates,
    required DateTime start,
    required DateTime end,
    String? excludeAppointmentId,
  });

  /// The live appointments standing in the way of [employeeIds] over
  /// [start]–[end], read ONCE.
  Future<List<AppointmentRecord>> findClashingAppointments({
    required List<String> employeeIds,
    required DateTime start,
    required DateTime end,
    String? excludeAppointmentId,
    bool clientJobsOnly,
  });
}
