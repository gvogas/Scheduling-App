import 'dart:io';

import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Builds appointment save records and applies photo changes.
class EventDetailsSavePipeline {
  const EventDetailsSavePipeline({
    required this.repo,
    required this.resolveStorage,
    required this.logger,
  });

  final AppointmentsRepository repo;

  /// Resolves Storage only when bytes must be deleted.
  final ImageStorageService? Function() resolveStorage;

  final AppLogger logger;

  /// Merges selected employees with original hidden assignees.
  ({List<String> ids, List<String> names}) resolveAssignees({
    required AppointmentRecord appointment,
    required List<EmployeeRecord> selected,
    required List<EmployeeRecord> activeEmployees,
  }) {
    return mergeRetainedAssignees(
      originalIds: appointment.employeeIds,
      originalNames: appointment.employeeNames,
      selectedIds: selected.map((e) => e.id).toList(),
      selectedNames: selected.map((e) => e.name).toList(),
      activeIds: activeEmployees.map((e) => e.id).toSet(),
    );
  }

  /// The edited record, from the form fields and the resolved assignees.
  AppointmentRecord buildUpdatedRecord(
    AppointmentRecord appointment, {
    required String id,
    required String title,
    required String address,
    required String notes,
    required String materialsNeeded,
    required DateTime start,
    required DateTime end,
    required ({List<String> ids, List<String> names}) assignees,
    required ClientRecord? selectedClient,
    required String status,
    required RepeatInterval repeat,
    required bool isPersonal,
    required bool isDayOff,
    required bool isAllDay,
  }) {
    // Personal jobs clear client fields while keeping the visible address.
    final pickedClient = isPersonal ? null : selectedClient;
    return AppointmentRecord(
      id: id,
      title: title.trim(),
      startTime: start,
      endTime: end,
      clientId: isPersonal ? '' : pickedClient?.id ?? appointment.clientId,
      clientName: isPersonal
          ? ''
          : pickedClient?.displayName ?? appointment.clientName,
      clientPhone: isPersonal
          ? ''
          : pickedClient?.phone ?? appointment.clientPhone,
      // Day-off jobs clear the hidden address field.
      address: isDayOff ? '' : address.trim(),
      isPersonal: isPersonal,
      isDayOff: isDayOff,
      isAllDay: isAllDay,
      employeeIds: assignees.ids,
      employeeNames: assignees.names,
      notes: notes.trim(),
      materialsNeeded: materialsNeeded.trim(),
      status: status,
      repeat: repeat,
      seriesId: appointment.seriesId,
      // Carried like `seriesId`: the edit form can't change the run label, and dropping it loses "Day 3 of 5".
      dayIndex: appointment.dayIndex,
      dayCount: appointment.dayCount,
    );
  }

  /// Applies photo changes after the record write.
  Future<void> applyPhotoChanges({
    required String id,
    required AppointmentImageUploadService? uploader,
    required List<AppointmentImage> removedImages,
    required List<File> newImages,
    void Function()? onRecordWritten,
  }) async {
    // Derived ids keep concurrent upload documents untouched.
    if (removedImages.isNotEmpty) {
      await repo.removeAppointmentPictures(id, removedImages);
    }
    onRecordWritten?.call();
    // Delete bytes only after documents stop referencing them.
    await _deleteOrphanedImages(removedImages);
    if (newImages.isNotEmpty) {
      uploader?.uploadInBackground(appointmentId: id, newImages: newImages);
    }
  }

  /// Best-effort cleanup after removed photo documents are gone.
  Future<void> _deleteOrphanedImages(List<AppointmentImage> images) async {
    if (images.isEmpty) return;
    final storage = resolveStorage();
    if (storage == null) return;
    try {
      await storage.deleteImages(images);
    } catch (e, st) {
      logger.warn('APPT-SAVE deleteImages failed (orphaned bytes)', e, st);
    }
  }
}
