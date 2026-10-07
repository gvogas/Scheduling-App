import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/employees/data/firebase_employees_repository.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

final employeesRepositoryProvider = Provider<EmployeesRepository>((ref) {
  final firestore = ref.watch(firestoreProvider);
  return FirebaseEmployeesRepository(firestore);
});

final allUsersStreamProvider = StreamProvider<List<EmployeeRecord>>((ref) {
  final repo = ref.watch(employeesRepositoryProvider);

  Stream<List<EmployeeRecord>> streamForRole(String role) {
    if (role == 'admin') return repo.watchAllUsers();
    return repo.watchAssignableUsers();
  }

  return streamForUid(ref, (uid) {
    if (uid == null) return Stream.value(const <EmployeeRecord>[]);

    // The ROLE picks the query, so it has to settle too: an admin resolved as
    // an employee gets `watchAssignableUsers`, which hides invited and
    // disabled accounts from the roster that exists to manage them.
    //
    // Projected down to the role STRING, never the raw doc: a `Map` compares
    // by identity, so every own-doc write would otherwise rebuild this
    // provider and re-read the whole `users` collection.
    final roleState = ref.watch(
      currentUserDocProvider.select(
        (s) => s.whenData((doc) => (doc['role'] ?? '').toString().trim()),
      ),
    );
    if (roleState.hasError) {
      return Stream.error(
        roleState.error!,
        roleState.stackTrace ?? StackTrace.current,
      );
    }
    if (roleState.isLoading) {
      return Stream.fromFuture(
        ref.watch(currentUserDocProvider.future),
      ).asyncExpand(
        (doc) => streamForRole((doc['role'] ?? '').toString().trim()),
      );
    }
    return streamForRole(roleState.value ?? '');
  });
});

/// Container-scoped mutable holders for the content-equality memo — each
/// container gets its own cache.
final _colorMapMemoProvider = Provider((ref) => _MapMemo<Color>());
final _nameMapMemoProvider = Provider((ref) => _MapMemo<String>());

class _MapMemo<V> {
  Map<String, V>? value;
}

// Memoized lookup maps — avoids re-allocating on every rebuild, and reuses
// the same instance when the content hasn't actually changed so watchers
// don't get notified for nothing.
Map<String, V> _memoizedEmployeeMap<V>(
  Ref ref,
  Provider<_MapMemo<V>> memoProvider,
  V Function(EmployeeRecord e) valueOf,
) {
  final memo = ref.watch(memoProvider);
  final employees = ref.watch(allUsersStreamProvider).asData?.value ?? const [];
  final next = {for (final e in employees) e.id: valueOf(e)};
  final previous = memo.value;
  if (previous != null && mapEquals(previous, next)) return previous;
  memo.value = next;
  return next;
}

final employeeColorMapProvider = Provider<Map<String, Color>>(
  (ref) => _memoizedEmployeeMap(ref, _colorMapMemoProvider, (e) => e.color),
);

final employeeNameMapProvider = Provider<Map<String, String>>(
  (ref) =>
      _memoizedEmployeeMap(ref, _nameMapMemoProvider, (e) => e.displayName),
);

/// Active employees only.
///
/// `autoDispose`, because its consumers are transient — the appointment edit
/// sheet directly, and the add sheet plus the Dashboard through
/// [assignableEmployeesProvider], which derives from this one and so keeps its
/// subscription. Without it, opening the add-appointment sheet ONCE attached a
/// second live `users` listener (alongside the always-on `watchAllUsers()`) for
/// the rest of the session.
///
/// Deliberately NOT derived from `allUsersStreamProvider`: that one includes
/// invited and disabled accounts for admin roster surfaces, while this one is
/// active employees only for crew-picking surfaces. That distinction is
/// load-bearing; keep it.
final employeesStreamProvider =
    StreamProvider.autoDispose<List<EmployeeRecord>>((ref) {
      return streamForUid(ref, (uid) {
        if (uid == null) return Stream.value(const <EmployeeRecord>[]);
        return ref.watch(employeesRepositoryProvider).watchEmployees();
      });
    });

/// Active employees a job can actually be assigned to — [employeesStreamProvider]
/// minus the titles that aren't crew (today: dispatcher).
///
/// The assignee picker and the dashboard's per-person job numbers read THIS
/// one; anything that manages accounts rather than crew keeps reading the
/// unfiltered stream. Deliberately derived rather than filtered inside
/// `employeesStreamProvider`: "active" and "assignable" are two questions, and
/// the retain path in `EventDetailsController._resolveActiveEmployees` asks
/// the first one straight from the repository — a dispatcher already stored on
/// a job must still read as ACTIVE there, or `mergeRetainedAssignees` would
/// treat a deliberate removal as an assignee the picker couldn't show and put
/// them straight back.
final assignableEmployeesProvider =
    Provider.autoDispose<AsyncValue<List<EmployeeRecord>>>(
      (ref) => ref
          .watch(employeesStreamProvider)
          .whenData(
            (employees) => [
              for (final e in employees)
                if (e.isAssignable) e,
            ],
          ),
    );

typedef _EmployeeSearchEntry = ({
  EmployeeRecord employee,
  String text,
  String phoneDigits,
});

// Pre-normalized, memoized search index — per-keystroke filtering then only
// has to normalize the query, not every employee field.
final _employeeSearchIndexProvider = Provider<List<_EmployeeSearchEntry>>((
  ref,
) {
  final employees = ref.watch(allUsersStreamProvider).asData?.value ?? const [];
  return [
    for (final e in employees)
      (
        employee: e,
        text: ClientSearchPolicy.normalize('${e.displayName} ${e.email}'),
        phoneDigits: ClientSearchPolicy.digitsOnly(e.phone),
      ),
  ];
});

final filteredEmployeesProvider = Provider.autoDispose
    .family<List<EmployeeRecord>, String>((ref, query) {
      final index = ref.watch(_employeeSearchIndexProvider);
      // Accent-folded + digits-only matching (mirrors client search).
      final q = ClientSearchPolicy.normalize(query);
      final qDigits = ClientSearchPolicy.digitsOnly(query);
      if (q.isEmpty && qDigits.isEmpty) {
        return [for (final entry in index) entry.employee];
      }
      return [
        for (final entry in index)
          if ((q.isNotEmpty && entry.text.contains(q)) ||
              (qDigits.isNotEmpty && entry.phoneDigits.contains(qDigits)))
            entry.employee,
      ];
    });
