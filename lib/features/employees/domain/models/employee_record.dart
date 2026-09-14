import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/features/employees/domain/policies/employee_name_policy.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';

part 'employee_record.freezed.dart';

@freezed
abstract class EmployeeRecord with _$EmployeeRecord {
  const factory EmployeeRecord({
    required String id,
    @Default('') String name,
    @Default('') String firstName,
    @Default('') String lastName,
    @Default('') String email,
    @Default('') String phone,
    // A crewPalette member, not Material blue: an off-palette hue is also
    // outside the dark-theme override map, so a doc that never picked a colour
    // rendered unlifted in dark.
    @Default(AppColors.crewDefault) Color color,
    @Default('employee') String role,
    @Default('') String status,
    @Default('') String uid,
    @Default(JobTitle.unset) JobTitle jobTitle,
    @Default(kDefaultWorkingDays) List<bool> workingDays,
    @Default(kDefaultWorkStartMinutes) int workStartMinutes,
    @Default(kDefaultWorkEndMinutes) int workEndMinutes,
    // 0 means no cap.
    @Default(0) int maxJobsPerDay,
    @Default(false) bool onCall,
    // Per-person opt-out for the traffic-aware "time to leave" push.
    @Default(true) bool travelAlertsEnabled,
    // Explicit consent for live location uploads used by the staff map and
    // travel-time presence.
    @Default(false) bool locationSharingEnabled,
    // Admin-only: hides the account from every teammate list and count.
    @Default(false) bool isTestAccount,
    // Admin-only opt-in for the month-end overdue review push.
    @Default(false) bool monthEndReviewPush,
    // NOTE: emergencyContact/emergencyPhone are NOT here — they live in
    // users/{docId}/private/emergency so rules can gate them to the admin and
    // the person themselves.
    DateTime? createdAt,
  }) = _EmployeeRecord;
  const EmployeeRecord._();

  factory EmployeeRecord.fromMap(String id, Map<String, dynamic> data) {
    final colorValue =
        int.tryParse((data['colorValue'] ?? '').toString()) ??
        AppColors.crewDefault.toARGB32();
    // `firestoreList`, never `as List?` — same leniency rule as the fields
    // below, and a non-list collapses to the same default an absent one does.
    final storedDays = firestoreList(
      data['workingDays'],
    ).map((v) => v == true).toList();

    return EmployeeRecord(
      id: id,
      name: (data['name'] ?? '').toString(),
      firstName: (data['firstName'] ?? '').toString(),
      lastName: (data['lastName'] ?? '').toString(),
      email: (data['email'] ?? '').toString(),
      phone: (data['phone'] ?? '').toString(),
      color: Color(colorValue),
      role: (data['role'] ?? 'employee').toString(),
      status: (data['status'] ?? '').toString(),
      uid: (data['uid'] ?? '').toString(),
      // Lenient like every other field here, and for a sharper reason: this
      // factory runs inside three `users` snapshot streams AND on the sign-in
      // path, so one console-edited doc holding a numeric jobTitle or a string
      // "480" would throw app-wide — crew picker, day route, live-map roster
      // and calendar dots at once — and lock that person out of signing in.
      jobTitle: JobTitle.fromRaw(data['jobTitle']?.toString()),
      workingDays: normalizeWorkingDays(storedDays),
      workStartMinutes:
          firestoreInt(data['workStartMinutes']) ?? kDefaultWorkStartMinutes,
      workEndMinutes:
          firestoreInt(data['workEndMinutes']) ?? kDefaultWorkEndMinutes,
      maxJobsPerDay: firestoreInt(data['maxJobsPerDay']) ?? 0,
      onCall: data['onCall'] == true,
      // `!= false`, never `== true`: an absent field must read as ON.
      travelAlertsEnabled: data['travelAlertsEnabled'] != false,
      locationSharingEnabled: data['locationSharingEnabled'] == true,
      isTestAccount: data['isTestAccount'] == true,
      monthEndReviewPush: data['monthEndReviewPush'] == true,
      createdAt: firestoreDateTime(data['createdAt']),
    );
  }

  /// Editable fields only. `createdAt` is function-owned and deliberately
  /// absent — see its declaration.
  Map<String, dynamic> toMap() => {
    'name': name,
    'firstName': firstName,
    'lastName': lastName,
    'phone': phone,
    'colorValue': color.toARGB32().toString(),
    'role': role,
    'jobTitle': jobTitle.raw,
    'workingDays': workingDays,
    'workStartMinutes': workStartMinutes,
    'workEndMinutes': workEndMinutes,
    'maxJobsPerDay': maxJobsPerDay,
    'onCall': onCall,
    'isTestAccount': isTestAccount,
    'monthEndReviewPush': monthEndReviewPush,
    // NOTE: `travelAlertsEnabled` is deliberately NOT emitted. It is the
    // person's own notification preference, written only by `updateSelfDetails`
    // — an admin save must leave it exactly as it was, and emitting it here
    // would let a future whole-record write flip somebody else's push setting.
    // `locationSharingEnabled` follows the same self-service-only contract.
  };

  /// The name every in-app surface renders — the split halves first, then the
  /// stored composed [name], then [email].
  String get displayName => displayEmployeeName(
    firstName: firstName,
    lastName: lastName,
    name: name,
    email: email,
  );

  bool get isAdmin => role == 'admin';

  /// Crew — someone a job can be assigned to; never a test account.
  bool get isAssignable => jobTitle.isAssignable && !isTestAccount;

  bool get isActive => status == 'active';
  bool get isDisabled => status == 'disabled';

  /// The account exists with a real `uid` but setup has never been completed —
  /// the person is still on the password their admin handed them.
  bool get isInvited => status == 'invited';
}
