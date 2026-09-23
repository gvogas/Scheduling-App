import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';

abstract class EmployeesRepository {
  Stream<List<EmployeeRecord>> watchAllUsers();

  Stream<List<EmployeeRecord>> watchEmployees();

  Stream<List<EmployeeRecord>> watchAssignableUsers();

  /// Creates the employee's Firebase Auth account and their `users` doc, and
  /// returns the credentials to read out to them.
  ///
  /// Re-running this for someone who hasn't set up yet is the supported
  /// "they never signed in / they lost the password" path: it refreshes their
  /// editable fields and issues a NEW random starting password. It throws
  /// `EmployeesFailureEmailAlreadyExists` once they HAVE set up, so it can
  /// never reset a password someone chose.
  ///
  /// The account is always created as a plain employee — the callable does not
  /// accept a role. Promotion to admin is a separate edit, after setup.
  Future<NewAccountCredentials> createEmployeeAccount({
    required String name,
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    required String colorValue,
    required String jobTitle,
  });

  /// Deletes an employee account that has never been set up — both the `users`
  /// doc and the Firebase Auth account.
  ///
  /// Throws `EmployeesFailureAccountNoLongerPending` when the server refuses
  /// because the person completed setup in the meantime. There is no delete
  /// for a set-up account: disable is the only removal.
  Future<void> deleteEmployeeAccount(String docId);

  /// Activates the signed-in user's own account, carrying the setup profile
  /// and consent flags the server stamps onto the users doc.
  ///
  /// Call this only AFTER the password has actually been changed — the server
  /// cannot see the password, so the order is what makes "you must replace the
  /// default" true.
  Future<void> completeEmployeeSetup({
    required String newPassword,
    String firstName,
    String lastName,
    String phone,
    bool termsAccepted,
    bool locationConsent,
  });

  /// Persists the editable fields of [employee] onto `users/{docId}`.
  ///
  /// The repository builds a field-scoped allowlist from the record — `uid` is
  /// rules-forbidden and `status` belongs to deactivate/reactivate, so neither
  /// is ever in the update map no matter what the record carries.
  ///
  /// A changed `email` on a doc that carries a `uid` is routed through the
  /// `changeEmployeeEmail` callable FIRST, so the Firebase Auth account and the
  /// users doc move together — a Firestore-only change would leave the person
  /// signing in at the old address. Throws
  /// `EmployeesFailureEmailAlreadyExists` if the new address is taken.
  Future<void> updateEmployee({
    required String docId,
    required EmployeeRecord employee,
  });

  /// A person's edit to their OWN record (P5, Settings › My details).
  ///
  /// Deliberately separate from [updateEmployee] rather than a flag on it: the
  /// rules gate a self write through `isAvailabilityOnlyChange()`, whose
  /// `hasOnly` rejects the ENTIRE update if one unnamed key rides along — and
  /// `updateEmployee`'s patch carries `role`, `email` and the emergency
  /// `FieldValue.delete()` scrub, every one of which would fail it.
  ///
  /// The keys written here must stay equal to `kSelfServiceUserFields`, which
  /// mirrors the rules; `self_service_fields_test.dart` pins that equality.
  /// Takes the whole record — see the implementation for why loose scalars were
  /// a trap here. Pass `record.copyWith(...)` of just the fields that changed.
  Future<void> updateSelfDetails(EmployeeRecord employee);

  /// Streams `users/{docId}/private/emergency`.
  ///
  /// Its own document, not two fields on the users doc: rules are
  /// document-level, and `/users` is readable by every active peer. Only an
  /// admin or the person themselves can read this path — see [EmergencyContact].
  /// Emits [EmergencyContact.empty] when the doc doesn't exist yet.
  Stream<EmergencyContact> watchEmergencyContact(String docId);

  /// Writes `users/{docId}/private/emergency`.
  ///
  /// The legacy parent-doc pair is scrubbed by admin saves in
  /// [updateEmployee]; this path is also used by self-service settings, whose
  /// allowlist would reject those extra delete keys.
  Future<void> saveEmergencyContact(String docId, EmergencyContact contact);

  Future<UserUidMatch?> findUserByUid(String uid);

  Future<void> deactivateEmployee(String docId);

  Future<void> reactivateEmployee(String docId);

  /// Streams the signed-in user's `users/{uid}` doc — a single listener that
  /// covers name, status, and role.
  Stream<Map<String, dynamic>> watchUserDoc(String uid);

  /// The doc id [watchUserDoc] last resolved for [uid], or null if it has not
  /// emitted a populated doc for that uid yet.
  ///
  /// Exists so a caller that already watches that stream does not pay a second
  /// `where('uid').limit(1).get()` purely to learn the id the stream had in
  /// hand and discarded. Null just means "ask the slow way".
  String? cachedUserDocId(String uid);
}

class UserUidMatch {
  const UserUidMatch({required this.id, required this.data});
  final String id;
  final Map<String, dynamic> data;
}
