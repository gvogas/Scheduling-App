# P5 — Settings + My details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an employee one screen where they edit their own phone, sign-in
email and availability, backed by the self-service rules clause that has been
written but uncalled since P4.

**Architecture:** Three separable phases. **Phase A** is app + `firestore.rules`
only: it calls the already-written `isAvailabilityOnlyChange()` and grows
`MyDetailsScreen` from an emergency-contact form into the real screen.
**Phase B** adds a `self` branch to the existing `changeEmployeeEmail` callable
so an email edit still moves Auth and Firestore together, plus the
active-admins fan-out P6 also needs. **Phase C** is the P4-parked time-to-leave
alerts toggle. Each phase ends green and shippable on its own.

**Tech Stack:** Flutter 3.10 / Dart, Riverpod 3, Firebase (Firestore, Auth,
Cloud Functions v2, App Check), `gen_l10n` (EN + FR), `flutter_test` +
`mocktail`, jest for `functions/`.

**Source spec:** `docs/plans/2026-07-29-redesign-program.md` §P5, reconciled
against the code 2026-08-10.

---

## Decisions taken while planning (read these before starting)

1. **My details does NOT get a NOTIFICATIONS block.** The spec says
   "NOTIFICATIONS (existing toggles)", but `settings_screen.dart` already
   renders that section (OS permission row + Live Activity toggle) through
   `NotificationsSettingsCard`. A second copy would be two surfaces for one
   piece of state. The genuinely-missing notification item is the P4-parked
   time-to-leave toggle, which is Phase C and lands in the **existing**
   Settings section.

2. **Identity fields are explicitly saved; availability applies immediately.**
   Owner instruction, 2026-08-10. Phone / emergency contact / emergency phone
   sit behind a **Save + Cancel bar that appears only when the form is dirty**;
   Cancel reverts every identity field to the stored values. The availability
   toggles keep the spec's apply-immediately behaviour — they are switches, and
   the spec is explicit that a change "applies immediately" with the inline
   amber warning. Do not collapse the two into one behaviour in either
   direction.

3. **`isSelf()` does not exist yet.** The P5 paragraph in the spec and the
   comment above `isAvailabilityOnlyChange()` both assume it. Task 1 adds it,
   and it gates on `isActiveUser()` as well as the uid match — an `invited` or
   `disabled` doc must not be self-editable.

4. **SCHEDULING panel is scoped to `maxJobsPerDay`.** The spec says the
   "SET BY YOUR ADMIN" panel becomes editable for admins and is hidden for
   technicians. `role`, `jobTitle`, `colorValue` and `status` stay on the
   admin-only Team sheet — an admin editing their own role from a self-service
   screen is a privilege-escalation shape with no product reason to exist.

5. **No profile card on My details.** The spec lists one, but `settings_screen.dart`
   already renders `SettingsProfileCard` directly above the row that navigates
   here — a second copy one tap later restates what the user just tapped past.
   The photo pill was already deferred with the email in the program's
   deviations list, so what remains of that card is name + role, both of which
   are on screen a moment earlier.

6. **The email field stays read-only until Phase B lands.** Shipping an
   editable email without the callable's `self` branch would either write
   `email` on the users doc (which the rules must refuse, and which is exactly
   the desync `changeEmployeeEmail` exists to end) or fail with an opaque
   `permission-denied`.

---

## File structure

**Phase A**

| File | Responsibility |
|---|---|
| `firestore.rules` (modify, ~261–287) | Add `isSelf()`; call `isAvailabilityOnlyChange()` from `allow update`; correct the two "only an admin can update" comments |
| `test/core/security/self_service_rules_test.dart` (create) | Read `firestore.rules` back and pin the clause, the same mechanism `emergency_contact_rules_test.dart` uses |
| `lib/features/employees/domain/policies/self_service_fields.dart` (create) | `kSelfServiceUserFields` — the Dart mirror of the rules allowlist, and the one owner of "which keys may a person write on their own doc" |
| `lib/features/employees/domain/employees_repository.dart` (modify) | Declare `updateSelfDetails` |
| `lib/features/employees/data/firebase_employees_repository.dart` (modify) | Implement `updateSelfDetails` — allowlisted keys only, no emergency scrub |
| `lib/features/employees/domain/policies/availability_conflict_policy.dart` (create) | Pure `daysWithBookedWork(...)` — which turned-off weekdays still hold jobs |
| `lib/features/settings/application/my_details_providers.dart` (create) | `myEmployeeRecordProvider`, `myAvailabilityConflictProvider` |
| `lib/features/settings/widgets/sections/my_identity_section.dart` (create) | Identity panel + the dirty-gated Save/Cancel bar |
| `lib/features/settings/widgets/sections/my_availability_section.dart` (create) | Day toggles, hours, on-call, amber conflict note |
| `lib/features/settings/widgets/sections/my_scheduling_section.dart` (create) | Admin-only `maxJobsPerDay` |
| `lib/features/settings/screens/my_details_screen.dart` (modify) | Host the three sections |
| `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb` (modify) | New keys, in lockstep |

**Phase B**

| File | Responsibility |
|---|---|
| `functions/employee_accounts.js` (modify) | `self` branch on `changeEmployeeEmail`; `notifyAdminsOfSelfEmailChange` |
| `functions/notification_utils.js` (modify) | `sendToActiveAdmins` fan-out (shared with P6) |
| `functions/notification_messages.js` (modify) | `buildSelfEmailChangedMessage` |
| `functions/__tests__/employee_accounts_self_email.test.js` (create) | Guard order, self branch, admin-vs-self refusals |
| `functions/__tests__/notification_admin_fanout.test.js` (create) | Fan-out targets active admins only |
| `lib/features/settings/services/self_email_service.dart` (create) | Reauth + callable, one owner |
| `lib/features/settings/widgets/dialogs/change_email_dialog.dart` (create) | Confirm-twice + password, `enableIMEPersonalizedLearning: false` |

**Phase C**

| File | Responsibility |
|---|---|
| `firestore.rules` (modify) | `travelAlertsEnabled` into the self allowlist + `isValidUserData` |
| `functions/travel_utils.js` (modify) | Skip `leaveNow` for an opted-out assignee |
| `lib/features/settings/widgets/cards/notifications_settings_card.dart` (modify) | The toggle row |

---

# PHASE A — rules, phone, availability

### Task 1: Call the self-service rules clause

**Files:**
- Modify: `firestore.rules:261-287`
- Test: `test/core/security/self_service_rules_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/core/security/self_service_rules_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P5's self-service clause. `isAvailabilityOnlyChange()` was written in P4 and
/// deliberately left uncalled until there was a UI behind it; this pins the
/// call, and pins the two things that make it safe to grant.
///
/// Rules cannot be unit-tested without the emulator, so this reads
/// `firestore.rules` back as text — the same mechanism
/// `emergency_contact_rules_test.dart` and `text_limits_test.dart` use.
void main() {
  late final rules = File('firestore.rules').readAsStringSync();

  group('users self-service update', () {
    test('allow update carries the self clause', () {
      final updateBlock = RegExp(
        r'allow update: if isAdmin\(\)(.*?);',
        dotAll: true,
      ).firstMatch(rules)?.group(1);

      expect(updateBlock, isNotNull, reason: 'allow update was restructured');
      expect(updateBlock, contains('isSelf()'));
      expect(updateBlock, contains('isAvailabilityOnlyChange()'));
    });

    test('isSelf requires an ACTIVE account, not just a uid match', () {
      // A disabled account keeps its Auth credential until syncUsersByUid
      // revokes it, and an invited one is mid-setup. Neither may self-edit.
      final fn = RegExp(
        r'function isSelf\(\)\s*\{(.*?)\}',
        dotAll: true,
      ).firstMatch(rules)?.group(1);

      expect(fn, isNotNull, reason: 'isSelf() was removed');
      expect(fn, contains('isActiveUser()'));
      expect(fn, contains('resource.data.uid == request.auth.uid'));
    });

    test('the self allowlist never admits an escalation field', () {
      final fn = RegExp(
        r'function isAvailabilityOnlyChange\(\)\s*\{(.*?)\}',
        dotAll: true,
      ).firstMatch(rules)?.group(1);

      expect(fn, isNotNull);
      for (final banned in const [
        'role',
        'status',
        'uid',
        'colorValue',
        'maxJobsPerDay',
        'email',
      ]) {
        expect(
          fn,
          isNot(contains("'$banned'")),
          reason: '$banned must stay admin-only',
        );
      }
    });
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/core/security/self_service_rules_test.dart`
Expected: FAIL — `isSelf() was removed` and the `allow update` expectation,
because neither exists yet.

- [ ] **Step 3: Add `isSelf()` to `firestore.rules`**

Insert immediately **above** `function isAvailabilityOnlyChange()` (currently
line 265), inside the `/users/{userId}` match block:

```
      // P5's self-service gate. The uid match alone is not enough: a disabled
      // account keeps its Auth credential until syncUsersByUid revokes it, and
      // an `invited` account is mid-setup with completeEmployeeSetup owning
      // its doc. Both must fall through to the admin-only branch.
      function isSelf() {
        return isActiveUser()
          && resource.data.uid == request.auth.uid;
      }
```

- [ ] **Step 4: Call it from `allow update`**

Replace the `allow update` block (currently lines 271–287) with:

```
      // Two ways in. An ADMIN may update any doc, minus the function-owned
      // fields. A PERSON may update their OWN doc, and only the self-service
      // keys isAvailabilityOnlyChange() names — availability, on-call and
      // their own phone. Scheduling fields (role, jobTitle, colorValue,
      // maxJobsPerDay, status) stay admin-only on both paths; `uid` and the
      // three consent stamps stay function-owned, which is why the self branch
      // cannot reach them either — they are not on the allowlist.
      //
      // Account activation still happens server-side via completeEmployeeSetup,
      // so there is no client self-activation path. Rewriting `uid` could
      // hijack another account's bridge doc.
      // Diff-based, so the denylist only fires when a write actually CHANGES
      // one — every shipped path (updateEmployee's field-scoped map,
      // deactivate/reactivate, updateSelfDetails) leaves them untouched. The
      // callables write via the Admin SDK, which bypasses rules entirely.
      allow update: if (isAdmin() || (isSelf() && isAvailabilityOnlyChange()))
            && !request.resource.data.diff(resource.data)
                 .affectedKeys()
                 .hasAny(['uid', 'termsAcceptedAt', 'locationConsentAt'])
            && emergencyFieldNotSet('emergencyContact')
            && emergencyFieldNotSet('emergencyPhone')
            && isValidUserData(request.resource.data);
```

Note the parentheses around the disjunction: without them the denylist and
`isValidUserData` would bind to the self branch only, and an admin write could
skip both.

- [ ] **Step 5: Fix the now-wrong comment above `isAvailabilityOnlyChange()`**

Replace the paragraph at lines 261–264 with:

```
      // The self-service allowlist, called from `allow update` above (P5,
      // 2026-08-10). Adding a key here grants every active employee the right
      // to write it on their own doc — check it is not a scheduling or
      // identity field first. `email` in particular must NEVER join this list:
      // it is a sign-in identity, and Auth and Firestore move together through
      // changeEmployeeEmail or not at all.
```

- [ ] **Step 6: Run the test and the full security group**

