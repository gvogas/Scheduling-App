import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';

abstract class EmployeesRepository {
  Stream<List<EmployeeRecord>> watchAllUsers();

  Stream<List<EmployeeRecord>> watchEmployees();

  Stream<List<EmployeeRecord>> watchAssignableUsers();

  /// Creates (or re-provisions) a plain-employee Auth account and `users` doc; returns its credentials.
  Future<NewAccountCredentials> createEmployeeAccount({
    required String name,
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    required String colorValue,
    required String jobTitle,
  });

  /// Deletes a never-set-up account; throws `EmployeesFailureAccountNoLongerPending` once set up.
  Future<void> deleteEmployeeAccount(String docId);

  /// Issues a new temporary password for an ACTIVE account and flags it for a forced change.
  Future<NewAccountCredentials> resetEmployeePassword(String docId);

  /// Replaces the signed-in user's temporary password and clears the reset flag.
  Future<void> completePasswordReset(String newPassword);

  /// Sets the signed-in user's password and activates their account with the setup profile.
  Future<void> completeEmployeeSetup({
    required String newPassword,
    String firstName,
    String lastName,
    String phone,
    bool termsAccepted,
    bool locationConsent,
  });

  /// Persists [employee]'s editable fields; an email change moves Auth first via `changeEmployeeEmail`.
  Future<void> updateEmployee({
    required String docId,
    required EmployeeRecord employee,
  });

  /// A person's edit to their own record; writes exactly `kSelfServiceUserFields`.
  Future<void> updateSelfDetails(EmployeeRecord employee);

  /// Streams `users/{docId}/private/emergency`, or [EmergencyContact.empty] if absent.
  Stream<EmergencyContact> watchEmergencyContact(String docId);

  /// Writes `users/{docId}/private/emergency`.
  Future<void> saveEmergencyContact(String docId, EmergencyContact contact);

  Future<UserUidMatch?> findUserByUid(String uid);

  Future<void> deactivateEmployee(String docId);

  Future<void> reactivateEmployee(String docId);

  /// Streams the signed-in user's users doc (name, status and role).
  Stream<Map<String, dynamic>> watchUserDoc(String uid);

  /// The doc id [watchUserDoc] last resolved for [uid]; null means query for it.
  String? cachedUserDocId(String uid);
}

class UserUidMatch {
  const UserUidMatch({required this.id, required this.data});
  final String id;
  final Map<String, dynamic> data;
}