Run: `flutter test test/core/security/`
Expected: PASS, including the existing `emergency_contact_rules_test.dart`.

- [ ] **Step 7: Commit**

```bash
git add firestore.rules test/core/security/self_service_rules_test.dart
git commit -m "feat(rules): call the P5 self-service clause on users allow update"
```

---

### Task 2: The Dart mirror of the allowlist

**Files:**
- Create: `lib/features/employees/domain/policies/self_service_fields.dart`
- Test: `test/features/employees/domain/self_service_fields_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/employees/domain/self_service_fields_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/employees/domain/policies/self_service_fields.dart';

/// Dart and CEL cannot share a constant, so this test is the only mechanism
/// keeping the two allowlists equal. A self write carrying a key the rules do
/// not name fails the whole update with an opaque `permission-denied`.
void main() {
  test('the Dart allowlist equals the rules allowlist', () {
    final fn = RegExp(
      r'function isAvailabilityOnlyChange\(\)\s*\{(.*?)\}',
      dotAll: true,
    ).firstMatch(File('firestore.rules').readAsStringSync())?.group(1);

    expect(fn, isNotNull);
    final inRules = RegExp("'([A-Za-z]+)'")
        .allMatches(fn!)
        .map((m) => m.group(1)!)
        .toSet();

    expect(kSelfServiceUserFields, equals(inRules));
  });

  test('updatedAt is in the set', () {
    // hasOnly() is exact: a write that omits updatedAt is fine, but the rules
    // must permit it, and every write path stamps it.
    expect(kSelfServiceUserFields, contains('updatedAt'));
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/employees/domain/self_service_fields_test.dart`
Expected: FAIL — `self_service_fields.dart` does not exist (compile error).

- [ ] **Step 3: Create the constant**

Create `lib/features/employees/domain/policies/self_service_fields.dart`:

```dart
/// The keys a person may write on their OWN `users` doc.
///
/// Hand-mirrors `isAvailabilityOnlyChange()` in `firestore.rules`, which is the
/// real gate — `self_service_fields_test.dart` reads the rules back and fails
/// the build if the two drift. The rules use `hasOnly`, so a write carrying one
/// extra key is rejected in full, not partially applied.
///
/// Adding a key here without adding it there is a silent `permission-denied` on
/// every self save. Adding it *there* first is the safe order.
const Set<String> kSelfServiceUserFields = {
  'workingDays',
  'workStartMinutes',
  'workEndMinutes',
  'onCall',
  'phone',
  'updatedAt',
};
```

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/employees/domain/self_service_fields_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/employees/domain/policies/self_service_fields.dart \
        test/features/employees/domain/self_service_fields_test.dart
git commit -m "feat(employees): mirror the self-service field allowlist in Dart"
```

---

### Task 3: `updateSelfDetails` on the repository

**Files:**
- Modify: `lib/features/employees/domain/employees_repository.dart`
- Modify: `lib/features/employees/data/firebase_employees_repository.dart:248`
  (add after `updateEmployee`)
- Test: `test/features/employees/data/update_self_details_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/employees/data/update_self_details_test.dart`:

```dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/employees/data/firebase_employees_repository.dart';
import 'package:scheduling/features/employees/domain/policies/self_service_fields.dart';

void main() {
  late FakeFirebaseFirestore firestore;
  late FirebaseEmployeesRepository repository;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    repository = FirebaseEmployeesRepository(firestore: firestore);
    await firestore.collection('users').doc('u1').set({
      'name': 'Theo',
      'phone': '(514) 555-0000',
      'role': 'employee',
      'status': 'active',
      'uid': 'auth-1',
      'workingDays': [false, true, true, true, true, true, false],
      'workStartMinutes': 480,
      'workEndMinutes': 1020,
      'onCall': false,
    });
  });

  test('writes only keys the rules allowlist names', () async {
    await repository.updateSelfDetails(
      docId: 'u1',
      phone: '(514) 555-1234',
      workingDays: const [true, true, true, true, true, true, true],
      workStartMinutes: 420,
      workEndMinutes: 960,
      onCall: true,
    );

    final stored = (await firestore.collection('users').doc('u1').get()).data()!;
    expect(stored['phone'], '(514) 555-1234');
    expect(stored['onCall'], isTrue);
    expect(stored['workStartMinutes'], 420);
    // The doc keeps its admin-owned fields untouched — this is a partial
    // update, and `role`/`status` were never in the patch.
    expect(stored['role'], 'employee');
    expect(stored['status'], 'active');
  });

  test('the patch carries no key outside the allowlist', () async {
    // A single stray key makes the rules' hasOnly() reject the WHOLE write, so
    // this is the assertion that matters most.
    await repository.updateSelfDetails(
      docId: 'u1',
      phone: '(514) 555-1234',
      workingDays: const [true, true, true, true, true, true, true],
      workStartMinutes: 420,
      workEndMinutes: 960,
      onCall: true,
    );

    expect(
      repository.debugLastSelfPatchKeys,
      everyElement(isIn(kSelfServiceUserFields)),
    );
  });

  test('working days are normalized to seven Sunday-indexed flags', () async {
    await repository.updateSelfDetails(
      docId: 'u1',
      phone: '(514) 555-1234',
      workingDays: const [true, true],
      workStartMinutes: 420,
      workEndMinutes: 960,
      onCall: false,
    );

    final stored = (await firestore.collection('users').doc('u1').get()).data()!;
    expect((stored['workingDays']! as List).length, 7);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/employees/data/update_self_details_test.dart`
Expected: FAIL — `updateSelfDetails` is not defined.

- [ ] **Step 3: Declare it on the interface**

In `lib/features/employees/domain/employees_repository.dart`, beside
`updateEmployee`:

```dart
  /// A person's edit to their OWN record.
  ///
  /// Deliberately separate from [updateEmployee]: the rules gate a self write
  /// through `isAvailabilityOnlyChange()`, whose `hasOnly` rejects the entire
  /// update if one extra key rides along — and `updateEmployee`'s patch carries
  /// `role`, `email` and the emergency `FieldValue.delete()` scrub, every one
  /// of which would fail it.
  Future<void> updateSelfDetails({
    required String docId,
    required String phone,
    required List<bool> workingDays,
    required int workStartMinutes,
    required int workEndMinutes,
    required bool onCall,
  });
```

- [ ] **Step 4: Implement it**

In `lib/features/employees/data/firebase_employees_repository.dart`, after
`updateEmployee` (line 248):

```dart
  /// Set by [updateSelfDetails] so a test can assert the patch never carries a
  /// key outside `kSelfServiceUserFields`. The rules reject the whole write on
  /// one stray key, and that failure reaches the user as an opaque
  /// `permission-denied`, so it is worth pinning.
  @visibleForTesting
  Iterable<String> debugLastSelfPatchKeys = const [];

  @override
  Future<void> updateSelfDetails({
    required String docId,
    required String phone,
    required List<bool> workingDays,
    required int workStartMinutes,
    required int workEndMinutes,
    required bool onCall,
  }) async {
    // Exactly the rules allowlist, and nothing else. No emergency scrub here —
    // updateEmployee sends one, but `hasOnly` would reject it.
    final patch = <String, dynamic>{
      'phone': phone.trim(),
      'workingDays': normalizeWorkingDays(workingDays),
      'workStartMinutes': workStartMinutes,
      'workEndMinutes': workEndMinutes,
      'onCall': onCall,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    assert(
      patch.keys.every(kSelfServiceUserFields.contains),
      'self patch carries a key the rules will reject',
    );
    debugLastSelfPatchKeys = patch.keys.toList(growable: false);
    await _users.doc(docId).update(patch);
  }
```

Add the imports at the top of the file if absent:

```dart
import 'package:flutter/foundation.dart';
import 'package:scheduling/features/employees/domain/policies/self_service_fields.dart';
```

- [ ] **Step 5: Run the test**

Run: `flutter test test/features/employees/data/update_self_details_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the analyzer**

Run: `flutter analyze`
Expected: `No issues found!` — that is the repo baseline; any lint printed is
from this change. A likely one is a missing `@override` on a mock
`EmployeesRepository` in an existing test; add the new method to any mock the
analyzer names.

- [ ] **Step 7: Commit**

```bash
git add lib/features/employees test/features/employees
git commit -m "feat(employees): add updateSelfDetails, allowlisted to the self rules clause"
```

---

### Task 4: The availability conflict policy

**Files:**
- Create: `lib/features/employees/domain/policies/availability_conflict_policy.dart`
- Test: `test/features/employees/domain/availability_conflict_policy_test.dart`

The spec's amber warning is "this day has booked work, and the jobs stay until
someone moves them". Deciding *which* days conflict is pure — keep it out of the
widget so it can be tested without Firebase.

- [ ] **Step 1: Write the failing test**

Create `test/features/employees/domain/availability_conflict_policy_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/policies/availability_conflict_policy.dart';

AppointmentRecord _job({
  required DateTime start,
  DateTime? end,
  String status = 'pending',
}) => AppointmentRecord(
  id: 'a-${start.millisecondsSinceEpoch}',
  title: 'Job',
  startTime: start,
  endTime: end ?? start.add(const Duration(hours: 2)),
  status: status,
  employeeIds: const ['me'],
);

void main() {
  // Sunday-indexed, matching `workingDays`. 2026-08-10 is a Monday.
  final monday = DateTime(2026, 8, 10, 9);
  final wednesday = DateTime(2026, 8, 12, 9);

  test('a day being turned OFF that holds work is reported', () {
    final conflicts = daysWithBookedWork(
      appointments: [_job(start: monday)],
      previousWorkingDays: const [false, true, true, true, true, true, false],
      nextWorkingDays: const [false, false, true, true, true, true, false],
    );

    expect(conflicts, {DateTime.monday % 7});
  });

  test('a day left ON is never reported, even when it holds work', () {
    final conflicts = daysWithBookedWork(
      appointments: [_job(start: monday)],
      previousWorkingDays: const [false, true, true, true, true, true, false],
      nextWorkingDays: const [false, true, true, true, true, true, false],
    );

    expect(conflicts, isEmpty);
  });

  test('a turned-off day with no work is not reported', () {
    final conflicts = daysWithBookedWork(
      appointments: [_job(start: wednesday)],
      previousWorkingDays: const [false, true, true, true, true, true, false],
      nextWorkingDays: const [false, false, true, true, true, true, false],
    );

    expect(conflicts, isEmpty);
  });

  test('a cancelled job is not booked work', () {
    final conflicts = daysWithBookedWork(
      appointments: [_job(start: monday, status: 'cancelled')],
      previousWorkingDays: const [false, true, true, true, true, true, false],
      nextWorkingDays: const [false, false, true, true, true, true, false],
    );

    expect(conflicts, isEmpty);
  });

  test('a multi-day run reports every work day it covers', () {
    // Mon 9:00 → Wed 17:00 is a three-work-day run; turning Monday AND
    // Wednesday off must flag both, which is why this walks the slices rather
    // than reading startTime alone.
    final conflicts = daysWithBookedWork(
      appointments: [
        _job(start: monday, end: DateTime(2026, 8, 12, 17)),
      ],
      previousWorkingDays: const [false, true, true, true, true, true, false],
      nextWorkingDays: const [false, false, true, false, true, true, false],
    );

    expect(conflicts, {1, 3});
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/employees/domain/availability_conflict_policy_test.dart`
Expected: FAIL — `availability_conflict_policy.dart` does not exist.

- [ ] **Step 3: Implement the policy**

Create `lib/features/employees/domain/policies/availability_conflict_policy.dart`:

```dart
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// Which weekdays a person is switching OFF while still holding booked work.
///
/// Returns **Sunday-indexed** weekday numbers (`0` = Sunday), matching
/// `workingDays` — see the working-days invariant in `CLAUDE.md`; a Monday-first
/// answer would need a `% 7` conversion at every caller and one missed
/// conversion shifts the warning by a day.
///
/// Nothing is ever auto-unassigned: this only decides what the amber note says.
/// A human moves the jobs.
///
/// Walks each record's day slices rather than its `startTime`, because an
/// appointment may span up to `maxAppointmentSpanDays` and its middle days are
/// real work days.
Set<int> daysWithBookedWork({
  required Iterable<AppointmentRecord> appointments,
  required List<bool> previousWorkingDays,
  required List<bool> nextWorkingDays,
}) {
  final turnedOff = <int>{
    for (var i = 0; i < 7; i++)
      if (_at(previousWorkingDays, i) && !_at(nextWorkingDays, i)) i,
  };
  if (turnedOff.isEmpty) return const {};

  final conflicts = <int>{};
  for (final appointment in appointments) {
    if (appointment.isClosed) continue;
    for (final day in expandToDays(appointment)) {
      // DateTime.sunday is 7; the stored list is 0-indexed on Sunday.
      final index = day.weekday % 7;
      if (turnedOff.contains(index)) conflicts.add(index);
    }
  }
  return conflicts;
}

bool _at(List<bool> days, int index) =>
    index < days.length && days[index];
```

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/employees/domain/availability_conflict_policy_test.dart`
Expected: PASS (5 tests).

If `expandToDays` returns something other than `Iterable<DateTime>`, read
`lib/features/calendar/domain/appointment_day_slice.dart` and adapt — that file
is the single owner of day-scoping and must not be bypassed with local date
arithmetic.

- [ ] **Step 5: Commit**

```bash
git add lib/features/employees/domain/policies/availability_conflict_policy.dart \
        test/features/employees/domain/availability_conflict_policy_test.dart
git commit -m "feat(employees): pure policy for availability-vs-booked-work conflicts"
```

---

### Task 5: My details providers

**Files:**
- Create: `lib/features/settings/application/my_details_providers.dart`
- Test: `test/features/settings/application/my_details_providers_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/settings/application/my_details_providers_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        // The provider reduces the shared range stream rather than opening a
        // per-person query, the same rule the roster's jobs-today count follows.
        myUpcomingAppointmentsProvider.overrideWith(
          (ref) => <AppointmentRecord>[
            AppointmentRecord(
              id: 'a1',
              title: 'Job',
              startTime: DateTime(2026, 8, 10, 9),
              endTime: DateTime(2026, 8, 10, 11),
              status: 'pending',
              employeeIds: const ['me'],
            ),
          ],
        ),
      ],
    );
    // AutoDispose families need a listener in setUp or the state races teardown.
    container.listen(
      myAvailabilityConflictProvider(
        const AvailabilityChange(
          previousWorkingDays: [false, true, true, true, true, true, false],
          nextWorkingDays: [false, false, true, true, true, true, false],
        ),
      ),
      (_, _) {},
    );
  });

  tearDown(container.dispose);

  test('reports Monday when Monday is switched off and holds a job', () {
    final conflicts = container.read(
      myAvailabilityConflictProvider(
        const AvailabilityChange(
          previousWorkingDays: [false, true, true, true, true, true, false],
          nextWorkingDays: [false, false, true, true, true, true, false],
        ),
      ),
    );

    expect(conflicts, contains(1));
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/settings/application/my_details_providers_test.dart`
Expected: FAIL — `my_details_providers.dart` does not exist.

- [ ] **Step 3: Implement the providers**

Create `lib/features/settings/application/my_details_providers.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/policies/availability_conflict_policy.dart';

/// One availability edit, as a value so the conflict provider can be a family.
///
/// A record rather than two loose lists: `family` keys on `==`, and two
/// positional `List<bool>` arguments would need a manual equality anyway.
class AvailabilityChange {
  const AvailabilityChange({
    required this.previousWorkingDays,
    required this.nextWorkingDays,
  });

  final List<bool> previousWorkingDays;
  final List<bool> nextWorkingDays;

  @override
  bool operator ==(Object other) =>
      other is AvailabilityChange &&
      _sameDays(other.previousWorkingDays, previousWorkingDays) &&
      _sameDays(other.nextWorkingDays, nextWorkingDays);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(previousWorkingDays),
    Object.hashAll(nextWorkingDays),
  );

  static bool _sameDays(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The signed-in person's own `users` record.
final myEmployeeRecordProvider = Provider.autoDispose<EmployeeRecord?>((ref) {
  final docId = ref.watch(activeUserIdentityProvider).value?.docId;
  if (docId == null || docId.isEmpty) return null;
  final all = ref.watch(allUsersStreamProvider).value ?? const <EmployeeRecord>[];
  for (final employee in all) {
    if (employee.docId == docId) return employee;
  }
  return null;
});

/// This person's own upcoming jobs, reduced from the SHARED range stream.
///
/// Never a per-person Firestore query: the calendar already holds this range
/// open, so the warning costs no extra read. The stream is a 14-day superset of
/// its range, so every consumer must re-scope — `expandToDays` inside the
/// policy is what does it here.
final myUpcomingAppointmentsProvider =
    Provider.autoDispose<List<AppointmentRecord>>((ref) {
      final docId = ref.watch(activeUserIdentityProvider).value?.docId;
      if (docId == null || docId.isEmpty) return const [];
      final today = ref.watch(currentDayProvider);
      final range = AppointmentDateRange.forMirrors(today);
      final jobs =
          ref.watch(appointmentsInRangeProvider(range)).value ??
          const <AppointmentRecord>[];
      return [
        for (final job in jobs)
          if (job.employeeIds.contains(docId)) job,
      ];
    });

/// Which weekdays this edit switches off while still holding booked work.
final myAvailabilityConflictProvider = Provider.autoDispose
    .family<Set<int>, AvailabilityChange>((ref, change) {
      return daysWithBookedWork(
        appointments: ref.watch(myUpcomingAppointmentsProvider),
        previousWorkingDays: change.previousWorkingDays,
        nextWorkingDays: change.nextWorkingDays,
      );
    });
```

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/settings/application/my_details_providers_test.dart`
Expected: PASS.

If `AppointmentDateRange.forMirrors` is not the right window here, use it
anyway — it is the window `AppSyncListeners` already holds open for the widget
and Siri mirrors, so reusing it adds no listener. Do **not** invent a new range
value; a different range forks a second live Firestore query for the same data.

- [ ] **Step 5: Commit**

```bash
git add lib/features/settings/application/my_details_providers.dart \
        test/features/settings/application/my_details_providers_test.dart
git commit -m "feat(settings): providers for my-details record and availability conflicts"
```

---

### Task 6: l10n keys for Phase A

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_fr.arb`

A hook regenerates `gen_l10n` on ARB edits — do not run `flutter gen-l10n` by
hand. Every key needs a `@key` block in EN or generation fails
(`required-resource-attributes: true`).

- [ ] **Step 1: Add the EN keys**

Add to `lib/l10n/app_en.arb`, beside the existing `settings_myDetails*` keys:

```json
  "settings_myDetailsIdentity": "YOU CAN CHANGE THESE",
  "@settings_myDetailsIdentity": {
    "description": "Section header over the fields a person may edit about themselves on My details."
  },
  "settings_myDetailsIdentityBlurb": "Your manager sets everything else.",
  "@settings_myDetailsIdentityBlurb": {
    "description": "Caption under the editable-fields section on My details."
  },
  "settings_myDetailsEmailReadOnly": "Ask your manager to change this.",
  "@settings_myDetailsEmailReadOnly": {
    "description": "Caption under the read-only sign-in email row on My details."
  },
  "settings_myAvailability": "MY AVAILABILITY",
  "@settings_myAvailability": {
    "description": "Section header over the working-days and hours controls on My details."
  },
  "settings_myAvailabilityBlurb": "Changes apply right away.",
  "@settings_myAvailabilityBlurb": {
    "description": "Caption telling the user availability toggles save immediately, unlike the fields above."
  },
  "settings_availabilityConflict": "{days} already has booked work — the jobs stay until someone moves them.",
  "@settings_availabilityConflict": {
    "description": "Amber warning shown when a person turns off a day that still holds appointments.",
    "placeholders": {
      "days": {
        "type": "String",
        "example": "Monday and Wednesday"
      }
    }
  },
  "settings_myScheduling": "SCHEDULING",
  "@settings_myScheduling": {
    "description": "Admin-only section header on My details for scheduling limits."
  },
  "common_discard": "Discard",
  "@common_discard": {
    "description": "Button that throws away unsaved edits and restores the stored values."
  },
  "settings_unsavedChanges": "Unsaved changes",
  "@settings_unsavedChanges": {
    "description": "Label on the save/discard bar that appears once a form is edited."
  },
  "error_introSaveAvailability": "Couldn't save your availability",
  "@error_introSaveAvailability": {
    "description": "Notice intro when the immediate availability write fails."
  },
```

- [ ] **Step 2: Add the FR keys in lockstep**

Add to `lib/l10n/app_fr.arb` (no `@key` blocks in FR):

```json
  "settings_myDetailsIdentity": "VOUS POUVEZ MODIFIER CECI",
  "settings_myDetailsIdentityBlurb": "Votre gestionnaire définit tout le reste.",
  "settings_myDetailsEmailReadOnly": "Demandez à votre gestionnaire de la modifier.",
  "settings_myAvailability": "MES DISPONIBILITÉS",
  "settings_myAvailabilityBlurb": "Les changements s'appliquent immédiatement.",
  "settings_availabilityConflict": "{days} a déjà du travail réservé — les tâches restent jusqu'à ce que quelqu'un les déplace.",
  "settings_myScheduling": "PLANIFICATION",
  "common_discard": "Annuler les modifications",
  "settings_unsavedChanges": "Modifications non enregistrées",
  "error_introSaveAvailability": "Impossible d'enregistrer vos disponibilités",
```

- [ ] **Step 3: Confirm generation succeeded and nothing is untranslated**

Run: `flutter analyze`
Expected: `No issues found!`

Then check `lib/l10n/.gen/untranslated.json` — it must not name any key added
above. EN/FR drift surfaces there rather than as a build failure.

- [ ] **Step 4: Commit**

```bash
git add lib/l10n/app_en.arb lib/l10n/app_fr.arb
git commit -m "feat(l10n): keys for the My details identity, availability and scheduling sections"
```

---

### Task 7: The identity section with its Save / Discard bar

**Files:**
- Create: `lib/features/settings/widgets/sections/my_identity_section.dart`
- Test: `test/features/settings/widgets/my_identity_section_test.dart`

**Behaviour (owner instruction, 2026-08-10):** nothing here writes until Save is
pressed. The bar is absent while the form is pristine, so a screen that has only
been read shows no call to action; Discard restores the stored values and the
bar disappears again.

- [ ] **Step 1: Write the failing test**

Create `test/features/settings/widgets/my_identity_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/settings/widgets/sections/my_identity_section.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _harness(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('the save bar is hidden while the form is pristine', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        MyIdentitySection(
          email: 'theo@example.com',
          initialPhone: '(514) 555-0000',
          initialEmergencyContact: 'Ana',
          initialEmergencyPhone: '(514) 555-1111',
          isSaving: false,
          onSave: (_) async {},
          onChangeEmail: null,
        ),
      ),
    );

    expect(find.byKey(const Key('myIdentitySaveBar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a field reveals the save bar', (tester) async {
    await tester.pumpWidget(
      _harness(
        MyIdentitySection(
          email: 'theo@example.com',
          initialPhone: '(514) 555-0000',
          initialEmergencyContact: 'Ana',
          initialEmergencyPhone: '(514) 555-1111',
          isSaving: false,
          onSave: (_) async {},
          onChangeEmail: null,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('myPhone')),
      '(514) 555-9999',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('myIdentitySaveBar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discard restores the stored value and hides the bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        MyIdentitySection(
          email: 'theo@example.com',
          initialPhone: '(514) 555-0000',
          initialEmergencyContact: 'Ana',
          initialEmergencyPhone: '(514) 555-1111',
          isSaving: false,
          onSave: (_) async {},
          onChangeEmail: null,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('myPhone')),
      '(514) 555-9999',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('myIdentityDiscard')));
    await tester.pumpAndSettle();

    expect(find.text('(514) 555-0000'), findsOneWidget);
    expect(find.byKey(const Key('myIdentitySaveBar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing is written until save is pressed', (tester) async {
    var saves = 0;
    await tester.pumpWidget(
      _harness(
        MyIdentitySection(
          email: 'theo@example.com',
          initialPhone: '(514) 555-0000',
          initialEmergencyContact: 'Ana',
          initialEmergencyPhone: '(514) 555-1111',
          isSaving: false,
          onSave: (_) async => saves++,
          onChangeEmail: null,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('myPhone')),
      '(514) 555-9999',
    );
    await tester.pumpAndSettle();
    expect(saves, 0, reason: 'typing must not write');

    await tester.tap(find.byKey(const Key('myIdentitySave')));
    await tester.pumpAndSettle();
    expect(saves, 1);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/settings/widgets/my_identity_section_test.dart`
Expected: FAIL — `my_identity_section.dart` does not exist.

- [ ] **Step 3: Implement the section**

Create `lib/features/settings/widgets/sections/my_identity_section.dart`:

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// The identity values a person may change about themselves.
///
/// **Explicitly saved, deliberately.** The availability toggles below this
/// section apply the instant they are tapped, but these are free-text identity
/// fields: a half-typed phone number auto-committing is both a bad write and a
/// bad feeling, and there is no undo for one. The Save/Discard bar therefore
/// appears only once the form is dirty (owner call, 2026-08-10) — keep the two
/// behaviours distinct rather than unifying them.
class MyIdentitySection extends StatefulWidget {
  const MyIdentitySection({
    required this.email,
    required this.initialPhone,
    required this.initialEmergencyContact,
    required this.initialEmergencyPhone,
    required this.isSaving,
    required this.onSave,
    required this.onChangeEmail,
    super.key,
  });

  final String email;
  final String initialPhone;
  final String initialEmergencyContact;
  final String initialEmergencyPhone;
  final bool isSaving;
  final Future<void> Function(MyIdentityEdit edit) onSave;

  /// Null until Phase B lands the callable's `self` branch, which renders the
  /// email row read-only. It must never become a plain users-doc write.
  final VoidCallback? onChangeEmail;

  @override
  State<MyIdentitySection> createState() => _MyIdentitySectionState();
}

/// What the section hands back on Save.
class MyIdentityEdit {
  const MyIdentityEdit({
    required this.phone,
    required this.emergencyContact,
    required this.emergencyPhone,
  });

  final String phone;
  final String emergencyContact;
  final String emergencyPhone;
}

class _MyIdentitySectionState extends State<MyIdentitySection> {
  late final _phone = TextEditingController(text: widget.initialPhone);
  late final _contact = TextEditingController(
    text: widget.initialEmergencyContact,
  );
  late final _emergencyPhone = TextEditingController(
    text: widget.initialEmergencyPhone,
  );

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    for (final controller in _controllers) {
      controller.addListener(_recomputeDirty);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..removeListener(_recomputeDirty)
        ..dispose();
    }
    super.dispose();
  }

  List<TextEditingController> get _controllers => [
    _phone,
    _contact,
    _emergencyPhone,
  ];

  /// Recomputed against the STORED values rather than tracked as a one-way
  /// flag, so typing a change and typing it back reads as pristine.
  void _recomputeDirty() {
    final dirty =
        _phone.text != widget.initialPhone ||
        _contact.text != widget.initialEmergencyContact ||
        _emergencyPhone.text != widget.initialEmergencyPhone;
    if (dirty != _isDirty) setState(() => _isDirty = dirty);
  }

  void _discard() {
    _phone.text = widget.initialPhone;
    _contact.text = widget.initialEmergencyContact;
    _emergencyPhone.text = widget.initialEmergencyPhone;
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoSectionLabel(l10n.settings_myDetailsIdentity),
        const SizedBox(height: AppSpacing.sp8),
        Text(
          l10n.settings_myDetailsIdentityBlurb,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        SheetPanel(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sp16),
              child: Column(
                children: [
                  LabeledTextField(
                    key: const Key('myPhone'),
                    label: l10n.employees_phone,
                    controller: _phone,
                    keyboard: TextInputType.phone,
                    inputFormatters: const [PhoneInputFormatter()],
                    maxLength: TextLimits.phone,
                  ),
                  const SizedBox(height: AppSpacing.sp16),
                  _EmailRow(
                    email: widget.email,
                    onChangeEmail: widget.onChangeEmail,
                  ),
                  const SizedBox(height: AppSpacing.sp16),
                  LabeledTextField(
                    key: const Key('myEmergencyContact'),
                    label: l10n.employees_emergencyContact,
                    controller: _contact,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    maxLength: TextLimits.employeeEmergencyContact,
                  ),
                  const SizedBox(height: AppSpacing.sp16),
                  LabeledTextField(
                    key: const Key('myEmergencyPhone'),
                    label: l10n.employees_emergencyPhone,
                    controller: _emergencyPhone,
                    keyboard: TextInputType.phone,
                    inputFormatters: const [PhoneInputFormatter()],
                    maxLength: TextLimits.phone,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_isDirty) ...[
          const SizedBox(height: AppSpacing.sp16),
          _SaveBar(
            key: const Key('myIdentitySaveBar'),
            isSaving: widget.isSaving,
            onDiscard: _discard,
            onSave: () => widget.onSave(
              MyIdentityEdit(
                phone: _phone.text,
                emergencyContact: _contact.text,
                emergencyPhone: _emergencyPhone.text,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Read-only until Phase B. The row still shows the address, because "what do I
/// sign in with" is the question this screen is most often opened to answer.
class _EmailRow extends StatelessWidget {
  const _EmailRow({required this.email, required this.onChangeEmail});

  final String email;
  final VoidCallback? onChangeEmail;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                email,
                style: theme.textTheme.bodyLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onChangeEmail != null)
              TextButton(
                key: const Key('myChangeEmail'),
                onPressed: onChangeEmail,
                child: Text(l10n.common_change),
              ),
          ],
        ),
        if (onChangeEmail == null)
          Text(
            l10n.settings_myDetailsEmailReadOnly,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.isSaving,
    required this.onDiscard,
    required this.onSave,
    super.key,
  });

  final bool isSaving;
  final VoidCallback onDiscard;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    // Folds to a column on a small phone or at large text, the same gate every
    // other dense row in the app uses.
    final buttons = [
      TextButton(
        key: const Key('myIdentityDiscard'),
        onPressed: isSaving ? null : onDiscard,
        child: Text(l10n.common_discard),
      ),
      AnimatedLoadingButton(
        key: const Key('myIdentitySave'),
        label: l10n.common_save,
        isLoading: isSaving,
        onPressed: onSave,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sp12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.r12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settings_unsavedChanges,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sp8),
          if (context.isCompact)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                buttons[1],
                const SizedBox(height: AppSpacing.sp8),
                buttons[0],
              ],
            )
          else
            Row(
              children: [
                Expanded(child: buttons[0]),
                const SizedBox(width: AppSpacing.sp8),
                Expanded(child: buttons[1]),
              ],
            ),
        ],
      ),
    );
  }
}
```

Add `import 'package:scheduling/core/layout/breakpoints.dart';` for
`context.isCompact`. If `common_change` does not exist in the ARBs, add it in
both (EN `"Change"`, FR `"Modifier"`) with a `@key` block in EN.

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/settings/widgets/my_identity_section_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Add the small-phone overflow sweep**

Append to the same test file:

```dart
  testWidgets('no overflow at 260px and 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MyIdentitySection(
            email: 'a-very-long-address@example-company.com',
            initialPhone: '(514) 555-0000',
            initialEmergencyContact: 'Ana',
            initialEmergencyPhone: '(514) 555-1111',
            isSaving: false,
            onSave: (_) async {},
            onChangeEmail: null,
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('myPhone')), '(514) 555-9');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
```

Run: `flutter test test/features/settings/widgets/my_identity_section_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/features/settings/widgets/sections/my_identity_section.dart \
        test/features/settings/widgets/my_identity_section_test.dart \
        lib/l10n
git commit -m "feat(settings): My details identity section with an explicit save/discard bar"
```

---

### Task 8: The availability section

**Files:**
- Create: `lib/features/settings/widgets/sections/my_availability_section.dart`
- Test: `test/features/settings/widgets/my_availability_section_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/settings/widgets/my_availability_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/settings/widgets/sections/my_availability_section.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';

Widget _harness(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  const weekdays = [false, true, true, true, true, true, false];

  testWidgets('toggling a day applies immediately', (tester) async {
    List<bool>? applied;
    await tester.pumpWidget(
      _harness(
        MyAvailabilitySection(
          workingDays: weekdays,
          workStartMinutes: 480,
          workEndMinutes: 1020,
          onCall: false,
          conflictDays: const {},
          onChanged: (days, start, end, {required onCall}) =>
              applied = days,
        ),
      ),
    );

    await tester.tap(find.text('M').first);
    await tester.pumpAndSettle();

    expect(applied, isNotNull, reason: 'availability saves on toggle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a conflicting day renders the amber warning', (tester) async {
    await tester.pumpWidget(
      _harness(
        MyAvailabilitySection(
          workingDays: weekdays,
          workStartMinutes: 480,
          workEndMinutes: 1020,
          onCall: false,
          conflictDays: const {1},
          onChanged: (_, _, _, {required onCall}) {},
        ),
      ),
    );

    expect(find.byType(WarningNote), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no warning when nothing conflicts', (tester) async {
    await tester.pumpWidget(
      _harness(
        MyAvailabilitySection(
          workingDays: weekdays,
          workStartMinutes: 480,
          workEndMinutes: 1020,
          onCall: false,
          conflictDays: const {},
          onChanged: (_, _, _, {required onCall}) {},
        ),
      ),
    );

    expect(find.byType(WarningNote), findsNothing);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/settings/widgets/my_availability_section_test.dart`
Expected: FAIL — `my_availability_section.dart` does not exist.

- [ ] **Step 3: Implement the section**

Create `lib/features/settings/widgets/sections/my_availability_section.dart`:

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';
import 'package:scheduling/features/employees/widgets/fields/working_days_picker.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// Signature of an availability edit. Every field travels together so the write
/// is one patch — the rules' `hasOnly` is satisfied by the set, not by which of
/// them actually changed.
typedef AvailabilityChanged =
    void Function(
      List<bool> workingDays,
      int workStartMinutes,
      int workEndMinutes, {
      required bool onCall,
    });

/// Day toggles, hours and on-call — **applied immediately** (spec, P5).
///
/// Deliberately unlike the identity section above it, which is explicitly
/// saved. These are switches: a switch that needs a second confirmation reads
/// as broken, and the write is one allowlisted patch that cannot half-apply.
class MyAvailabilitySection extends StatelessWidget {
  const MyAvailabilitySection({
    required this.workingDays,
    required this.workStartMinutes,
    required this.workEndMinutes,
    required this.onCall,
    required this.conflictDays,
    required this.onChanged,
    super.key,
  });

  final List<bool> workingDays;
  final int workStartMinutes;
  final int workEndMinutes;
  final bool onCall;

  /// Sunday-indexed weekdays being switched off that still hold booked work.
  final Set<int> conflictDays;
  final AvailabilityChanged onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoSectionLabel(l10n.settings_myAvailability),
        const SizedBox(height: AppSpacing.sp8),
        Text(
          l10n.settings_myAvailabilityBlurb,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        SheetPanel(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sp16),
              child: WorkingDaysPicker(
                workingDays: workingDays,
                onChanged: (next) => onChanged(
                  next,
                  workStartMinutes,
                  workEndMinutes,
                  onCall: onCall,
                ),
              ),
            ),
            SheetFieldRow(
              label: l10n.employees_startsAt,
              value: materialL10n.formatTimeOfDay(
                minutesToTimeOfDay(workStartMinutes),
              ),
              onTap: () => _pickTime(
                context,
                initial: workStartMinutes,
                onPicked: (minutes) => onChanged(
                  workingDays,
                  minutes,
                  workEndMinutes,
                  onCall: onCall,
                ),
              ),
            ),
            SheetFieldRow(
              label: l10n.employees_endsAt,
              value: materialL10n.formatTimeOfDay(
                minutesToTimeOfDay(workEndMinutes),
              ),
              onTap: () => _pickTime(
                context,
                initial: workEndMinutes,
                onPicked: (minutes) => onChanged(
                  workingDays,
                  workStartMinutes,
                  minutes,
                  onCall: onCall,
                ),
              ),
            ),
            SwitchListTile.adaptive(
              key: const Key('myOnCall'),
              title: Text(l10n.employees_onCall),
              value: onCall,
              activeTrackColor: theme.colorScheme.primary,
              onChanged: (value) => onChanged(
                workingDays,
                workStartMinutes,
                workEndMinutes,
                onCall: value,
              ),
            ),
          ],
        ),
        if (conflictDays.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sp12),
          WarningNote(
            message: l10n.settings_availabilityConflict(
              _joinDayNames(context, conflictDays),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickTime(
    BuildContext context, {
    required int initial,
    required ValueChanged<int> onPicked,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: minutesToTimeOfDay(initial),
    );
    if (picked == null) return;
    onPicked(picked.hour * 60 + picked.minute);
  }

  /// Sunday-indexed labels, UNROTATED — the set holds stored indices, and
  /// `weekdayAbbreviationsForLocale` is indexed the same way. Passing a
  /// display-ordered list here silently names the wrong day.
  String _joinDayNames(BuildContext context, Set<int> days) {
    final locale = Localizations.localeOf(context).toString();
    final labels = weekdayAbbreviationsForLocale(locale);
    final ordered = days.toList()..sort();
    return ordered.map((index) => labels[index]).join(', ');
  }
}
```

Check the real names of `SheetFieldRow`'s parameters, `minutesToTimeOfDay`,
`weekdayAbbreviationsForLocale` and `WarningNote`'s message parameter against
`edit_person_sheet.dart:487-520` and adjust — that sheet is the working
reference for this exact control group.

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/settings/widgets/my_availability_section_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/settings/widgets/sections/my_availability_section.dart \
        test/features/settings/widgets/my_availability_section_test.dart
git commit -m "feat(settings): My availability section with the booked-work warning"
```

---

### Task 9: The admin-only SCHEDULING section

**Files:**
- Create: `lib/features/settings/widgets/sections/my_scheduling_section.dart`
- Test: `test/features/settings/widgets/my_scheduling_section_test.dart`

Scoped to `maxJobsPerDay` — see planning decision 4. It is written through the
**admin** rules branch (`isAdmin()`), not the self allowlist, which is why the
section is hidden entirely for a technician rather than shown disabled: an
employee has no path that could ever make it succeed.

- [ ] **Step 1: Write the failing test**

Create `test/features/settings/widgets/my_scheduling_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/settings/widgets/sections/my_scheduling_section.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _harness(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('an admin sees the editable max-jobs row', (tester) async {
    await tester.pumpWidget(
      _harness(
        MySchedulingSection(
          isAdmin: true,
          maxJobsPerDay: 5,
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.byKey(const Key('myMaxJobsPerDay')), findsOneWidget);
  });

  testWidgets('a technician sees nothing at all', (tester) async {
    // Hidden, not disabled: the rules give an employee no path that could
    // succeed here, so a greyed control would only advertise a dead end.
    await tester.pumpWidget(
      _harness(
        MySchedulingSection(
          isAdmin: false,
          maxJobsPerDay: 5,
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.byKey(const Key('myMaxJobsPerDay')), findsNothing);
    expect(find.text('SCHEDULING'), findsNothing);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/settings/widgets/my_scheduling_section_test.dart`
Expected: FAIL — `my_scheduling_section.dart` does not exist.

- [ ] **Step 3: Implement the section**

Create `lib/features/settings/widgets/sections/my_scheduling_section.dart`:

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// Scheduling limits, admin-only.
///
/// `maxJobsPerDay` is NOT on the self-service rules allowlist, so this writes
/// through the admin branch of `allow update`. That is also why a technician
/// gets nothing rather than a disabled control — there is no path here that
/// could ever succeed for them, and an inert row would just advertise it.
///
/// Deliberately scoped to this one field: role, job title and crew colour stay
/// on the admin Team sheet. An admin editing their own role from a
/// self-service screen is a privilege-escalation shape with no product reason
/// to exist.
class MySchedulingSection extends StatelessWidget {
  const MySchedulingSection({
    required this.isAdmin,
    required this.maxJobsPerDay,
    required this.onChanged,
    super.key,
  });

  final bool isAdmin;
  final int maxJobsPerDay;
  final ValueChanged<int> onChanged;

  static const _max = 50;

  @override
  Widget build(BuildContext context) {
    if (!isAdmin) return const SizedBox.shrink();
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoSectionLabel(l10n.settings_myScheduling),
        const SizedBox(height: AppSpacing.sp16),
        SheetPanel(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sp16),
              child: Row(
                children: [
                  Expanded(child: Text(l10n.employees_maxJobsPerDay)),
                  IconButton(
                    onPressed: maxJobsPerDay > 0
                        ? () => onChanged(maxJobsPerDay - 1)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                  Text(
                    key: const Key('myMaxJobsPerDay'),
                    '$maxJobsPerDay',
                    style: Theme.of(context).monoType.data,
                  ),
                  IconButton(
                    onPressed: maxJobsPerDay < _max
                        ? () => onChanged(maxJobsPerDay + 1)
                        : null,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
```

`_max` is 50 to match `isValidUserData`'s cap in `firestore.rules:218-221` — a
looser client cap would let a value through that the rules reject with an
opaque `permission-denied`.

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/settings/widgets/my_scheduling_section_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/settings/widgets/sections/my_scheduling_section.dart \
        test/features/settings/widgets/my_scheduling_section_test.dart
git commit -m "feat(settings): admin-only scheduling section on My details"
```

---

### Task 10: Wire the sections into `MyDetailsScreen`

**Files:**
- Modify: `lib/features/settings/screens/my_details_screen.dart` (whole file)
- Test: `test/features/settings/screens/my_details_screen_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/features/settings/screens/my_details_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/settings/screens/my_details_screen.dart';
import 'package:scheduling/features/settings/widgets/sections/my_availability_section.dart';
import 'package:scheduling/features/settings/widgets/sections/my_identity_section.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('renders the identity and availability sections', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: const [
          // Override activeUserIdentityProvider, allUsersStreamProvider and
          // emergencyContactProvider here — see
          // test/features/settings/screens/ for the existing settings harness.
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MyDetailsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MyIdentitySection), findsOneWidget);
    expect(find.byType(MyAvailabilitySection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

Fill the `overrides` list from the existing settings-screen harness in
`test/features/settings/screens/` — copy its provider overrides rather than
inventing new ones.

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/settings/screens/my_details_screen_test.dart`
Expected: FAIL — `MyIdentitySection` is not in the tree.

- [ ] **Step 3: Rewrite the screen body**

In `lib/features/settings/screens/my_details_screen.dart`, replace `_body` and
the state fields. The existing `_save` stays as the **emergency-contact** half
and gains the users-doc half; the availability handler is separate because it
writes immediately.

```dart
  /// Identity save — emergency contact (subcollection) AND phone (users doc).
  /// Two stores, so both are awaited before the success notice.
  Future<void> _saveIdentity(String docId, MyIdentityEdit edit) async {
    if (_isSaving) return;
    FocusScope.of(context).unfocus();

    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);

    if (guardedOffline(context, ref, intro: l10n.error_introSaveMyDetails)) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final repository = ref.read(employeesRepositoryProvider);
      await repository.saveEmergencyContact(
        docId,
        EmergencyContact(
          contact: edit.emergencyContact,
          phone: edit.emergencyPhone,
        ),
      );
      await repository.updateSelfDetails(
        docId: docId,
        phone: edit.phone,
        workingDays: _workingDays,
        workStartMinutes: _workStartMinutes,
        workEndMinutes: _workEndMinutes,
        onCall: _onCall,
      );
      if (!mounted) return;
      notices.success(l10n.common_changesSaved);
    } catch (error, stackTrace) {
      ref
          .read(loggerProvider)
          .warn('ME-SAVE identity save failed', error, stackTrace);
      if (!mounted) return;
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introSaveMyDetails,
          error: error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Availability applies immediately (spec, P5). Optimistic: the local state
  /// moves first so the switch does not lag a Firestore round trip, and a
  /// failure rolls it back and says so.
  Future<void> _applyAvailability(
    String docId,
    List<bool> days,
    int start,
    int end, {
    required bool onCall,
  }) async {
    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);

    final previous = (
      days: _workingDays,
      start: _workStartMinutes,
      end: _workEndMinutes,
      onCall: _onCall,
    );
    setState(() {
      _workingDays = days;
      _workStartMinutes = start;
      _workEndMinutes = end;
      _onCall = onCall;
    });

    if (guardedOffline(context, ref, intro: l10n.error_introSaveAvailability)) {
      setState(() {
        _workingDays = previous.days;
        _workStartMinutes = previous.start;
        _workEndMinutes = previous.end;
        _onCall = previous.onCall;
      });
      return;
    }

    try {
      await ref
          .read(employeesRepositoryProvider)
          .updateSelfDetails(
            docId: docId,
            phone: _storedPhone,
            workingDays: days,
            workStartMinutes: start,
            workEndMinutes: end,
            onCall: onCall,
          );
    } catch (error, stackTrace) {
      ref
          .read(loggerProvider)
          .warn('ME-SAVE availability failed', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _workingDays = previous.days;
        _workStartMinutes = previous.start;
        _workEndMinutes = previous.end;
        _onCall = previous.onCall;
      });
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introSaveAvailability,
          error: error,
        ),
      );
    }
  }
```

Note `_storedPhone`: the availability write must send the **stored** phone, not
whatever is in the identity controller. Sending the in-progress text would make
an availability toggle silently commit a half-typed phone number — exactly the
auto-save the identity bar exists to prevent. Seed `_storedPhone` in `_seed`
alongside the availability fields, from `myEmployeeRecordProvider`.

Add these state fields beside `_seeded` / `_isSaving`:

```dart
  List<bool> _workingDays = kDefaultWorkingDays;
  int _workStartMinutes = kDefaultWorkStartMinutes;
  int _workEndMinutes = kDefaultWorkEndMinutes;
  bool _onCall = false;
  String _storedPhone = '';
```

And compose the body:

```dart
        ListView(
          padding: const EdgeInsets.all(AppSpacing.sp16),
          children: [
            MyIdentitySection(
              email: record.email,
              initialPhone: record.phone,
              initialEmergencyContact: contact.contact,
              initialEmergencyPhone: contact.phone,
              isSaving: _isSaving,
              onSave: (edit) => _saveIdentity(docId, edit),
              // Phase B replaces this null with the change-email dialog.
              onChangeEmail: null,
            ),
            const SizedBox(height: AppSpacing.sp24),
            MyAvailabilitySection(
              workingDays: _workingDays,
              workStartMinutes: _workStartMinutes,
              workEndMinutes: _workEndMinutes,
              onCall: _onCall,
              conflictDays: ref.watch(
                myAvailabilityConflictProvider(
                  AvailabilityChange(
                    previousWorkingDays: record.workingDays,
                    nextWorkingDays: _workingDays,
                  ),
                ),
              ),
              onChanged: (days, start, end, {required onCall}) =>
                  _applyAvailability(docId, days, start, end, onCall: onCall),
            ),
            const SizedBox(height: AppSpacing.sp24),
            MySchedulingSection(
              isAdmin: isAdmin,
              maxJobsPerDay: record.maxJobsPerDay,
              onChanged: (value) => _saveMaxJobs(docId, record, value),
            ),
            const SizedBox(height: AppSpacing.sp32),
          ],
        )
```

`_saveMaxJobs` goes through the existing admin path
(`EmployeesRepository.updateEmployee` with `record.copyWith(maxJobsPerDay:)`),
because that field is not on the self allowlist.

- [ ] **Step 4: Run the test and the whole settings group**

Run: `flutter test test/features/settings/`
Expected: PASS. The existing `settings_screen_mobile_test.dart` and
`settings_landscape_mobile_test.dart` must stay green.

- [ ] **Step 5: Run the analyzer**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/settings test/features/settings
git commit -m "feat(settings): My details hosts identity, availability and scheduling"
```

---

### Task 11: Phase A verification and rules deploy

- [ ] **Step 1: Full suite**

Run: `flutter test`
Expected: all green. Note the count; the baseline before this plan was 1713.

- [ ] **Step 2: Analyzer**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: BOM scan**

Run: `git diff --name-only main...HEAD -- '*.dart' | while read f; do head -c 3 "$f" | od -An -tx1 | grep -q 'ef bb bf' && echo "BOM: $f"; done`
Expected: no output.

- [ ] **Step 4: Deploy the rules**

Rules must be live **before** an app build carrying the self-service UI ships,
or every self save fails `permission-denied`. Rules-only deploys are safe on
their own — the new clause only widens `allow update`.

Run: `firebase deploy --only firestore:rules`
Expected: `Deploy complete!`

Never pass `--force` (it deletes prod TTL policies missing from
`firestore.indexes.json`).

- [ ] **Step 5: Verify on a device**

`flutter run` on the iPhone, sign in as a **technician** (not an admin), open
Settings › My details and confirm:
- editing the phone shows the Save/Discard bar, and Discard restores it
- Save writes and the notice appears
- toggling a working day writes with no bar
- turning off a day that holds a job shows the amber note
- the SCHEDULING section is absent

Widget errors go to Crashlytics, not stdout — if the screen misbehaves
silently, temporarily add `FlutterError.dumpErrorToConsole(details)` to
`FlutterError.onError` in `main()`.

- [ ] **Step 6: Commit any device fixes and push**

```bash
git push origin redesgin
```

---

# PHASE B — self-service email

Everything here is gated on Phase A being deployed and verified.

### Task 12: `sendToActiveAdmins` fan-out

**Files:**
- Modify: `functions/notification_utils.js` (add beside `sendToEmployee`)
- Test: `functions/__tests__/notification_admin_fanout.test.js` (create)

This is shared work: P6's time-off requests need the same fan-out, which is why
it lands as its own helper rather than inline in `employee_accounts.js`.

- [ ] **Step 1: Write the failing test**

Create `functions/__tests__/notification_admin_fanout.test.js`:

```js
const {sendToActiveAdmins} = require("../notification_utils");

function fakeDb(users) {
  return {
    collection: () => ({
      where: () => ({
        where: () => ({
          get: async () => ({docs: users}),
        }),
      }),
    }),
  };
}

function userDoc(id) {
  return {id, data: () => ({role: "admin", status: "active"})};
}

describe("sendToActiveAdmins", () => {
  test("sends one message per active admin", async () => {
    const sent = [];
    const deps = {
      db: fakeDb([userDoc("a1"), userDoc("a2")]),
      messaging: {},
      logger: {warn: () => {}},
    };

    await sendToActiveAdmins(
        deps,
        {kind: "selfEmailChanged"},
        () => ({title: "t", body: "b"}),
        {sendToEmployee: async (_d, id) => {
          sent.push(id);
          return 1;
        }},
    );

    expect(sent).toEqual(["a1", "a2"]);
  });

  test("excludes one doc id when asked", async () => {
    // The person who made the change does not need to be told about it.
    const sent = [];
    const deps = {
      db: fakeDb([userDoc("a1"), userDoc("a2")]),
      messaging: {},
      logger: {warn: () => {}},
    };

    await sendToActiveAdmins(
        deps,
        {kind: "selfEmailChanged"},
        () => ({title: "t", body: "b"}),
        {
          excludeDocId: "a1",
          sendToEmployee: async (_d, id) => {
            sent.push(id);
            return 1;
          },
        },
    );

    expect(sent).toEqual(["a2"]);
  });

  test("a throw from one recipient does not stop the rest", async () => {
    // Best-effort: the change is already committed, so a push failure must
    // never surface as a failed operation.
    const sent = [];
    const deps = {
      db: fakeDb([userDoc("a1"), userDoc("a2")]),
      messaging: {},
      logger: {warn: () => {}},
    };

    await expect(sendToActiveAdmins(
        deps,
        {kind: "selfEmailChanged"},
        () => ({title: "t", body: "b"}),
        {sendToEmployee: async (_d, id) => {
          if (id === "a1") throw new Error("boom");
          sent.push(id);
          return 1;
        }},
    )).resolves.toBeUndefined();

    expect(sent).toEqual(["a2"]);
  });
});
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd functions && npx jest __tests__/notification_admin_fanout.test.js`
Expected: FAIL — `sendToActiveAdmins is not a function`.

- [ ] **Step 3: Implement the helper**

Add to `functions/notification_utils.js`, after `sendToEmployee`:

```js
/**
 * Pushes one localized message to every ACTIVE ADMIN.
 *
 * Shared fan-out: P5's self-service email notice needs it, and P6's time-off
 * requests will too — build it once rather than inlining the query at each
 * call site.
 *
 * Best-effort in the same sense as `notifyEmailChanged`: whatever prompted the
 * notice has already committed, so a push failure must never surface as a
 * failed operation. Each recipient is isolated, so one bad token cannot
 * suppress the rest.
 *
 * @param {!Object} deps `{db, messaging, logger}`.
 * @param {!Object} data Data payload (string values); `kind` etc.
 * @param {function(string): {title: string, body: string}} buildMsg Localized
 *   message builder keyed by 'en'|'fr'.
 * @param {{excludeDocId: (string|undefined),
 *          sendToEmployee: (!Function|undefined)}=} opts `excludeDocId` skips
 *   the person who caused the notice; `sendToEmployee` is injectable for tests.
 * @return {!Promise<void>}
 */
async function sendToActiveAdmins(deps, data, buildMsg, opts) {
  const {db, logger} = deps;
  const options = opts || {};
  const send = options.sendToEmployee || sendToEmployee;
  try {
    const snap = await db.collection("users")
        .where("role", "==", "admin")
        .where("status", "==", "active")
        .get();
    // The query constrains both fields, which is what the /users read rule
    // needs — but this runs on the Admin SDK, which bypasses rules anyway.
    await Promise.all(snap.docs
        .filter((doc) => doc.id !== options.excludeDocId)
        .map((doc) => send(
            deps, doc.id, data, buildMsg, ADMIN_RECIPIENT_ROLES,
        ).catch((e) => {
          if (logger) {
            logger.warn("sendToActiveAdmins: recipient failed",
                {docId: doc.id, err: String(e)});
          }
        })));
  } catch (e) {
    if (logger) {
      logger.warn("sendToActiveAdmins: fan-out failed", {err: String(e)});
    }
  }
}
```

Add the role set beside the existing ones near the top of the file:

```js
// Admins only. `sendToEmployee` re-checks the recipient's role, and the
// existing sets are employee-flavoured — passing one of those would make the
// fan-out silently deliver nothing.
const ADMIN_RECIPIENT_ROLES = new Set(["admin"]);
```

Export both from `module.exports`.

- [ ] **Step 4: Run the test**

Run: `cd functions && npx jest __tests__/notification_admin_fanout.test.js`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint**

Run: `cd functions && npm run lint`
Expected: clean (Google ESLint, 80-char limit).

- [ ] **Step 6: Commit**

```bash
git add functions/notification_utils.js functions/__tests__/notification_admin_fanout.test.js
git commit -m "feat(functions): shared active-admins push fan-out"
```

---

### Task 13: The `self` branch on `changeEmployeeEmail`

**Files:**
- Modify: `functions/employee_accounts.js:354-433`
- Modify: `functions/notification_messages.js` (add `buildSelfEmailChangedMessage`)
- Test: `functions/__tests__/employee_accounts_self_email.test.js` (create)

- [ ] **Step 1: Write the failing test**

Create `functions/__tests__/employee_accounts_self_email.test.js`:

```js
const {resolveEmailChangeCaller} = require("../employee_accounts");

describe("resolveEmailChangeCaller", () => {
  const adminBridge = {role: "admin", status: "active", docId: "adm"};
  const selfBridge = {role: "employee", status: "active", docId: "u1"};

  test("an active admin may change any doc", async () => {
    const result = await resolveEmailChangeCaller(adminBridge, "u1");
    expect(result).toEqual({isSelf: false, callerDocId: "adm"});
  });

  test("an employee may change their OWN doc", async () => {
    const result = await resolveEmailChangeCaller(selfBridge, "u1");
    expect(result).toEqual({isSelf: true, callerDocId: "u1"});
  });

  test("an employee may not change someone else's doc", async () => {
    // This is the whole point of the branch: widening the callable to
    // non-admins must not widen WHICH doc they can reach.
    await expect(resolveEmailChangeCaller(selfBridge, "u2"))
        .rejects.toThrow(/not-admin|permission/);
  });

  test("a DISABLED employee may not change their own doc", async () => {
    await expect(resolveEmailChangeCaller(
        {role: "employee", status: "disabled", docId: "u1"}, "u1",
    )).rejects.toThrow(/not-admin|permission/);
  });

  test("an INVITED employee may not change their own doc", async () => {
    // Mid-setup: completeEmployeeSetup owns that doc, and the person is still
    // on the shared starting password.
    await expect(resolveEmailChangeCaller(
        {role: "employee", status: "invited", docId: "u1"}, "u1",
    )).rejects.toThrow(/not-admin|permission/);
  });

  test("a missing bridge doc is refused", async () => {
    await expect(resolveEmailChangeCaller(null, "u1"))
        .rejects.toThrow(/not-admin|permission/);
  });
});
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd functions && npx jest __tests__/employee_accounts_self_email.test.js`
Expected: FAIL — `resolveEmailChangeCaller is not a function`.

- [ ] **Step 3: Add the resolver**

Add to `functions/employee_accounts.js`, above `changeEmployeeEmail`:

```js
/**
 * Decides whether this caller may move [docId]'s email, and how.
 *
 * Pure over the caller's `usersByUid` bridge data so the guard is testable
 * without Firestore. Two ways through and no third: an ACTIVE ADMIN may move
 * any doc, and an ACTIVE EMPLOYEE may move their OWN. Everything else — a
 * disabled account, an invited account mid-setup, a missing bridge doc, an
 * employee naming somebody else's doc — is refused.
 *
 * Widening this callable past admins must never widen WHICH doc a caller can
 * reach; that is the failure this function exists to make hard to write.
 *
 * @param {?Object} bridge The caller's `usersByUid/{uid}` data, or null.
 * @param {string} docId The users-doc id being changed.
 * @return {!Promise<{isSelf: boolean, callerDocId: string}>}
 */
async function resolveEmailChangeCaller(bridge, docId) {
  const data = bridge || null;
  if (!data || data.status !== "active") {
    throw new HttpsError("permission-denied", "not-admin");
  }
  if (data.role === "admin") {
    return {isSelf: false, callerDocId: data.docId || ""};
  }
  if (data.docId === docId) {
    return {isSelf: true, callerDocId: docId};
  }
  throw new HttpsError("permission-denied", "not-admin");
}
```

- [ ] **Step 4: Run the resolver test**

Run: `cd functions && npx jest __tests__/employee_accounts_self_email.test.js`
Expected: PASS (6 tests) once `resolveEmailChangeCaller` is added to
`module.exports`.

- [ ] **Step 5: Wire it into the callable**

In `changeEmployeeEmail`, replace `await assertAdmin(req.auth.uid);` (line 358)
with the bridge read plus the resolver, keeping the guard order **auth →
identity → payload → rate limit → work**:

```js
  const db = getFirestore();
  const bridgeSnap = await db.collection("usersByUid").doc(req.auth.uid).get();
  assertPayloadShape(req.data, new Set(["docId", "email"]));
  const docId = requireString(req.data, "docId", 128);
  if (docId.includes("/")) {
    throw new HttpsError("invalid-argument", "invalid-docId");
  }
  const email = requireString(req.data, "email", 254).toLowerCase();
  // Identity guard sits ABOVE the limiter so a non-entitled caller cannot burn
  // a legitimate one's slots; the payload is validated above it so a burst of
  // malformed submissions cannot either.
  const {isSelf, callerDocId} = await resolveEmailChangeCaller(
      bridgeSnap.exists ? bridgeSnap.data() : null, docId);
  // Same per-caller budget either way: this rewrites a sign-in identity.
  await enforceDurableRateLimit(
      "changeEmployeeEmail", req.auth.uid, CREATE_RATE_MAX,
      CREATE_RATE_WINDOW_MS);

  const auth = getAuth();
```

Delete the now-duplicated `const db = getFirestore();` / `const auth =
getAuth();` pair and the old `assertPayloadShape`/`requireString` block further
down, so each runs exactly once.

- [ ] **Step 6: Swap the notification by caller**

Replace the `await notifyEmailChanged(...)` call (line 430) with:

```js
  // Who needs telling depends on who did it. An ADMIN edit surprises the
  // employee, so the employee is told. A SELF edit surprises nobody who made
  // it — the admins are the ones who need to know a sign-in identity moved.
  if (isSelf) {
    await notifyAdminsOfSelfEmailChange(
        {db, messaging: getMessaging(), logger}, callerDocId, docId);
  } else {
    await notifyEmailChanged(
        {db, messaging: getMessaging(), logger}, docId, email);
  }
  return {ok: true};
```

And add the notifier beside `notifyEmailChanged`:

```js
/**
 * Tells the active admins that someone changed their OWN sign-in address.
 *
 * Deliberately does NOT name the new address: this goes to every admin's Lock
 * Screen, and an email is PII. The admin opens the roster to see it.
 *
 * Best-effort and after the commit, exactly like `notifyEmailChanged`.
 *
 * @param {!Object} deps `{db, messaging, logger}`.
 * @param {string} callerDocId The person who made the change (excluded).
 * @param {string} docId users doc id whose email moved.
 * @return {!Promise<void>}
 */
async function notifyAdminsOfSelfEmailChange(deps, callerDocId, docId) {
  try {
    const snap = await deps.db.collection("users").doc(docId).get();
    const name = (snap.exists && (snap.data() || {}).name) || "";
    await sendToActiveAdmins(
        deps,
        {kind: "selfEmailChanged", docId},
        (locale) => buildSelfEmailChangedMessage(name, locale),
        {excludeDocId: callerDocId},
    );
  } catch (e) {
    logger.warn("changeEmployeeEmail: admin notify failed",
        {docId, err: String(e)});
  }
}
```

Import `sendToActiveAdmins` from `./notification_utils` and
`buildSelfEmailChangedMessage` from `./notification_messages`, and export
`resolveEmailChangeCaller` + `notifyAdminsOfSelfEmailChange`.

- [ ] **Step 7: Add the message builder**

In `functions/notification_messages.js`, beside `buildEmailChangedMessage`:

```js
/**
 * Tells an admin that a team member moved their own sign-in address.
 *
 * Carries the NAME, never the address — this lands on every admin's Lock
 * Screen and an email is PII.
 *
 * @param {string} name The person's display name.
 * @param {string} locale 'en' or 'fr'.
 * @return {{title: string, body: string}}
 */
function buildSelfEmailChangedMessage(name, locale) {
  const who = String(name || "").trim();
  if (locale === "fr") {
    return {
      title: "Courriel de connexion modifié",
      body: who ?
        `${who} a modifié son adresse de connexion.` :
        "Un membre de l'équipe a modifié son adresse de connexion.",
    };
  }
  return {
    title: "Sign-in email changed",
    body: who ?
      `${who} changed their sign-in address.` :
      "A team member changed their sign-in address.",
  };
}
```

Add it to `module.exports`.

- [ ] **Step 8: Run the functions suite**

Run: `cd functions && npx jest`
Expected: all green. Baseline before this plan was 820.

- [ ] **Step 9: Lint**

Run: `cd functions && npm run lint`
Expected: clean.

- [ ] **Step 10: Commit**

```bash
git add functions
git commit -m "feat(functions): self branch on changeEmployeeEmail with an admin notice"
```

---

### Task 14: The change-email dialog

**Files:**
- Create: `lib/features/settings/services/self_email_service.dart`
- Create: `lib/features/settings/widgets/dialogs/change_email_dialog.dart`
- Modify: `lib/features/settings/screens/my_details_screen.dart` (pass
  `onChangeEmail`)
- Test: `test/features/settings/widgets/change_email_dialog_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/settings/widgets/change_email_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/settings/widgets/dialogs/change_email_dialog.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _harness(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('confirm is disabled until both addresses match', (tester) async {
    // The Admin SDK sets the address with no proof of control, so a typo locks
    // the person out until an admin undoes it. Typing it twice is the guard.
    await tester.pumpWidget(
      _harness(
        ChangeEmailDialogBody(
          currentEmail: 'theo@example.com',
          isBusy: false,
          onSubmit: (_, _) async {},
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('newEmail')),
      'theo.new@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('confirmEmail')),
      'theo.nwe@example.com',
    );
    await tester.enterText(find.byKey(const Key('reauthPassword')), 'hunter22');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('confirmEmailChange')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('confirm enables once both match and a password is given', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        ChangeEmailDialogBody(
          currentEmail: 'theo@example.com',
          isBusy: false,
          onSubmit: (_, _) async {},
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('newEmail')),
      'theo.new@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('confirmEmail')),
      'theo.new@example.com',
    );
    await tester.enterText(find.byKey(const Key('reauthPassword')), 'hunter22');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('confirmEmailChange')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('the password field opts out of IME personalized learning', (
    tester,
  ) async {
    // Every password field here has a Show/Hide toggle, so obscureText is not
    // a safe proxy — a third-party keyboard would retain and cloud-sync the
    // plain text the instant it is revealed.
    await tester.pumpWidget(
      _harness(
        ChangeEmailDialogBody(
          currentEmail: 'theo@example.com',
          isBusy: false,
          onSubmit: (_, _) async {},
        ),
      ),
    );

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('reauthPassword')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('addresses are compared case- and whitespace-insensitively', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        ChangeEmailDialogBody(
          currentEmail: 'theo@example.com',
          isBusy: false,
          onSubmit: (_, _) async {},
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('newEmail')),
      ' Theo.New@Example.com ',
    );
    await tester.enterText(
      find.byKey(const Key('confirmEmail')),
      'theo.new@example.com',
    );
    await tester.enterText(find.byKey(const Key('reauthPassword')), 'hunter22');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('confirmEmailChange')),
    );
    expect(button.onPressed, isNotNull);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/settings/widgets/change_email_dialog_test.dart`
Expected: FAIL — `change_email_dialog.dart` does not exist.

- [ ] **Step 3: Implement the dialog body**

Create `lib/features/settings/widgets/dialogs/change_email_dialog.dart`. The
body is a separate public widget from the dialog shell so the test above can
pump it without a route.

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';

/// Confirm-twice + re-authenticate, before a sign-in identity moves.
///
/// Two guards, both load-bearing:
///
/// * **Twice.** `changeEmployeeEmail` sets the address through the Admin SDK
///   with no proof the person controls it, so a typo means they cannot sign in.
///   An admin can undo it with the same callable, which bounds the blast
///   radius — but the sheet should not lean on that.
/// * **Re-auth.** An unattended unlocked phone changing the sign-in address is
///   the account-takeover primitive. Reuses
///   `AccountDeletionService.reauthenticateWithPassword`.
class ChangeEmailDialogBody extends StatefulWidget {
  const ChangeEmailDialogBody({
    required this.currentEmail,
    required this.isBusy,
    required this.onSubmit,
    super.key,
  });

  final String currentEmail;
  final bool isBusy;
  final Future<void> Function(String email, String password) onSubmit;

  @override
  State<ChangeEmailDialogBody> createState() => _ChangeEmailDialogBodyState();
}

class _ChangeEmailDialogBodyState extends State<ChangeEmailDialogBody> {
  final _email = TextEditingController();
  final _confirm = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    for (final c in [_email, _confirm, _password]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_email, _confirm, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Normalized on both sides — the callable lowercases anyway, so a case-only
  /// difference is not a typo and must not block the button.
  String _norm(String value) => value.trim().toLowerCase();

  bool get _canSubmit =>
      _norm(_email.text).isNotEmpty &&
      _norm(_email.text) == _norm(_confirm.text) &&
      _norm(_email.text) != _norm(widget.currentEmail) &&
      _password.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabeledTextField(
          key: const Key('newEmail'),
          label: l10n.auth_email,
          controller: _email,
          keyboard: TextInputType.emailAddress,
          maxLength: TextLimits.authEmail,
        ),
        const SizedBox(height: AppSpacing.sp12),
        LabeledTextField(
          key: const Key('confirmEmail'),
          label: l10n.settings_confirmNewEmail,
          controller: _confirm,
          keyboard: TextInputType.emailAddress,
          maxLength: TextLimits.authEmail,
        ),
        const SizedBox(height: AppSpacing.sp12),
        LabeledTextField(
          key: const Key('reauthPassword'),
          label: l10n.auth_password,
          controller: _password,
          obscureText: _obscure,
          // Unconditional, beside obscureText and never in place of it: the
          // Show/Hide toggle means this field renders plain text on demand.
          enableIMEPersonalizedLearning: false,
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_rounded,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        AnimatedLoadingButton(
          key: const Key('confirmEmailChange'),
          label: l10n.common_save,
          isLoading: widget.isBusy,
          onPressed: _canSubmit
              ? () => widget.onSubmit(_norm(_email.text), _password.text)
              : null,
        ),
      ],
    );
  }
}
```

If `AnimatedLoadingButton` does not render a `FilledButton` the test can read,
change the test's `tester.widget<FilledButton>` to match what it actually
builds — the assertion that matters is `onPressed == null` while invalid.

`settings_confirmNewEmail` is a new key: add it to both ARBs (EN
`"Confirm new email"`, FR `"Confirmer le nouveau courriel"`) with an EN `@key`
block.

- [ ] **Step 4: Run the test**

Run: `flutter test test/features/settings/widgets/change_email_dialog_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Implement the service**

Create `lib/features/settings/services/self_email_service.dart`:

```dart
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/account_deletion_service.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';

final selfEmailServiceProvider = Provider<SelfEmailService>(
  (ref) => SelfEmailService(
    deletionService: ref.watch(accountDeletionServiceProvider),
    logger: ref.watch(loggerProvider),
  ),
);

/// Moves the signed-in person's OWN sign-in address.
///
/// Re-auth FIRST, then the callable. Reversing them would let an unattended
/// unlocked phone move the address and only then discover it could not prove
/// who it was — by which point Auth has already changed.
class SelfEmailService {
  SelfEmailService({
    required AccountDeletionService deletionService,
    required AppLogger logger,
    FirebaseFunctions? functions,
  }) : _deletionService = deletionService,
       _logger = logger,
       _functions = functions ?? FirebaseFunctions.instance;

  final AccountDeletionService _deletionService;
  final AppLogger _logger;
  final FirebaseFunctions _functions;

  Future<void> changeOwnEmail({
    required String docId,
    required String email,
    required String password,
  }) async {
    await _deletionService.reauthenticateWithPassword(password);
    try {
      await _functions
          .httpsCallable(
            'changeEmployeeEmail',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
          )
          .call<dynamic>({'docId': docId, 'email': email});
    } on FirebaseFunctionsException catch (e, st) {
      if (e.message == 'email-exists') {
        throw const EmployeesFailureEmailAlreadyExists();
      }
      _logger.warn('ME-EMAIL changeEmployeeEmail failed', e, st);
      throw const AuthFailureUnknown();
    }
  }
}
```

- [ ] **Step 6: Wire it into the screen**

In `my_details_screen.dart`, replace `onChangeEmail: null` with a handler that
opens the dialog and, on success, shows `common_changesSaved`. Log failures
under `ME-EMAIL` and surface them with `composeErrorNotice(intro:
l10n.error_introChangeEmail)` — add that ARB key in both files.

- [ ] **Step 7: Run the settings suite and the analyzer**

Run: `flutter test test/features/settings/ && flutter analyze`
Expected: PASS and `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add lib/features/settings lib/l10n test/features/settings
git commit -m "feat(settings): self-service sign-in email change with reauth"
```

---

### Task 15: Phase B deploy and verification

- [ ] **Step 1: Full suites**

Run: `flutter test` then `cd functions && npx jest && npm run lint`
Expected: all green.

- [ ] **Step 2: Read the deploy runbook**

Read `docs/DEPLOYMENT.md`. This changes a callable's guard set, so the
old-build-compatibility check applies: a shipped 1.4x app calls
`changeEmployeeEmail` with the same payload and an admin caller, which the new
resolver still accepts — confirm that before deploying.

- [ ] **Step 3: Deploy backend before the app build**

Run: `firebase deploy --only functions,firestore:rules`
Expected: `Deploy complete!`, 25 functions. Never `--force`.

- [ ] **Step 4: Verify on a device**

As a technician: change your own email, confirm you must type it twice and give
your password, confirm you can then sign in with the new address, and confirm
an admin device receives the notice. As an admin: change a *different*
employee's email from the Team sheet and confirm that path still notifies the
employee, not the admins.

- [ ] **Step 5: Push**

```bash
git push origin redesgin
```

---

# PHASE C — time-to-leave alerts toggle

Parked from P4 into P5. Separable: nothing in Phases A or B depends on it.

### Task 16: The `travelAlertsEnabled` flag

**Files:**
- Modify: `firestore.rules` (`isAvailabilityOnlyChange`, `isValidUserData`)
- Modify: `lib/features/employees/domain/policies/self_service_fields.dart`
- Modify: `lib/features/employees/domain/models/employee_record.dart`
- Modify: `functions/travel_utils.js`
- Modify: `lib/features/settings/widgets/cards/notifications_settings_card.dart`
- Test: `functions/__tests__/travel_utils.test.js` (extend)

- [ ] **Step 1: Extend the rules allowlist**

In `firestore.rules`, add `'travelAlertsEnabled'` to
`isAvailabilityOnlyChange()`'s `hasOnly` list, and add to `isValidUserData`:

```
          && (!('travelAlertsEnabled' in d.keys())
              || d.travelAlertsEnabled is bool)
```

This is a genuine widening of what an employee may write on their own doc — it
is a per-person notification preference, which is the category the allowlist
exists for. Do not treat "add a key" as routine.

- [ ] **Step 2: Run the mirror tests**

Run: `flutter test test/core/security/ test/features/employees/domain/self_service_fields_test.dart`
Expected: FAIL on the Dart-mirror test — that is the mechanism working.

- [ ] **Step 3: Add the key to the Dart mirror**

Add `'travelAlertsEnabled'` to `kSelfServiceUserFields`.

Run: `flutter test test/features/employees/domain/self_service_fields_test.dart`
Expected: PASS.

- [ ] **Step 4: Write the failing sweep test**

Add to `functions/__tests__/travel_utils.test.js`:

```js
describe("travelAlertsEnabled", () => {
  test("an opted-out assignee gets no leaveNow push", async () => {
    // The flag defaults to ON: a doc written before this field existed has no
    // value, and undefined must read as enabled or the whole fleet goes quiet.
    expect(wantsTravelAlerts({})).toBe(true);
    expect(wantsTravelAlerts({travelAlertsEnabled: true})).toBe(true);
    expect(wantsTravelAlerts({travelAlertsEnabled: false})).toBe(false);
  });
});
```

Import `wantsTravelAlerts` at the top of that file.

- [ ] **Step 5: Run it and confirm it fails**

Run: `cd functions && npx jest __tests__/travel_utils.test.js`
Expected: FAIL — `wantsTravelAlerts is not a function`.

- [ ] **Step 6: Implement and apply the predicate**

Add to `functions/travel_utils.js` and export it:

```js
/**
 * Whether this person still wants the "time to leave" push.
 *
 * **Defaults to ON.** Every users doc written before this field existed has no
 * value, so an `undefined`-is-off reading would silence the whole fleet — the
 * exact failure mode nobody notices, because the symptom is a push that does
 * not arrive.
 *
 * Only the `leaveNow` kind honours it. The plain 30-minute `reminder` fallback,
 * the daily digest and the overdue nudge are unaffected.
 *
 * @param {?Object} user The users doc data.
 * @return {boolean}
 */
function wantsTravelAlerts(user) {
  return !user || user.travelAlertsEnabled !== false;
}
```

Apply it in `runTravelAwareReminderSweep` where the `leaveNow` kind is chosen:
an opted-out assignee falls through to the existing fixed-30-minute `reminder`
path, which is the same degradation every other travel failure already takes.

- [ ] **Step 7: Run the functions suite and lint**

Run: `cd functions && npx jest && npm run lint`
Expected: all green.

- [ ] **Step 8: Add the toggle row**

In `notifications_settings_card.dart`, add a third `SettingsTile` below the Live
Activity row with a `Switch.adaptive` bound to the record's
`travelAlertsEnabled`, writing through `updateSelfDetails`. Add
`settings_travelAlerts` to both ARBs (EN `"Time-to-leave alerts"`, FR
`"Alertes de départ"`) with an EN `@key` block.

`updateSelfDetails` gains a `travelAlertsEnabled` parameter; add it to the
interface, the implementation's patch, and the assertion — the `assert` in
Task 3 will fire immediately if the rules allowlist was not updated first.

- [ ] **Step 9: Full verification**

Run: `flutter test && flutter analyze`
Expected: all green, `No issues found!`

- [ ] **Step 10: Deploy and commit**

```bash
firebase deploy --only functions,firestore:rules
git add -A
git commit -m "feat(settings): per-person time-to-leave alerts toggle"
git push origin redesgin
```

---

## Closing out

- [ ] Update `CLAUDE.md`: the `/users` `allow update` invariant now has a self
      branch, `isAvailabilityOnlyChange()` is no longer uncalled, and
      `MyDetailsScreen` is no longer emergency-contact-only. The existing
      paragraphs saying otherwise become wrong the moment Task 1 lands.
- [ ] Update `docs/plans/README.md` §1: strike P5 from "what has not been done"
      and leave P6 (deferred) and P7 as the remainder.
- [ ] Update `docs/plans/2026-07-29-redesign-program.md` §P5 with a status
      banner, and record the three planning decisions above (no duplicate
      notifications block, explicit-save identity fields, scheduling scoped to
      `maxJobsPerDay`) as deviations.
- [ ] Update `docs/CLOUD_FUNCTIONS.md` and `functions/CLAUDE.md` for
      `changeEmployeeEmail`'s self branch and `sendToActiveAdmins`.
- [ ] Add the new surfaces to
      `docs/plans/redesign-subdocs/2026-07-30-p1-p2-DEVICE-TEST.md`.
