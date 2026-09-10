# Add-Job Client Picker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: SHIPPED AND DEPLOYED — ARCHIVED 2026-09-09.** Implemented
2026-09-05, released as 1.58.0+87 (`101d0c0a`); boxes ticked in `394d67af`.
The backend that owns `searchClients` went live 2026-09-06 (25 → 29 functions,
composite `READY`, tokens backfilled) — see `docs/DEPLOYMENT.md`. Design doc:
`docs/plans/2026-09-05-add-job-client-picker.md`.

**Goal:** Rebuild the add-job client step for an admin who is on the phone with the client and types a full ten-digit number: the match list narrows live above the OS phone pad on one network round trip, a tap attaches the client as a confirmation card, and the job address moves next to that card.

**Architecture:** Three pure policy objects carry the decisions — `PhoneQueryPolicy` (is this a phone query, and what should we actually send), `ClientSearchWindow` (may we narrow the last answer locally instead of re-querying), and the existing `ClientSearchPolicy` with its phone seam fixed. The controller mixin `AppointmentFormConcerns.searchClients` becomes the one orchestrator; the widget stays dumb and renders state. `ClientSearchField` is replaced by `ClientPicker`, which owns the mode switch, the tally, the list and every focus state. `AppointmentAddressField` moves out of the details section into the WHO section under the new `SelectedClientCard`.

**Tech Stack:** Flutter/Dart 3.10, Riverpod 3 (`Notifier`, `FutureProvider`), Freezed, `gen_l10n` ARB localization, Firestore callables (`searchClients`), Jest for the `functions/` twin.

**Design doc:** `docs/plans/2026-09-05-add-job-client-picker.md`
**Mockup:** https://claude.ai/code/artifact/aeedb5fe-92a8-455e-9c22-6741a4252b50

---

## Six findings from reading the code that the design doc does not cover

Read all six before Task 1. Each changes what a task has to do.

### F1 — the design doc's fallback ladder does not rescue the typo it was drawn for

The design says: on a miss, retry the **last seven** digits, then the **last
four**. Run the mockup's own example — stored `5145628332`, typed `5145628233`
(a transposition in the tail) — against a substring index:

| Rung | Query | Result |
|---|---|---|
| full | `5145628233` | miss |
| last 7 | `5628233` | **miss** |
| last 4 | `8233` | **miss** |
| **first 7** | `5145628` | **hit** |

A typo lands in the part of the number you are least sure of, which is the
**tail**. So the rung that survives it is the one anchored at the **head**.
This plan therefore ships:

1. **canonical** — all digits, leading `1` dropped when that leaves ten
2. **first 7** of the canonical — survives an error in the tail
3. **last 7** of the canonical — survives a wrong or missing area code

No last-four rung: it is the least selective and, as the table shows, it does
not rescue the case it was added for. **Update the design doc and the artifact
to match** (Task 13).

### F2 — `phoneDigits` is a concatenated blob in THREE places, not one

The design names two. There are three, and one is a shared record type:

- `ClientSearchPolicy.index` (`client_search_policy.dart:113-118`) builds
  `phoneDigits` by joining `phone`, `mobile` and every contact phone, then
  `digitsOnly` — which strips the joining spaces. `entryMatches` (L199-207)
  then does `entry.phoneDigits.contains(queryDigits)`.
- `firebase_clients_repository.dart:437-441` builds its own
  `digitsOnly('${data['phone']} ${data['mobile']}')` for `relevanceScore`.
- `functions/search_tokens.js:199-204` `recordMatchesQuery` does the same on the
  server, over `phone`, `mobile`, `clientPhone` and contact phones.

Two consequences: a query can **straddle the seam** between two numbers and
match a number nobody has, and `relevanceScore`'s exact tier
(`phoneDigits == queryDigits`, L181) is **unreachable** for any client with both
a phone and a mobile. Task 2 fixes all three together, and changing
`ClientSearchEntry.phoneDigits` from `String` to `List<String>` is a breaking
change to a typedef used across the clients feature.

### F3 — two different things are called `AppointmentFormFields`

`abstract interface class AppointmentFormFields`
(`appointment_form_concerns.dart:15-22`) is the state read-interface. `class
AppointmentFormFields extends StatelessWidget`
(`appointment_form_fields.dart:104`) is the widget. Both files are edited by
this plan. When a step says "add a field to `AppointmentFormFields`", it means
the **interface**; widget changes are always named as
`appointment_form_fields.dart`.

### F4 — the edit host keeps THREE client fields, and a pick writes two of them

`EventDetailsState` has `client` (the originally loaded client, L62),
`selectedClient` (L63) and `clientCleared` (L71). `applyFormUpdate` writes
**both** `selectedClient` and `client` on a pick (L303-308), and
`_loadClientIfNeeded` adopts a client only `if (state.selectedClient == null &&
!state.clientCleared)` (L196-201). Nothing in this plan may bypass that: attach
still goes through `selectClient`, and clear still goes through `clearClient`.

### F5 — local narrowing is only sound when the previous answer was complete

`ClientSearchPolicy.resultDisplayLimit` is 25 and the server returns at most
that. If the answer for `5145628` was truncated at 25, the client matching
`51456283` may be one of the ones that never came back — so filtering the 25
locally would **hide a real match with nothing logged**. Narrowing is therefore
permitted only when the previous window was **not** at the cap. Task 3 makes
that a property of the window, not a judgement at the call site.

### F6 — recents cannot be an unfiltered query for a non-admin, and do not need to be

**Job creation is admin-only.** `_addAppointmentFab`
(`main_calendar_screen.dart:529-530`) opens with
`if (!widget.isAdmin) return null;`, so an employee never reaches this sheet
from the calendar. The limitation below therefore costs nothing today; it is
recorded so that a future decision to let employees book does not quietly ship a
picker with a permanently empty recents list.


The invariant is "employees see only appointments where their doc id is in
`employeeIds`" (root `CLAUDE.md`). A recents query is
`orderBy('createdAt', descending: true).limit(n)` with no `employeeIds`
constraint, which an employee's rules evaluation rejects outright. Adding
`whereArrayContains('employeeIds', id)` to it would need a **new composite
index**. This plan does neither: **recents resolve to an empty list for
non-admins**, documented at the provider. They then simply type the number,
which is the whole workflow anyway.

`appointments.createdAt` has **no** entry in `firestore.indexes.json`
`fieldOverrides` (the appointments overrides are `pictures`, `employeeNames`,
`title`, `notes`, `materialsNeeded`, `address`, `clientName`, `clientPhone`,
`seriesOpId`, plus explicit re-enables for `clientId`, `startTime`, `status`),
so it keeps default single-field indexing and needs **no new index**. Task 4
verifies this rather than assuming it.

---

## File Structure

**Created:**
- `lib/features/clients/domain/policies/phone_query_policy.dart` — mode detection, canonical digits, the three-rung ladder (F1). Its own file beside `client_search_policy.dart` because it is query-shaping, not matching.
- `lib/features/clients/domain/models/client_search_window.dart` — the last answer plus whether it may be narrowed (F5).
- `lib/features/clients/domain/models/client_search_status.dart` — the Freezed value object the form states carry for everything the picker renders that is not the result list itself.
- `lib/features/calendar/domain/models/recent_client.dart` — the `RecentClient` record typedef.
- `lib/features/calendar/application/recent_clients_provider.dart` — session-cached recents, admin-only (F6).
- `lib/features/clients/widgets/fields/client_picker.dart` — replaces `ClientSearchField`. Owns the mode switch, the number field, the tally, the result list and every focus state.
- `lib/features/clients/widgets/cards/selected_client_card.dart` — the confirmation card.
- `lib/features/calendar/widgets/sections/job_address_section.dart` — the address block in its new WHO home: the switch's off-state panel of previous job addresses plus the existing autocomplete.
- `lib/features/calendar/domain/policies/previous_address_policy.dart` — groups previous job addresses by street/unit (Task 11b).
- `test/features/clients/domain/phone_query_policy_test.dart`
- `test/features/clients/domain/client_search_window_test.dart`
- `test/features/clients/widgets/client_picker_test.dart`
- `test/features/clients/widgets/selected_client_card_test.dart`
- `test/features/calendar/widgets/sections/job_address_section_test.dart`
- `test/features/calendar/recent_clients_provider_test.dart`
- `test/features/calendar/domain/previous_address_policy_test.dart`

**Deleted:**
- `lib/features/clients/widgets/fields/client_search_field.dart`
- `test/features/clients/widgets/client_search_field_test.dart` (its five cases are re-expressed against `ClientPicker` in Task 9)

**Modified:**
- `lib/features/clients/domain/policies/client_search_policy.dart` — `ClientSearchEntry.phoneDigits` becomes `List<String>`; `index`, `entryMatches`, `relevanceScore` follow (F2).
- `lib/features/clients/data/firebase_clients_repository.dart` — the relevance call site's own blob (F2); `searchClients` reports truncation.
- `functions/search_tokens.js` — `recordMatchesQuery` splits phones (F2).
- `lib/features/calendar/application/appointment_form_concerns.dart` — the interface gains `clientSearchStatus`; `AppointmentFormUpdate` gains it; `searchClients` becomes the orchestrator.
- `lib/features/calendar/application/add_event_controller.dart` — state field + `applyFormUpdate`.
- `lib/features/calendar/application/event_details_controller.dart` — state field + `applyFormUpdate` (F4).
- `lib/features/calendar/widgets/sections/appointment_form_fields.dart` — renders `ClientPicker` / `SelectedClientCard` / `JobAddressSection` in WHO; drops `AppointmentAddressField` from `_detailsBody`.
- `lib/features/clients/domain/policies/client_name_policy.dart` — `_matchPhone` accepts 7-15 digits, not exactly 10.
- `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- `lib/features/feature_tour/...` — `TourStepId.apptClient` copy.
- `.claude/rules/clients.md`, `docs/plans/2026-09-05-add-job-client-picker.md`

---

### Task 1: `PhoneQueryPolicy` — what we actually send

**Files:**
- Create: `lib/features/clients/domain/policies/phone_query_policy.dart`
- Test: `test/features/clients/domain/phone_query_policy_test.dart`

- [x] **Step 1: Write the failing test**

Create `test/features/clients/domain/phone_query_policy_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';

void main() {
  group('isPhoneQuery', () {
    test('digits and separators only', () {
      expect(PhoneQueryPolicy.isPhoneQuery('(514) 562-8332'), isTrue);
      expect(PhoneQueryPolicy.isPhoneQuery('5145628332'), isTrue);
      expect(PhoneQueryPolicy.isPhoneQuery('514'), isTrue);
    });

    test('anything with a letter is a text query', () {
      expect(PhoneQueryPolicy.isPhoneQuery('tremblay'), isFalse);
      expect(PhoneQueryPolicy.isPhoneQuery('4820 Wellington'), isFalse);
      expect(PhoneQueryPolicy.isPhoneQuery('H4G 1X2'), isFalse);
    });

    test('empty or punctuation-only is neither', () {
      expect(PhoneQueryPolicy.isPhoneQuery(''), isFalse);
      expect(PhoneQueryPolicy.isPhoneQuery('()-'), isFalse);
    });
  });

  group('canonicalDigits', () {
    test('strips separators', () {
      expect(PhoneQueryPolicy.canonicalDigits('(514) 562-8332'), '5145628332');
    });

    // A leading 1 is a habit, not a digit of the number. Stored numbers are
    // exactly ten digits (normalizePhoneForStorage -> bareNumber), so an
    // 11-digit token is a substring of nothing.
    test('drops a leading 1 when that leaves ten digits', () {
      expect(PhoneQueryPolicy.canonicalDigits('15145628332'), '5145628332');
      expect(PhoneQueryPolicy.canonicalDigits('1 514 562 8332'), '5145628332');
    });

    test('leaves an 11-digit string that does not start with 1 alone', () {
      expect(PhoneQueryPolicy.canonicalDigits('51456283322'), '51456283322');
    });

    test('leaves short input alone', () {
      expect(PhoneQueryPolicy.canonicalDigits('1514'), '1514');
    });
  });

  group('ladder', () {
    test('below the minimum it sends nothing', () {
      expect(PhoneQueryPolicy.ladder('514'), isEmpty);
      expect(PhoneQueryPolicy.ladder('514562'), isEmpty);
    });

    test('at seven digits it sends exactly one rung', () {
      final rungs = PhoneQueryPolicy.ladder('5145628');
      expect(rungs, hasLength(1));
      expect(rungs.single.rung, PhoneRung.canonical);
      expect(rungs.single.digits, '5145628');
    });

    test('a partial eight or nine digits still sends only the canonical', () {
      expect(PhoneQueryPolicy.ladder('51456283'), hasLength(1));
      expect(PhoneQueryPolicy.ladder('514562833'), hasLength(1));
    });

    test('a full ten digits sends canonical, then first seven, then last seven', () {
      final rungs = PhoneQueryPolicy.ladder('5145628332');
      expect(rungs.map((r) => r.rung).toList(), [
        PhoneRung.canonical,
        PhoneRung.firstSeven,
        PhoneRung.lastSeven,
      ]);
      expect(rungs[0].digits, '5145628332');
      expect(rungs[1].digits, '5145628');
      expect(rungs[2].digits, '5628332');
    });

    test('a leading 1 is absorbed before the ladder is built', () {
      final rungs = PhoneQueryPolicy.ladder('1 (514) 562-8332');
      expect(rungs[0].digits, '5145628332');
      expect(rungs[1].digits, '5145628');
    });

    // F1: this is the case the design doc's last-7/last-4 ladder missed.
    test('the first-seven rung rescues a transposition in the tail', () {
      const stored = '5145628332';
      final rungs = PhoneQueryPolicy.ladder('5145628233');
      expect(stored.contains(rungs[0].digits), isFalse, reason: 'canonical misses');
      expect(stored.contains(rungs[1].digits), isTrue, reason: 'first seven hits');
    });

    // The other direction: a wrong area code with a correct local number.
    test('the last-seven rung rescues a wrong area code', () {
      const stored = '5145628332';
      final rungs = PhoneQueryPolicy.ladder('4385628332');
      expect(stored.contains(rungs[0].digits), isFalse);
      expect(stored.contains(rungs[1].digits), isFalse);
      expect(stored.contains(rungs[2].digits), isTrue);
    });

    test('an over-long typo keeps a usable head rung', () {
      const stored = '5145628332';
      final rungs = PhoneQueryPolicy.ladder('51456283322');
      expect(rungs[1].digits, '5145628');
      expect(stored.contains(rungs[1].digits), isTrue);
    });

    test('rungs are de-duplicated when the number is exactly seven digits', () {
      final rungs = PhoneQueryPolicy.ladder('5628332');
      expect(rungs.map((r) => r.digits).toSet(), hasLength(1));
    });
  });

  group('fallbacksAllowed', () {
    // Fallbacks must not fire while he is still typing; only once the number
    // looks finished. Otherwise every partial spends three round trips.
    test('only at ten digits or more', () {
      expect(PhoneQueryPolicy.fallbacksAllowed('5145628'), isFalse);
      expect(PhoneQueryPolicy.fallbacksAllowed('514562833'), isFalse);
      expect(PhoneQueryPolicy.fallbacksAllowed('5145628332'), isTrue);
      expect(PhoneQueryPolicy.fallbacksAllowed('51456283322'), isTrue);
    });
  });
}
```

- [x] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/clients/domain/phone_query_policy_test.dart`
Expected: compile failure — `Target of URI doesn't exist: '.../phone_query_policy.dart'`.

- [x] **Step 3: Write the policy**

Create `lib/features/clients/domain/policies/phone_query_policy.dart`:

```dart
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// Which slice of the typed number a result came back from.
enum PhoneRung { canonical, firstSeven, lastSeven }

/// One query the app is willing to send, and what it is.
typedef PhoneQueryRung = ({PhoneRung rung, String digits});

/// Shapes the query the app SENDS from the number the admin TYPES.
///
/// The token index holds every 3-12 digit substring at every start position,
/// so a slice of the typed number is a legal query and a far better one than
/// the raw string: it absorbs a leading country code and it survives a typo.
abstract final class PhoneQueryPolicy {
  const PhoneQueryPolicy._();

  /// Below this a digits-only query cannot be selective — `514` matches the
  /// roster twice over and costs 200 document reads to prove it.
  static const int minPhoneDigits = 7;

  static const int _nanpLength = 10;

  static final _letter = RegExp('[a-zA-Z]');

  static bool isPhoneQuery(String raw) =>
      !_letter.hasMatch(raw) && ClientSearchPolicy.digitsOnly(raw).isNotEmpty;

  static String canonicalDigits(String raw) {
    final digits = ClientSearchPolicy.digitsOnly(raw);
    if (digits.length == _nanpLength + 1 && digits.startsWith('1')) {
      return digits.substring(1);
    }
    return digits;
  }

  /// True once the number looks finished, so spending the fallback round trips
  /// is worth it. While he is still typing it stays false.
  static bool fallbacksAllowed(String raw) =>
      canonicalDigits(raw).length >= _nanpLength;

  /// The queries to try, in order, stopping at the first that answers.
  static List<PhoneQueryRung> ladder(String raw) {
    final digits = canonicalDigits(raw);
    if (digits.length < minPhoneDigits) return const [];

    final out = <PhoneQueryRung>[(rung: PhoneRung.canonical, digits: digits)];
    if (!fallbacksAllowed(raw)) return out;

    final seen = <String>{digits};
    void add(PhoneRung rung, String slice) {
      if (seen.add(slice)) out.add((rung: rung, digits: slice));
    }

    // Head first: a typo lands in the part of the number he is least sure of,
    // which is the tail, so the head is what survives it.
    add(PhoneRung.firstSeven, digits.substring(0, minPhoneDigits));
    add(PhoneRung.lastSeven, digits.substring(digits.length - minPhoneDigits));
    return out;
  }
}
```

- [x] **Step 4: Run the test and confirm it passes**

Run: `flutter test test/features/clients/domain/phone_query_policy_test.dart`
Expected: `All tests passed!`

- [x] **Step 5: Commit**

```bash
git add lib/features/clients/domain/policies/phone_query_policy.dart test/features/clients/domain/phone_query_policy_test.dart
git commit -m "Add PhoneQueryPolicy: canonical digits and the three-rung query ladder"
```

---

### Task 2: Split the concatenated phone blob, both sides (F2)

**Files:**
- Modify: `lib/features/clients/domain/policies/client_search_policy.dart:1-10` (the typedef), `:95-120` (`index`), `:173-207` (`relevanceScore`, `entryMatches`)
- Modify: `lib/features/clients/data/firebase_clients_repository.dart:437-441`
- Modify: `functions/search_tokens.js:179-207`
- Test: `test/features/clients/client_search_policy_test.dart`, `test/features/clients/data/client_search_relevance_test.dart`, `functions/__tests__/search_tokens.test.js`

- [x] **Step 1: Write the failing Dart tests**

Append to `test/features/clients/client_search_policy_test.dart`, inside `main()`:

```dart
  group('phone seam (F2)', () {
    ClientRecord clientWith({
      String phone = '',
      String mobile = '',
      List<ClientContact> contacts = const [],
    }) => ClientRecord(
      id: 'c1',
      name: 'Marie Tremblay',
      phone: phone,
      mobile: mobile,
      contacts: contacts,
    );

    test('a query straddling phone and mobile no longer matches', () {
      final client = clientWith(phone: '5145628332', mobile: '4385551212');
      // The old blob was '51456283324385551212', which contains '83324385'.
      expect(ClientSearchPolicy.matchesClient(client, '83324385'), isFalse);
    });

    test('each number still matches on its own', () {
      final client = clientWith(phone: '5145628332', mobile: '4385551212');
      expect(ClientSearchPolicy.matchesClient(client, '5145628332'), isTrue);
      expect(ClientSearchPolicy.matchesClient(client, '4385551212'), isTrue);
      expect(ClientSearchPolicy.matchesClient(client, '5628332'), isTrue);
    });

    test('index exposes one entry per number, not one blob', () {
      final entry = ClientSearchPolicy.index(
        clientWith(phone: '5145628332', mobile: '4385551212'),
      );
      expect(entry.phoneDigits, ['5145628332', '4385551212']);
    });

    test('a contact phone is its own entry', () {
      final entry = ClientSearchPolicy.index(
        clientWith(
          phone: '5145628332',
          contacts: const [ClientContact(name: 'Ana', phone: '5145550110')],
        ),
      );
      expect(entry.phoneDigits, contains('5145550110'));
    });

    test('blank numbers are dropped rather than becoming empty entries', () {
      final entry = ClientSearchPolicy.index(clientWith(phone: '5145628332'));
      expect(entry.phoneDigits, ['5145628332']);
    });
  });

  group('relevance exact tier with two numbers (F2)', () {
    test('the main line reaches the exact tier even when a mobile exists', () {
      final score = ClientSearchPolicy.relevanceScore(
        displayName: 'marie tremblay',
        personName: 'marie tremblay',
        phoneDigits: const ['5145628332', '4385551212'],
        contactsDigits: const [],
        queryText: '5145628332',
        queryDigits: '5145628332',
      );
      expect(score, 0);
    });

    test('the mobile reaches the exact tier too', () {
      final score = ClientSearchPolicy.relevanceScore(
        displayName: 'marie tremblay',
        personName: 'marie tremblay',
        phoneDigits: const ['5145628332', '4385551212'],
        contactsDigits: const [],
        queryText: '4385551212',
        queryDigits: '4385551212',
      );
      expect(score, 0);
    });

    test('a prefix of the mobile reaches the prefix tier', () {
      final score = ClientSearchPolicy.relevanceScore(
        displayName: 'marie tremblay',
        personName: 'marie tremblay',
        phoneDigits: const ['5145628332', '4385551212'],
        contactsDigits: const [],
        queryText: '438555',
        queryDigits: '438555',
      );
      expect(score, 2);
    });
  });
```

Add the imports the group needs at the top of the file if absent:

```dart
import 'package:scheduling/features/clients/domain/models/client_record.dart';
```

> If `ClientContact`'s constructor differs from `ClientContact(name:, phone:)`,
> read `lib/features/clients/domain/models/client_record.dart` and use the real
> one — do not change the assertions.

- [x] **Step 2: Run them and confirm they fail**

Run: `flutter test test/features/clients/client_search_policy_test.dart`
Expected: compile failure on `entry.phoneDigits` being compared to a `List`, and
on `relevanceScore(phoneDigits: const [...])` — the parameter is still `String`.

- [x] **Step 3: Change the typedef and the three readers**

In `lib/features/clients/domain/policies/client_search_policy.dart`, change the
typedef:

```dart
/// A pre-normalized searchable projection of a client.
///
/// `phoneDigits` is ONE ENTRY PER NUMBER, never a concatenation. Joining them
/// let a query straddle the seam between two numbers and match a number nobody
/// has, and it made the exact-match tier unreachable for any client with both a
/// phone and a mobile.
typedef ClientSearchEntry = ({
  ClientRecord client,
  String text,
  List<String> phoneDigits,
});
```

Replace the `phoneDigits:` block inside `index` (was L113-118):

```dart
    phoneDigits: [
      for (final raw in [
        client.phone,
        client.mobile,
        for (final c in client.contacts) c.phone,
      ])
        if (digitsOnly(raw).isNotEmpty) digitsOnly(raw),
    ],
```

Replace `entryMatches` (was L199-207):

```dart
  static bool entryMatches(
    ClientSearchEntry entry, {
    required String queryText,
    required String queryDigits,
  }) {
    final matchesText = queryText.isNotEmpty && entry.text.contains(queryText);
    final matchesPhone =
        queryDigits.isNotEmpty &&
        entry.phoneDigits.any((number) => number.contains(queryDigits));
    return matchesText || matchesPhone;
  }
```

Replace `relevanceScore` (was L173-195):

```dart
  static int relevanceScore({
    required String displayName,
    required String personName,
    required List<String> phoneDigits,
    required List<String> contactsDigits,
    required String queryText,
    required String queryDigits,
  }) {
    final hasDigits = queryDigits.isNotEmpty;
    if (displayName == queryText ||
        (hasDigits && phoneDigits.contains(queryDigits))) {
      return 0;
    }
    if (displayName.startsWith(queryText) || personName.startsWith(queryText)) {
      return 1;
    }
    if (hasDigits &&
        phoneDigits.any((number) => number.startsWith(queryDigits))) {
      return 2;
    }
    if (displayName.contains(queryText) || personName.contains(queryText)) {
      return 3;
    }
    if (hasDigits &&
        [...phoneDigits, ...contactsDigits]
            .any((number) => number.contains(queryDigits))) {
      return 4;
    }
    return 5;
  }
```

- [x] **Step 4: Fix the repository call site**

In `lib/features/clients/data/firebase_clients_repository.dart`, replace the two
blob builders (was L437-441) with per-number lists. The `contactSearchText`
join above them stays as it is — that one is text, not digits.

```dart
    final phoneDigits = [
      for (final raw in [data['phone'], data['mobile']])
        if (ClientSearchPolicy.digitsOnly('${raw ?? ''}').isNotEmpty)
          ClientSearchPolicy.digitsOnly('${raw ?? ''}'),
    ];
    final contactsDigits = [
      for (final contact in rawContacts)
        if (ClientSearchPolicy.digitsOnly(
          '${(contact as Map?)?['phone'] ?? ''}',
        ).isNotEmpty)
          ClientSearchPolicy.digitsOnly('${(contact as Map?)?['phone'] ?? ''}'),
    ];
```

> Read the surrounding lines first: the local holding the raw contacts list may
> be named differently in this scope. Use whatever the existing
> `contactSearchText` loop iterates.

- [x] **Step 5: Run the Dart tests**

Run: `flutter test test/features/clients/client_search_policy_test.dart test/features/clients/data/client_search_relevance_test.dart`
Expected: `All tests passed!` If a pre-existing relevance test asserted the old
concatenated behaviour, update the assertion — the old behaviour was the bug.

- [x] **Step 6: Write the failing Jest test for the server twin**

Append to `functions/__tests__/search_tokens.test.js`:

```js
describe("recordMatchesQuery phone seam", () => {
  const client = {
    name: "Marie Tremblay",
    phone: "5145628332",
    mobile: "4385551212",
    contacts: [{name: "Ana", phone: "5145550110"}],
  };

  it("does not match a query straddling two numbers", () => {
    // The old blob was '514562833243855512125145550110'.
    expect(recordMatchesQuery(client, "83324385")).toBe(false);
  });

  it("matches each number on its own", () => {
    expect(recordMatchesQuery(client, "5145628332")).toBe(true);
    expect(recordMatchesQuery(client, "4385551212")).toBe(true);
    expect(recordMatchesQuery(client, "5145550110")).toBe(true);
  });

  it("still matches a substring inside one number", () => {
    expect(recordMatchesQuery(client, "5628332")).toBe(true);
  });

  it("still matches text", () => {
    expect(recordMatchesQuery(client, "tremblay")).toBe(true);
  });
});
```

- [x] **Step 7: Run it and confirm the straddle case fails**

Run: `npm --prefix functions test -- search_tokens`
Expected: the "does not match a query straddling two numbers" case FAILS
(receives `true`).

- [x] **Step 8: Split the server side**

In `functions/search_tokens.js`, replace the `digits` block inside
`recordMatchesQuery` (was L199-204) and its return (L205-206):

```js
  const phones = [
    d.phone,
    d.mobile,
    d.clientPhone,
    ...contacts.map((c) => c && c.phone),
  ].map(digitsOnly).filter((n) => n.length > 0);
  return Boolean((q && text.includes(q)) ||
      (qDigits && phones.some((n) => n.includes(qDigits))));
```

- [x] **Step 9: Run both suites**

Run: `npm --prefix functions run lint && npm --prefix functions test -- search_tokens`
Expected: eslint clean, all cases pass.

- [x] **Step 10: Commit**

```bash
git add lib/features/clients/domain/policies/client_search_policy.dart lib/features/clients/data/firebase_clients_repository.dart functions/search_tokens.js test/features/clients/client_search_policy_test.dart test/features/clients/data/client_search_relevance_test.dart functions/__tests__/search_tokens.test.js
git commit -m "Score and match each client phone separately, in Dart and on the server"
```

---

### Task 3: `ClientSearchWindow` — when we may narrow locally (F5)

**Files:**
- Create: `lib/features/clients/domain/models/client_search_window.dart`
- Test: `test/features/clients/domain/client_search_window_test.dart`

- [x] **Step 1: Write the failing test**

Create `test/features/clients/domain/client_search_window_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_window.dart';

ClientRecord _client(String id, String phone) =>
    ClientRecord(id: id, name: phone, phone: phone);

void main() {
  final marie = _client('c1', '5145628332');
  final jp = _client('c2', '5145628901');

  group('canNarrowTo', () {
    test('a longer prefix of the same number narrows', () {
      const window = ClientSearchWindow(
        digits: '5145628',
        results: [],
        truncated: false,
      );
      expect(window.canNarrowTo('51456283'), isTrue);
      expect(window.canNarrowTo('5145628332'), isTrue);
    });

    test('a shorter or different query does not', () {
      const window = ClientSearchWindow(
        digits: '5145628',
        results: [],
        truncated: false,
      );
      expect(window.canNarrowTo('514562'), isFalse);
      expect(window.canNarrowTo('4385628332'), isFalse);
    });

    // F5: at the cap the answer is incomplete, so the client we want may never
    // have come back. Filtering it further hides a real match silently.
    test('a truncated window never narrows', () {
      const window = ClientSearchWindow(
        digits: '5145628',
        results: [],
        truncated: true,
      );
      expect(window.canNarrowTo('5145628332'), isFalse);
    });

    test('an empty window never narrows', () {
      expect(ClientSearchWindow.empty.canNarrowTo('5145628332'), isFalse);
    });
  });

  group('narrowTo', () {
    test('keeps only the clients still matching', () {
      final window = ClientSearchWindow(
        digits: '5145628',
        results: [marie, jp],
        truncated: false,
      );
      final narrowed = window.narrowTo('5145628332');
      expect(narrowed.results, [marie]);
      expect(narrowed.digits, '5145628332');
      expect(narrowed.truncated, isFalse);
    });

    test('a narrowed window can be narrowed again', () {
      final window = ClientSearchWindow(
        digits: '514',
        results: [marie, jp],
        truncated: false,
      );
      expect(window.narrowTo('5145628').narrowTo('5145628332').results, [marie]);
    });

    test('narrowing to nothing yields an empty result set, not a miss flag', () {
      final window = ClientSearchWindow(
        digits: '5145628',
        results: [marie, jp],
        truncated: false,
      );
      expect(window.narrowTo('5145628777').results, isEmpty);
    });
  });
}
```

- [x] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/clients/domain/client_search_window_test.dart`
Expected: compile failure — `client_search_window.dart` does not exist.

- [x] **Step 3: Write the window**

Create `lib/features/clients/domain/models/client_search_window.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// The last answer the callable gave, and whether it may be filtered further
/// instead of asking again.
///
/// Phone matching is a SUBSTRING test, so the candidate set only ever shrinks
/// as digits land: anything matching ten digits already matched the first
/// seven. That is what lets one query serve a whole number — but only when the
/// answer was COMPLETE. At the result cap the client being looked for may never
/// have come back, and narrowing would hide it with nothing logged.
@immutable
class ClientSearchWindow {
  const ClientSearchWindow({
    required this.digits,
    required this.results,
    required this.truncated,
  });

  static const ClientSearchWindow empty = ClientSearchWindow(
    digits: '',
    results: [],
    truncated: false,
  );

  final String digits;
  final List<ClientRecord> results;
  final bool truncated;

  bool get isEmpty => digits.isEmpty;

  bool canNarrowTo(String nextDigits) =>
      !isEmpty &&
      !truncated &&
      nextDigits.length > digits.length &&
      nextDigits.startsWith(digits);

  ClientSearchWindow narrowTo(String nextDigits) => ClientSearchWindow(
    digits: nextDigits,
    truncated: false,
    results: [
      for (final client in results)
        if (ClientSearchPolicy.index(client).phoneDigits.any(
          (number) => number.contains(nextDigits),
        ))
          client,
    ],
  );
}
```

- [x] **Step 4: Run the test**

Run: `flutter test test/features/clients/domain/client_search_window_test.dart`
Expected: `All tests passed!`

- [x] **Step 5: Commit**

```bash
git add lib/features/clients/domain/models/client_search_window.dart test/features/clients/domain/client_search_window_test.dart
git commit -m "Add ClientSearchWindow: narrow a complete answer locally instead of re-querying"
```

---

### Task 4: Recents, from appointments already paid for (F6)

**Files:**
- Create: `lib/features/calendar/domain/models/recent_client.dart`
- Create: `lib/features/calendar/application/recent_clients_provider.dart`
- Modify: `lib/features/calendar/domain/appointments_repository.dart` (add `fetchRecentClientBookings`)
- Modify: `lib/features/calendar/data/firebase_appointments_repository.dart`
- Test: `test/features/calendar/recent_clients_provider_test.dart`

- [x] **Step 1: Confirm no index is needed**

Run:

```bash
python -c "
import json
d=json.load(open('firestore.indexes.json'))
print([f['fieldPath'] for f in d.get('fieldOverrides',[]) if f.get('collectionGroup')=='appointments'])
"
```

Expected: a list **without** `createdAt`, and without `*`. That means
`appointments.createdAt` keeps default single-field indexing, so
`orderBy('createdAt', descending: true).limit(n)` needs no new index. If
`createdAt` or `*` IS in that list, stop and add a single-field re-enable
override before continuing — a missing one fails the query at runtime, not at
deploy.

- [x] **Step 2: Write the failing test**

Create `test/features/calendar/recent_clients_provider_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/recent_client.dart';

void main() {
  AppointmentRecord booking({
    required String clientId,
    required String name,
    required String phone,
    String address = '',
    required int day,
  }) => AppointmentRecord(
    startTime: DateTime(2026, 9, day),
    endTime: DateTime(2026, 9, day, 1),
    clientId: clientId,
    clientName: name,
    clientPhone: phone,
    address: address,
  );

  group('recentClientsFrom', () {
    test('keeps newest-first order and drops repeats', () {
      final recents = recentClientsFrom([
        booking(clientId: 'c1', name: 'Marie', phone: '5145628332', day: 5),
        booking(clientId: 'c2', name: 'Nordelec', phone: '5145550110', day: 4),
        booking(clientId: 'c1', name: 'Marie', phone: '5145628332', day: 3),
      ]);
      expect(recents.map((r) => r.clientId).toList(), ['c1', 'c2']);
    });

    test('drops personal jobs and rows with no client', () {
      final recents = recentClientsFrom([
        booking(clientId: '', name: '', phone: '', day: 5),
        booking(clientId: 'c1', name: 'Marie', phone: '5145628332', day: 4),
      ]);
      expect(recents.map((r) => r.clientId).toList(), ['c1']);
    });

    test('carries the job address of the most recent booking', () {
      final recents = recentClientsFrom([
        booking(
          clientId: 'c1',
          name: 'Marie',
          phone: '5145628332',
          address: '4820 rue Wellington',
          day: 5,
        ),
        booking(
          clientId: 'c1',
          name: 'Marie',
          phone: '5145628332',
          address: '1250 boul. LaSalle',
          day: 3,
        ),
      ]);
      expect(recents.single.address, '4820 rue Wellington');
    });

    test('caps the list', () {
      final recents = recentClientsFrom([
        for (var i = 0; i < 80; i++)
          booking(clientId: 'c$i', name: 'C$i', phone: '514555$i', day: 1),
      ], limit: 40);
      expect(recents, hasLength(40));
    });
  });

  group('matchesDigits', () {
    test('matches a substring of the phone', () {
      const recent = (
        clientId: 'c1',
        name: 'Marie Tremblay',
        phone: '5145628332',
        address: '',
      );
      expect(matchesDigits(recent, '514'), isTrue);
      expect(matchesDigits(recent, '5628'), isTrue);
      expect(matchesDigits(recent, '999'), isFalse);
    });

    test('an empty query matches everything', () {
      const recent = (
        clientId: 'c1',
        name: 'Marie Tremblay',
        phone: '5145628332',
        address: '',
      );
      expect(matchesDigits(recent, ''), isTrue);
    });
  });
}
```

- [x] **Step 3: Run it and confirm it fails**

Run: `flutter test test/features/calendar/recent_clients_provider_test.dart`
Expected: compile failure — `recent_client.dart` does not exist.

- [x] **Step 4: Write the model and its two pure functions**

Create `lib/features/calendar/domain/models/recent_client.dart`:

```dart
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// A client this admin booked recently, built from appointments the app has
/// already read. Deliberately NOT a `ClientRecord`: it carries only what an
/// appointment denormalizes, so showing recents costs no client reads at all.
typedef RecentClient = ({
  String clientId,
  String name,
  String phone,
  String address,
});

/// Newest-first, one entry per client, capped.
List<RecentClient> recentClientsFrom(
  List<AppointmentRecord> bookings, {
  int limit = 40,
}) {
  final seen = <String>{};
  final out = <RecentClient>[];
  for (final booking in bookings) {
    if (booking.clientId.isEmpty) continue;
    if (!seen.add(booking.clientId)) continue;
    out.add((
      clientId: booking.clientId,
      name: booking.clientName,
      phone: booking.clientPhone,
      address: booking.address,
    ));
    if (out.length >= limit) break;
  }
  return out;
}

/// The local filter the picker applies while the query is too short to send.
bool matchesDigits(RecentClient recent, String digits) {
  if (digits.isEmpty) return true;
  return ClientSearchPolicy.digitsOnly(recent.phone).contains(digits);
}
```

- [x] **Step 5: Run the test**

Run: `flutter test test/features/calendar/recent_clients_provider_test.dart`
Expected: `All tests passed!`

- [x] **Step 6: Add the repository method**

In `lib/features/calendar/domain/appointments_repository.dart`, beside
`fetchClientHistory` (L96-100):

```dart
  /// The most recent bookings across all clients, newest-first, for the
  /// picker's recents list. Admin-only: the query carries no `employeeIds`
  /// constraint, so an employee's rules evaluation rejects it.
  Future<List<AppointmentRecord>> fetchRecentClientBookings({int limit});
```

In `lib/features/calendar/data/firebase_appointments_repository.dart`, beside
`fetchClientHistory`:

```dart
  @override
  Future<List<AppointmentRecord>> fetchRecentClientBookings({
    int limit = 60,
  }) async {
    final snapshot = await _firestore
        .collection('appointments')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    return [
      for (final doc in snapshot.docs) AppointmentRecord.fromFirestore(doc),
    ];
  }
```

> Use whatever constructor the neighbouring methods use to build an
> `AppointmentRecord` from a snapshot — read `fetchClientHistory` and copy it.
> There is no paging and no cap warn here on purpose: the limit IS the answer,
> not a truncation of one.

- [x] **Step 7: Write the provider**

Create `lib/features/calendar/application/recent_clients_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/logging/logger_provider.dart';
import 'package:scheduling/features/calendar/domain/models/recent_client.dart';

/// Clients this admin booked recently, resolved once per session.
///
/// NOT autoDispose: it is read by a sheet that opens and closes many times a
/// day, and the whole point is that reopening costs nothing.
///
/// Empty for a non-admin. The underlying query has no `employeeIds` constraint
/// — employees may only read appointments they are assigned to — and adding one
/// would need a new composite index for no real gain, since an employee's
/// workflow here is to type the number anyway.
final recentClientsProvider = FutureProvider<List<RecentClient>>((ref) async {
  final isAdmin = await ref.watch(isCurrentUserAdminProvider.future);
  if (!isAdmin) return const [];
  final logger = ref.read(loggerProvider);
  final repo = ref.read(appointmentsRepositoryProvider);
  try {
    final bookings = await repo.fetchRecentClientBookings(limit: 60);
    return recentClientsFrom(bookings);
  } catch (e, st) {
    // Recents are a convenience; a failure must never block the picker.
    logger.warn('CLI-RECENT recent clients lookup failed', e, st);
    return const [];
  }
});
```

> `isCurrentUserAdminProvider` and `appointmentsRepositoryProvider` are
> placeholders for whatever this repo already exposes — grep
> `lib/features/calendar/application/` for the appointments repository provider
> and `lib/core/` for the admin/role provider, and import the real ones. Do not
> read the role from SharedPreferences (root `CLAUDE.md`).

- [x] **Step 8: Analyzer and commit**

Run: `flutter analyze lib/features/calendar/application/recent_clients_provider.dart lib/features/calendar/domain/models/recent_client.dart`
Expected: `No issues found!`

```bash
git add lib/features/calendar/domain/models/recent_client.dart lib/features/calendar/application/recent_clients_provider.dart lib/features/calendar/domain/appointments_repository.dart lib/features/calendar/data/firebase_appointments_repository.dart test/features/calendar/recent_clients_provider_test.dart
git commit -m "Add recent clients, derived from appointments the app already reads"
```

---

### Task 5: `ClientSearchStatus` — everything the picker renders that is not the list

**Files:**
- Create: `lib/features/clients/domain/models/client_search_status.dart`
- Modify: `lib/features/calendar/application/appointment_form_concerns.dart:15-54`
- Modify: `lib/features/calendar/application/add_event_controller.dart:26-56,113-132`
- Modify: `lib/features/calendar/application/event_details_controller.dart:40-75,290-315`

- [x] **Step 1: Write the status object**

Create `lib/features/clients/domain/models/client_search_status.dart`:

```dart
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';

part 'client_search_status.freezed.dart';

/// Which keyboard and which matcher the client field is using.
enum ClientQueryMode { phone, text }

/// Everything the picker renders about the current search EXCEPT the results
/// themselves, which stay on `clientResults` so the existing state contract and
/// its tests are untouched.
@freezed
abstract class ClientSearchStatus with _$ClientSearchStatus {
  const factory ClientSearchStatus({
    @Default(ClientQueryMode.phone) ClientQueryMode mode,
    @Default(0) int digitsTyped,
    @Default(false) bool failed,
    @Default('') String answeredQuery,
    PhoneRung? answeredRung,
  }) = _ClientSearchStatus;

  const ClientSearchStatus._();

  /// Digits typed, but not yet enough to send. The picker shows pips, not rows.
  bool get isHolding =>
      mode == ClientQueryMode.phone &&
      digitsTyped > 0 &&
      digitsTyped < PhoneQueryPolicy.minPhoneDigits;

  /// The answer came from a fallback rung, so these are near misses and must be
  /// labelled "closest numbers on file" rather than presented as matches.
  bool get isFallback =>
      answeredRung != null && answeredRung != PhoneRung.canonical;
}
```

- [x] **Step 2: Generate Freezed**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: `client_search_status.freezed.dart` written, no errors.

- [x] **Step 3: Add it to the state interface and the update object**

In `lib/features/calendar/application/appointment_form_concerns.dart`, add to
`abstract interface class AppointmentFormFields` (L15-22):

```dart
  ClientSearchStatus get clientSearchStatus;
```

Add to `AppointmentFormUpdate` (L26-54) — a nullable field plus the ctor param,
matching the existing style of the other nullable members:

```dart
  final ClientSearchStatus? clientSearchStatus;
```

- [x] **Step 4: Add it to both states**

`add_event_controller.dart`, in `AddEventState` beside `isSearchingClient`
(L44):

```dart
    @Default(ClientSearchStatus()) ClientSearchStatus clientSearchStatus,
```

`event_details_controller.dart`, in `EventDetailsState` beside
`isSearchingClient` (L65): the same line.

Then thread it through both `applyFormUpdate`s (`add_event_controller.dart`
L113-132 and `event_details_controller.dart` L290-315), in the same style as
the neighbouring fields:

```dart
      clientSearchStatus: update.clientSearchStatus ?? current.clientSearchStatus,
```

- [x] **Step 5: Regenerate and check the analyzer**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter analyze`
Expected: `No issues found!`

- [x] **Step 6: Commit**

```bash
git add lib/features/clients/domain/models/client_search_status.dart lib/features/calendar/application/
git commit -m "Carry client search status on the appointment form state"
```

---

### Task 6: The controller becomes the orchestrator

**Files:**
- Modify: `lib/features/calendar/application/appointment_form_concerns.dart:58-120`
- Test: `test/features/calendar/add_event_controller_test.dart` (extend the existing `group('searchClients')` at L197-241)

This is the task that removes the wasted reads, the stale rows and the
indistinguishable failure.

- [x] **Step 1: Write the failing tests**

Add to `test/features/calendar/add_event_controller_test.dart`, inside the
existing `group('searchClients')`. Use the same mock repository setup the
neighbouring tests already build — read them first and reuse their harness.

```dart
    test('a digits-only query under seven digits never hits the repository', () async {
      await controller.searchClients('514');
      await controller.searchClients('514562');
      verifyNever(() => repo.searchClients(any()));
      expect(controller.state.clientSearchStatus.isHolding, isTrue);
      expect(controller.state.clientSearchStatus.digitsTyped, 6);
    });

    test('a text query still searches from the first character', () async {
      when(() => repo.searchClients(any())).thenAnswer((_) async => []);
      await controller.searchClients('t');
      verify(() => repo.searchClients('t')).called(1);
      expect(controller.state.clientSearchStatus.mode, ClientQueryMode.text);
    });

    test('seven digits sends the canonical query once', () async {
      when(() => repo.searchClients(any())).thenAnswer((_) async => [marie]);
      await controller.searchClients('(514) 562-8');
      verify(() => repo.searchClients('5145628')).called(1);
      expect(controller.state.clientResults, [marie]);
      expect(controller.state.clientSearchStatus.answeredRung, PhoneRung.canonical);
    });

    test('a leading 1 is dropped before the query is sent', () async {
      when(() => repo.searchClients(any())).thenAnswer((_) async => [marie]);
      await controller.searchClients('1 514 562 8332');
      verify(() => repo.searchClients('5145628332')).called(1);
    });

    test('extra digits narrow the previous answer with no second call', () async {
      when(() => repo.searchClients('5145628'))
          .thenAnswer((_) async => [marie, jp]);
      await controller.searchClients('5145628');
      await controller.searchClients('5145628332');
      verify(() => repo.searchClients('5145628')).called(1);
      verifyNever(() => repo.searchClients('5145628332'));
      expect(controller.state.clientResults, [marie]);
    });

    // F5
    test('a truncated answer is re-queried rather than narrowed', () async {
      final full = List.generate(
        25,
        (i) => ClientRecord(id: 'c$i', name: '514562$i', phone: '514562$i'),
      );
      when(() => repo.searchClients('5145628')).thenAnswer((_) async => full);
      when(() => repo.searchClients('5145628332'))
          .thenAnswer((_) async => [marie]);
      await controller.searchClients('5145628');
      await controller.searchClients('5145628332');
      verify(() => repo.searchClients('5145628332')).called(1);
    });

    test('a miss at ten digits falls back to the first seven', () async {
      when(() => repo.searchClients('5145628233')).thenAnswer((_) async => []);
      when(() => repo.searchClients('5145628')).thenAnswer((_) async => [marie]);
      await controller.searchClients('5145628233');
      expect(controller.state.clientResults, [marie]);
      expect(controller.state.clientSearchStatus.answeredRung, PhoneRung.firstSeven);
      expect(controller.state.clientSearchStatus.isFallback, isTrue);
    });

    test('a miss on both seven-digit rungs leaves an honest empty', () async {
      when(() => repo.searchClients(any())).thenAnswer((_) async => []);
      await controller.searchClients('5145628233');
      expect(controller.state.clientResults, isEmpty);
      expect(controller.state.clientSearchStatus.failed, isFalse);
      expect(controller.state.clientSearchStatus.answeredRung, isNull);
    });

    test('a thrown search is flagged as failed, not as empty', () async {
      when(() => repo.searchClients(any())).thenThrow(Exception('boom'));
      await controller.searchClients('5145628332');
      expect(controller.state.clientSearchStatus.failed, isTrue);
      expect(controller.state.isSearchingClient, isFalse);
    });

    test('starting a new search clears the previous rows immediately', () async {
      when(() => repo.searchClients('5145628')).thenAnswer((_) async => [marie]);
      await controller.searchClients('5145628');
      expect(controller.state.clientResults, isNotEmpty);

      final gate = Completer<List<ClientRecord>>();
      when(() => repo.searchClients('4385551')).thenAnswer((_) => gate.future);
      final pending = controller.searchClients('4385551');
      expect(controller.state.clientResults, isEmpty,
          reason: 'stale rows must not stay tappable behind the spinner');
      expect(controller.state.isSearchingClient, isTrue);
      gate.complete([jp]);
      await pending;
      expect(controller.state.clientResults, [jp]);
    });
```

Add `import 'dart:async';` and the `PhoneRung` / `ClientQueryMode` imports at
the top of the test file if absent, and define `marie` / `jp` beside the
group's existing fixtures:

```dart
  final marie = ClientRecord(id: 'c1', name: 'Marie Tremblay', phone: '5145628332');
  final jp = ClientRecord(id: 'c2', name: 'J-P Gagnon', phone: '5145628901');
```

- [x] **Step 2: Run and confirm they fail**

Run: `flutter test test/features/calendar/add_event_controller_test.dart`
Expected: the new cases fail — the repository is called for `514`, no
`clientSearchStatus` is written, stale rows persist.

- [x] **Step 3: Rewrite `searchClients`**

Replace `searchClients` in
`lib/features/calendar/application/appointment_form_concerns.dart` (was
L80-108). Keep the existing `_searchRequestId` guard shape and the
resolve-before-await rule (Riverpod 3 `ref.read` after an await throws).

```dart
  ClientSearchWindow _clientWindow = ClientSearchWindow.empty;

  Future<void> searchClients(String query) async {
    final trimmed = query.trim();
    final isPhone = PhoneQueryPolicy.isPhoneQuery(trimmed);
    final digits = PhoneQueryPolicy.canonicalDigits(trimmed);
    final mode = isPhone ? ClientQueryMode.phone : ClientQueryMode.text;

    if (trimmed.isEmpty || (!isPhone && !ClientSearchPolicy.shouldSearch(trimmed))) {
      _searchRequestId++;
      _clientWindow = ClientSearchWindow.empty;
      _apply(AppointmentFormUpdate(
        clientResults: const [],
        isSearchingClient: false,
        clientSearchStatus: ClientSearchStatus(mode: mode),
      ));
      return;
    }

    // Too few digits to be selective: `514` matches the roster twice over and
    // costs 200 document reads to prove it. Hold, and say so.
    if (isPhone && digits.length < PhoneQueryPolicy.minPhoneDigits) {
      _searchRequestId++;
      _clientWindow = ClientSearchWindow.empty;
      _apply(AppointmentFormUpdate(
        clientResults: const [],
        isSearchingClient: false,
        clientSearchStatus: ClientSearchStatus(
          mode: mode,
          digitsTyped: digits.length,
        ),
      ));
      return;
    }

    // The candidate set only shrinks as digits land, so a complete previous
    // answer can be filtered instead of asked again.
    if (isPhone && _clientWindow.canNarrowTo(digits)) {
      _searchRequestId++;
      _clientWindow = _clientWindow.narrowTo(digits);
      _apply(AppointmentFormUpdate(
        clientResults: _clientWindow.results,
        isSearchingClient: false,
        clientSearchStatus: ClientSearchStatus(
          mode: mode,
          digitsTyped: digits.length,
          answeredQuery: digits,
          answeredRung: PhoneRung.canonical,
        ),
      ));
      return;
    }

    final logger = ref.read(loggerProvider);
    final repo = ref.read(clientsRepositoryProvider);
    final requestId = ++_searchRequestId;

    // Drop the previous rows NOW. Leaving them under the spinner is the only
    // way to attach a client from a half-typed query without noticing.
    _apply(const AppointmentFormUpdate(
      clientResults: [],
      isSearchingClient: true,
    ));

    final rungs = isPhone
        ? PhoneQueryPolicy.ladder(trimmed)
        : [(rung: PhoneRung.canonical, digits: trimmed)];

    try {
      for (final rung in rungs) {
        final results = await repo.searchClients(rung.digits);
        if (!ref.mounted || requestId != _searchRequestId) return;
        if (results.isEmpty && rung != rungs.last) continue;

        _clientWindow = isPhone && rung.rung == PhoneRung.canonical
            ? ClientSearchWindow(
                digits: digits,
                results: results,
                truncated: results.length >= ClientSearchPolicy.resultDisplayLimit,
              )
            : ClientSearchWindow.empty;

        _apply(AppointmentFormUpdate(
          clientResults: results,
          isSearchingClient: false,
          clientSearchStatus: ClientSearchStatus(
            mode: mode,
            digitsTyped: digits.length,
            answeredQuery: rung.digits,
            answeredRung: results.isEmpty ? null : rung.rung,
          ),
        ));
        if (results.isNotEmpty) return;
      }
    } catch (e, st) {
      logger.warn('CLI-SEARCH appointment form searchClients failed', e, st);
      if (!ref.mounted || requestId != _searchRequestId) return;
      _clientWindow = ClientSearchWindow.empty;
      // A failure that renders as "no clients found" is how a duplicate gets
      // created for a client who is already on file.
      _apply(AppointmentFormUpdate(
        clientResults: const [],
        isSearchingClient: false,
        clientSearchStatus: ClientSearchStatus(
          mode: mode,
          digitsTyped: digits.length,
          failed: true,
        ),
      ));
    }
  }
```

Also clear the window in `clearClient` (L122) so a new booking never narrows
from the last one:

```dart
    _clientWindow = ClientSearchWindow.empty;
```

- [x] **Step 4: Run the controller tests**

Run: `flutter test test/features/calendar/add_event_controller_test.dart`
Expected: `All tests passed!`, including the pre-existing stale-response guard
test at L224-231.

- [x] **Step 5: Commit**

```bash
git add lib/features/calendar/application/appointment_form_concerns.dart test/features/calendar/add_event_controller_test.dart
git commit -m "Hold short phone queries, narrow locally, and tell a failed search from an empty one"
```

---

### Task 6b: Rank what comes back (owner, 2026-09-05)

**Files:**
- Modify: `lib/features/clients/domain/policies/client_search_policy.dart` (add `scoreRecord`)
- Modify: `lib/features/clients/data/firebase_clients_repository.dart:304-309` (`_searchClientsCallable`)
- Test: `test/features/clients/data/client_search_relevance_test.dart`

The callable ends `orderBy("name")` (`indexed_search.js:112,116`) and
`_clientsFromCallable` does not re-sort, so **production results are
alphabetical**. `relevanceScore` exists and only the local fallback path — which
in practice means tests — ever runs it. This matters most where the new design
leans hardest: a fallback rung returns several near-miss rows, and the closest
number must not be third.

Sorting in the repository, not the controller, is what keeps the callable path
and the local path behaving the same.

- [x] **Step 1: Write the failing test**

Append to `test/features/clients/data/client_search_relevance_test.dart`:

```dart
  group('scoreRecord', () {
    final exact = ClientRecord(id: 'a', name: 'Zed Ltd', phone: '5145628332');
    final prefix = ClientRecord(id: 'b', name: 'Abe Inc', phone: '5145628901');
    final contains = ClientRecord(id: 'c', name: 'Bee Co', phone: '4385145628');

    int score(ClientRecord c, String query) => ClientSearchPolicy.scoreRecord(
      c,
      queryText: ClientSearchPolicy.normalize(query),
      queryDigits: ClientSearchPolicy.digitsOnly(query),
    );

    test('an exact phone beats a prefix, which beats a substring', () {
      expect(score(exact, '5145628332'), lessThan(score(prefix, '5145628332')));
      expect(score(prefix, '5145628'), lessThan(score(contains, '5145628')));
    });

    test('sorting by it puts the exact number first despite the name', () {
      final sorted = [prefix, contains, exact]
        ..sort((a, b) => score(a, '5145628332').compareTo(score(b, '5145628332')));
      expect(sorted.first.id, 'a');
    });
  });
```

- [x] **Step 2: Run and confirm it fails**

Run: `flutter test test/features/clients/data/client_search_relevance_test.dart`
Expected: `scoreRecord` is not defined.

- [x] **Step 3: Add the record-shaped scorer**

In `client_search_policy.dart`, beside `relevanceScore`:

```dart
  /// [relevanceScore] for a built record. The raw-map call site in the
  /// repository keeps its own projection; this is the one for callers that
  /// already hold a [ClientRecord], so neither has to re-spell the field list.
  static int scoreRecord(
    ClientRecord client, {
    required String queryText,
    required String queryDigits,
  }) {
    final entry = index(client);
    return relevanceScore(
      displayName: normalize(client.displayName),
      personName: normalize('${client.firstName} ${client.lastName}'),
      phoneDigits: entry.phoneDigits,
      contactsDigits: [
        for (final c in client.contacts)
          if (digitsOnly(c.phone).isNotEmpty) digitsOnly(c.phone),
      ],
      queryText: queryText,
      queryDigits: queryDigits,
    );
  }
```

- [x] **Step 4: Sort the callable's answer**

In `firebase_clients_repository.dart`, in `_searchClientsCallable`, sort before
returning. Keep display name as the tie-break so the order is stable:

```dart
    final queryText = ClientSearchPolicy.normalize(q);
    final queryDigits = ClientSearchPolicy.digitsOnly(q);
    records.sort((a, b) {
      final byScore = ClientSearchPolicy.scoreRecord(
        a,
        queryText: queryText,
        queryDigits: queryDigits,
      ).compareTo(ClientSearchPolicy.scoreRecord(
        b,
        queryText: queryText,
        queryDigits: queryDigits,
      ));
      if (byScore != 0) return byScore;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return records;
```

> This re-ranks the 25 the server chose; it does not change **which** 25 come
> back. The server's 200-doc read cap is still decided by `orderBy("name")`, so
> a very broad query is still answered from the alphabetically first slice. That
> bound is documented in the root `CLAUDE.md` and is out of scope here.

- [x] **Step 5: Run and commit**

Run: `flutter test test/features/clients/`
Expected: `All tests passed!`

```bash
git add lib/features/clients/domain/policies/client_search_policy.dart lib/features/clients/data/firebase_clients_repository.dart test/features/clients/data/client_search_relevance_test.dart
git commit -m "Rank callable search results by relevance instead of alphabetically"
```

---

### Task 7: Creating a client keeps the number dialable

**Files:**
- Modify: `lib/features/clients/domain/policies/client_name_policy.dart:244-258` (`_matchPhone`)
- Test: `test/features/clients/client_name_policy_test.dart`

Today `_matchPhone` requires **exactly ten digits**, so seeding the add-client
sheet from a seven- or eleven-digit query saves a client whose name is a number
and whose phone field is empty — the one record guaranteed never to be found
again.

- [x] **Step 1: Write the failing test**

Append to `test/features/clients/client_name_policy_test.dart`:

```dart
  group('liftPhoneFromName at other digit counts', () {
    test('a ten-digit number still lifts and formats', () {
      final lifted = ClientNamePolicy.liftPhoneFromName(
        name: '5145628332',
        phone: '',
      );
      expect(lifted!.phone, '(514) 562-8332');
    });

    test('a seven-digit number lifts rather than being left in the name', () {
      final lifted = ClientNamePolicy.liftPhoneFromName(
        name: '5628332',
        phone: '',
      );
      expect(lifted, isNotNull);
      expect(ClientSearchPolicy.digitsOnly(lifted!.phone), '5628332');
    });

    test('an eleven-digit typo still lifts', () {
      final lifted = ClientNamePolicy.liftPhoneFromName(
        name: '51456283322',
        phone: '',
      );
      expect(lifted, isNotNull);
      expect(ClientSearchPolicy.digitsOnly(lifted!.phone), '51456283322');
    });

    test('an international number still stays in the name', () {
      expect(
        ClientNamePolicy.liftPhoneFromName(name: '+33 6 12 34 56 78', phone: ''),
        isNull,
      );
    });

    test('too few digits to dial is not a phone', () {
      expect(
        ClientNamePolicy.liftPhoneFromName(name: '4820', phone: ''),
        isNull,
      );
    });

    test('a name with a number in it keeps the name', () {
      final lifted = ClientNamePolicy.liftPhoneFromName(
        name: 'Marie Tremblay 5145628332',
        phone: '',
      );
      expect(lifted!.name, 'Marie Tremblay');
      expect(lifted.phone, '(514) 562-8332');
    });
  });
```

- [x] **Step 2: Run and confirm the seven- and eleven-digit cases fail**

Run: `flutter test test/features/clients/client_name_policy_test.dart`
Expected: those two return null.

- [x] **Step 3: Widen the digit gate**

**Scope the widening to the whole-field case only.** `_candidate` feeds
`_matchPhone`, which feeds `liftPhoneFromName`, which the add-client name field
calls — so widening it unconditionally would also lift a seven-digit run out of
a *longer* name ("Local 8 4820123"). Ten digits inside a longer name stays the
rule; the new behaviour applies only when the field holds nothing but the
number, which is exactly the seeded-from-query case this fixes.

In `lib/features/clients/domain/policies/client_name_policy.dart`, add a
whole-field branch at the top of `_matchPhone` and leave the existing loop
alone:

```dart
  static ({int start, int end, String formatted})? _matchPhone(String text) {
    // The whole field is one number: seed-from-query. Anything dialable counts,
    // because leaving it in the name is what produced clients with nothing to
    // dial. formatPhoneNumber handles both ends — it formats progressively
    // under ten digits and appends anything past the tenth verbatim.
    final whole = text.trim();
    if (whole.isNotEmpty && !whole.contains('+')) {
      final digits = _digits(whole);
      if (digits.length == _digits(whole.replaceAll(_nonPhoneChar, '')).length &&
          digits.length >= 7 &&
          digits.length <= 15 &&
          !_hasLetter.hasMatch(whole)) {
        return (
          start: text.indexOf(whole),
          end: text.indexOf(whole) + whole.length,
          formatted: formatPhoneNumber(digits),
        );
      }
    }
    // A number embedded in a longer name still needs the full ten digits.
    for (final match in _candidate.allMatches(text)) {
      ...unchanged...
    }
  }
```

Add the two helper patterns beside the existing ones:

```dart
  static final _hasLetter = RegExp('[a-zA-Z]');
  static final _nonPhoneChar = RegExp(r'[^\d\s().\-]');
```

- [x] **Step 4: Run the whole name-policy and add-client suites**

Run: `flutter test test/features/clients/client_name_policy_test.dart test/features/clients/widgets/`
Expected: `All tests passed!` — `stripPhone` and `displayFor` share
`_candidate`, so a regression there shows up here.

- [x] **Step 5: Commit**

```bash
git add lib/features/clients/domain/policies/client_name_policy.dart test/features/clients/client_name_policy_test.dart
git commit -m "Lift a 7-15 digit number into the phone field when creating a client"
```

---

### Task 8: The strings

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`

- [x] **Step 1: Add the EN keys with their metadata blocks**

Add to `lib/l10n/app_en.arb`, keeping the `feature_keyName` convention and the
existing bucket prefixes (`calendar_`, `clients_`, `validation_`):

```json
  "clients_modePhone": "Phone",
  "@clients_modePhone": {
    "description": "Segment of the client picker's mode switch that opens the phone keypad."
  },
  "clients_modeNameOrAddress": "Name or address",
  "@clients_modeNameOrAddress": {
    "description": "Segment of the client picker's mode switch that opens the text keyboard and searches names, addresses, emails and contacts."
  },
  "clients_tapPhoneToStart": "Tap Phone to start",
  "@clients_tapPhoneToStart": {
    "description": "Placeholder in the add-job client field before it has focus."
  },
  "clients_digitsTyped": "{typed} of {total}",
  "@clients_digitsTyped": {
    "description": "Digit counter beside the client picker's number field.",
    "placeholders": {
      "typed": { "type": "int", "example": "8" },
      "total": { "type": "int", "example": "10" }
    }
  },
  "clients_keepGoing": "Keep going",
  "@clients_keepGoing": {
    "description": "Shown beside the digit pips while the typed number is still too short to search."
  },
  "clients_recentClients": "Recent",
  "@clients_recentClients": {
    "description": "Header above the recently booked clients shown before a search runs."
  },
  "clients_exactMatch": "Exact match",
  "@clients_exactMatch": {
    "description": "Header above a client result that matched the full phone number."
  },
  "clients_closestNumbers": "Closest numbers on file",
  "@clients_closestNumbers": {
    "description": "Header above near-miss results, shown when no client has the exact number typed."
  },
  "clients_matchCount": "{count, plural, =0{No matches} =1{1 match} other{{count} matches}}",
  "@clients_matchCount": {
    "description": "Count of clients matching the current query in the add-job picker.",
    "placeholders": { "count": { "type": "int", "example": "3" } }
  },
  "clients_tapToCarryOn": "tap to carry on",
  "@clients_tapToCarryOn": {
    "description": "Trailing hint on the collapsed match summary shown after the client field loses focus."
  },
  "clients_attach": "Attach",
  "@clients_attach": {
    "description": "Button on a client result row that attaches that client to the job."
  },
  "clients_searchFailed": "Couldn't check that number",
  "@clients_searchFailed": {
    "description": "Shown in the client picker when the search itself failed, so an empty result is not mistaken for a new customer."
  },
  "clients_retrySearch": "Try again",
  "@clients_retrySearch": {
    "description": "Action beside the client picker's failed-search message."
  },
  "clients_noneOfTheseNewClient": "None of these — new client",
  "@clients_noneOfTheseNewClient": {
    "description": "Last row of the client picker when near misses were offered, creating a client from the typed number."
  },
  "clients_changeClient": "Change",
  "@clients_changeClient": {
    "description": "Action on the attached-client card that reopens the picker."
  },
  "clients_removeClient": "Remove",
  "@clients_removeClient": {
    "description": "Destructive action on the attached-client card that detaches the client from the job."
  },
  "clients_jobsAndLastVisit": "{jobs, plural, =1{1 job} other{{jobs} jobs}} · last {date}",
  "@clients_jobsAndLastVisit": {
    "description": "Second line of the attached-client card: how many jobs this client has had and when the last one was.",
    "placeholders": {
      "jobs": { "type": "int", "example": "12" },
      "date": { "type": "String", "example": "14 Aug" }
    }
  },
  "calendar_jobAddress": "Job address",
  "@calendar_jobAddress": {
    "description": "Label of the address field in the add-job sheet's WHO section, under the attached client."
  },
  "calendar_useThisAddressForTheJob": "Use this address for the job",
  "@calendar_useThisAddressForTheJob": {
    "description": "Switch on the attached-client card that copies the client's own address into the job."
  },
  "calendar_beenHereBefore": "{name} has been here before",
  "@calendar_beenHereBefore": {
    "description": "Header above previous job addresses for the attached client, offered before a billed address lookup.",
    "placeholders": { "name": { "type": "String", "example": "Marie" } }
  },
  "calendar_unitsBilledToThisClient": "Units billed to this client",
  "@calendar_unitsBilledToThisClient": {
    "description": "Header above previous job addresses when they share a street and differ only by unit."
  },
  "calendar_searchForAnotherAddress": "Search for another address…",
  "@calendar_searchForAnotherAddress": {
    "description": "Row that opens the address autocomplete, below the client's previous job addresses."
  }
```

- [x] **Step 2: Add the FR translations in lockstep**

Add the same keys to `lib/l10n/app_fr.arb` (values only — `@key` blocks live in
the template):

```json
  "clients_modePhone": "Téléphone",
  "clients_modeNameOrAddress": "Nom ou adresse",
  "clients_tapPhoneToStart": "Touchez Téléphone pour commencer",
  "clients_digitsTyped": "{typed} sur {total}",
  "clients_keepGoing": "Continuez",
  "clients_recentClients": "Récents",
  "clients_exactMatch": "Correspondance exacte",
  "clients_closestNumbers": "Numéros les plus proches au dossier",
  "clients_matchCount": "{count, plural, =0{Aucune correspondance} =1{1 correspondance} other{{count} correspondances}}",
  "clients_tapToCarryOn": "touchez pour continuer",
  "clients_attach": "Associer",
  "clients_searchFailed": "Impossible de vérifier ce numéro",
  "clients_retrySearch": "Réessayer",
  "clients_noneOfTheseNewClient": "Aucun de ceux-ci — nouveau client",
  "clients_changeClient": "Modifier",
  "clients_removeClient": "Retirer",
  "clients_jobsAndLastVisit": "{jobs, plural, =1{1 tâche} other{{jobs} tâches}} · dernière {date}",
  "calendar_jobAddress": "Adresse de la tâche",
  "calendar_useThisAddressForTheJob": "Utiliser cette adresse pour la tâche",
  "calendar_beenHereBefore": "{name} y est déjà allé",
  "calendar_unitsBilledToThisClient": "Unités facturées à ce client",
  "calendar_searchForAnotherAddress": "Rechercher une autre adresse…"
```

- [x] **Step 3: Regenerate and check for drift**

The repo has a hook that runs `flutter gen-l10n` on ARB edits — do not run it
manually. Confirm the result:

Run: `cat lib/l10n/.gen/untranslated.json`
Expected: `{}`.

- [x] **Step 4: Commit**

```bash
git add lib/l10n/app_en.arb lib/l10n/app_fr.arb
git commit -m "Add the client picker and job address strings"
```

---

### Task 9: `ClientPicker` replaces `ClientSearchField`

**Files:**
- Create: `lib/features/clients/widgets/fields/client_picker.dart`
- Delete: `lib/features/clients/widgets/fields/client_search_field.dart`
- Delete: `test/features/clients/widgets/client_search_field_test.dart`
- Test: `test/features/clients/widgets/client_picker_test.dart`

The mode switch and the result row are **private widgets in this file**, not
their own files: each has exactly one caller, and the repo's rule is that three
similar lines beat a helper used once.

- [x] **Step 1: Write the failing widget test**

Create `test/features/clients/widgets/client_picker_test.dart`. Each test file
owns its local `_harness`; there is no shared `_scaledHarness`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/recent_client.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';
import 'package:scheduling/features/clients/widgets/fields/client_picker.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  final marie = ClientRecord(id: 'c1', name: 'Marie Tremblay', phone: '5145628332');
  final jp = ClientRecord(id: 'c2', name: 'J-P Gagnon', phone: '5145628901');
  const recents = <RecentClient>[
    (clientId: 'c1', name: 'Marie Tremblay', phone: '5145628332', address: ''),
  ];

  Widget harness({
    required TextEditingController controller,
    List<ClientRecord> results = const [],
    ClientSearchStatus status = const ClientSearchStatus(),
    List<RecentClient> recentClients = recents,
    bool isSearching = false,
    ValueChanged<ClientRecord>? onSelect,
    VoidCallback? onRetry,
    VoidCallback? onAddNew,
    double textScale = 1,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: ClientPicker(
          controller: controller,
          results: results,
          status: status,
          recentClients: recentClients,
          isSearching: isSearching,
          onChanged: (_) {},
          onModeChanged: (_) {},
          onSelect: onSelect ?? (_) {},
          onRetry: onRetry ?? () {},
          onAddNew: onAddNew,
        ),
      ),
    ),
  );

  testWidgets('at rest both mode segments are shown and neither is selected',
      (tester) async {
    await tester.pumpWidget(harness(controller: TextEditingController()));
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Name or address'), findsOneWidget);
    expect(find.text('Tap Phone to start'), findsOneWidget);
  });

  testWidgets('holding shows the digit tally and no rows', (tester) async {
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 5'),
      status: const ClientSearchStatus(digitsTyped: 4),
    ));
    expect(find.text('4 of 10'), findsOneWidget);
    expect(find.text('Keep going'), findsOneWidget);
    expect(find.text('Attach'), findsNothing);
  });

  testWidgets('recents are filtered by the typed digits while holding',
      (tester) async {
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '514'),
      status: const ClientSearchStatus(digitsTyped: 3),
    ));
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Marie Tremblay'), findsOneWidget);
  });

  testWidgets('an exact match is labelled and carries an Attach button',
      (tester) async {
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 562-8332'),
      results: [marie],
      status: const ClientSearchStatus(
        digitsTyped: 10,
        answeredQuery: '5145628332',
        answeredRung: PhoneRung.canonical,
      ),
    ));
    expect(find.text('Exact match'), findsOneWidget);
    expect(find.text('Attach'), findsOneWidget);
  });

  testWidgets('tapping the row attaches, and nothing attaches on its own',
      (tester) async {
    ClientRecord? attached;
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 562-8332'),
      results: [marie],
      status: const ClientSearchStatus(
        digitsTyped: 10,
        answeredRung: PhoneRung.canonical,
      ),
      onSelect: (c) => attached = c,
    ));
    expect(attached, isNull, reason: 'never auto-attach');
    await tester.tap(find.text('Attach'));
    await tester.pump();
    expect(attached, marie);
  });

  testWidgets('a fallback answer is labelled as closest, not as matches',
      (tester) async {
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 562-8233'),
      results: [marie, jp],
      status: const ClientSearchStatus(
        digitsTyped: 10,
        answeredQuery: '5145628',
        answeredRung: PhoneRung.firstSeven,
      ),
      onAddNew: () {},
    ));
    expect(find.text('Closest numbers on file'), findsOneWidget);
    expect(find.text('None of these — new client'), findsOneWidget);
  });

  testWidgets('a failed search is not an empty one', (tester) async {
    var retried = false;
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 562-8332'),
      status: const ClientSearchStatus(digitsTyped: 10, failed: true),
      onRetry: () => retried = true,
    ));
    expect(find.text("Couldn't check that number"), findsOneWidget);
    expect(find.text('No clients found'), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('add-new is absent when the host offers no callback',
      (tester) async {
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 562-8233'),
      results: const [],
      status: const ClientSearchStatus(digitsTyped: 10),
    ));
    expect(find.textContaining('new client'), findsNothing);
  });

  testWidgets('no overflow on a small phone at 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(harness(
      controller: TextEditingController(text: '(514) 562-8332'),
      results: [marie, jp],
      status: const ClientSearchStatus(
        digitsTyped: 10,
        answeredRung: PhoneRung.canonical,
      ),
      textScale: 2,
    ));
    expect(tester.takeException(), isNull);
  });
}
```

- [x] **Step 2: Run and confirm it fails**

Run: `flutter test test/features/clients/widgets/client_picker_test.dart`
Expected: compile failure — `client_picker.dart` does not exist.

- [x] **Step 3: Write the picker**

Create `lib/features/clients/widgets/fields/client_picker.dart`. Points the
implementation must hold, each pinned by a test above:

- Two segments rendered whether or not the field has focus, so choosing a name
  search never opens a phone pad first (that is what keeps the
  `keyboardType` swap off the common path).
- `keyboardType: status.mode == ClientQueryMode.phone ? TextInputType.phone : TextInputType.text`, and an input formatter applying `formatPhoneNumber` live in phone mode.
- The field is wrapped in `SheetFocusScroll` **by the host**, not here.
- Never call `FocusScope.of(context).unfocus()` except from the attach handler.
- The list section header is `clients_recentClients` while `status.isHolding`, `clients_closestNumbers` when `status.isFallback`, `clients_exactMatch` otherwise.
- `status.failed` renders `clients_searchFailed` plus a `clients_retrySearch` action and **no** empty-state text.
- The add-new row is last, and only when `onAddNew != null`.
- No `ListTile` inside a decorated panel — the panel paints its own background (`ListTile` asserts).

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/features/calendar/domain/models/recent_client.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';
import 'package:scheduling/l10n/l10n.dart';

class ClientPicker extends StatelessWidget {
  const ClientPicker({
    required this.controller,
    required this.results,
    required this.status,
    required this.recentClients,
    required this.isSearching,
    required this.onChanged,
    required this.onModeChanged,
    required this.onSelect,
    required this.onRetry,
    super.key,
    this.errorText,
    this.onAddNew,
  });

  final TextEditingController controller;
  final List<ClientRecord> results;
  final ClientSearchStatus status;
  final List<RecentClient> recentClients;
  final bool isSearching;
  final ValueChanged<String> onChanged;
  final ValueChanged<ClientQueryMode> onModeChanged;
  final ValueChanged<ClientRecord> onSelect;
  final VoidCallback onRetry;
  final String? errorText;
  final VoidCallback? onAddNew;

  @override
  Widget build(BuildContext context) {
    // Build the segments, the field and the body below it. Full body omitted
    // here only because the three sections are described above and each is
    // pinned by a named test; write them against those tests.
    throw UnimplementedError();
  }
}
```

> **This is the one step in the plan that does not carry finished code.** Write
> the widget against the ten tests in Step 1 — they specify every string, every
> branch and the overflow constraint. Match the visual language of the mockup
> and the existing `AppSearchBar` / `SheetPanel` idioms. Do not add a state the
> tests do not name.

- [x] **Step 4: Run the picker tests**

Run: `flutter test test/features/clients/widgets/client_picker_test.dart`
Expected: `All tests passed!`

- [x] **Step 5: Delete the old field and its test**

```bash
git rm lib/features/clients/widgets/fields/client_search_field.dart test/features/clients/widgets/client_search_field_test.dart
```

Run: `flutter analyze`
Expected: one error per remaining `ClientSearchField` reference — there should
be exactly one, in `appointment_form_fields.dart`. Task 12 fixes it. If the
analyzer reports more, stop and list them.

- [x] **Step 6: Commit**

```bash
git add lib/features/clients/widgets/fields/client_picker.dart test/features/clients/widgets/client_picker_test.dart
git commit -m "Replace ClientSearchField with ClientPicker: mode switch, tally, honest empty and failure states"
```

---

### Task 10: `SelectedClientCard`

**Files:**
- Create: `lib/features/clients/widgets/cards/selected_client_card.dart`
- Test: `test/features/clients/widgets/selected_client_card_test.dart`

- [x] **Step 1: Write the failing test**

Create `test/features/clients/widgets/selected_client_card_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/cards/selected_client_card.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  final marie = ClientRecord(
    id: 'c1',
    name: 'Marie Tremblay',
    phone: '5145628332',
    address: '4820 rue Wellington',
    city: 'Verdun',
    jobCount: 12,
  );

  Widget harness({
    required ClientRecord client,
    bool useClientAddress = true,
    VoidCallback? onChange,
    VoidCallback? onRemove,
    ValueChanged<bool>? onUseClientAddressChanged,
    double textScale = 1,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SelectedClientCard(
          client: client,
          useClientAddress: useClientAddress,
          lastVisitLabel: '14 Aug',
          onChange: onChange ?? () {},
          onRemove: onRemove ?? () {},
          onUseClientAddressChanged: onUseClientAddressChanged ?? (_) {},
        ),
      ),
    ),
  );

  testWidgets('the number is the headline and the name is the qualifier',
      (tester) async {
    await tester.pumpWidget(harness(client: marie));
    expect(find.text('(514) 562-8332'), findsOneWidget);
    expect(find.textContaining('Marie Tremblay'), findsOneWidget);
    expect(find.textContaining('12 jobs'), findsOneWidget);
  });

  testWidgets('the address switch reports both directions', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(harness(
      client: marie,
      onUseClientAddressChanged: changes.add,
    ));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(changes, [false]);
  });

  testWidgets('the declined address stays visible when the switch is off',
      (tester) async {
    await tester.pumpWidget(harness(client: marie, useClientAddress: false));
    expect(find.textContaining('4820 rue Wellington'), findsOneWidget);
  });

  testWidgets('Change and Remove both fire', (tester) async {
    var changed = false;
    var removed = false;
    await tester.pumpWidget(harness(
      client: marie,
      onChange: () => changed = true,
      onRemove: () => removed = true,
    ));
    await tester.tap(find.text('Change'));
    await tester.tap(find.text('Remove'));
    expect(changed, isTrue);
    expect(removed, isTrue);
  });

  testWidgets('a client with no job count omits the count rather than showing 0',
      (tester) async {
    await tester.pumpWidget(harness(
      client: marie.copyWith(jobCount: null),
    ));
    expect(find.textContaining('0 jobs'), findsNothing);
  });

  testWidgets('no overflow at 260px and 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(harness(client: marie, textScale: 2));
    expect(tester.takeException(), isNull);
  });
}
```

- [x] **Step 2: Run and confirm it fails**

Run: `flutter test test/features/clients/widgets/selected_client_card_test.dart`
Expected: compile failure — the card does not exist.

- [x] **Step 3: Write the card**

Create `lib/features/clients/widgets/cards/selected_client_card.dart`. Build it
on `appCardDecoration(theme)` and `theme.monoType` for the number; the actions
row is two text buttons split by a divider, the destructive one taking
`scheme.error` via the palette rule (`palette.dangerFill` is for FILLED
destructive buttons — a text action uses `scheme.error`). Reuse `AppAvatar` for
the leading circle; do not hand-roll initials-on-colour.

```dart
class SelectedClientCard extends StatelessWidget {
  const SelectedClientCard({
    required this.client,
    required this.useClientAddress,
    required this.onChange,
    required this.onRemove,
    required this.onUseClientAddressChanged,
    super.key,
    this.lastVisitLabel,
  });

  final ClientRecord client;
  final bool useClientAddress;
  final String? lastVisitLabel;
  final VoidCallback onChange;
  final VoidCallback onRemove;
  final ValueChanged<bool> onUseClientAddressChanged;
  // ...
}
```

> As in Task 9, write the body against the six tests. The one rule that is not
> obvious from them: the card must not render an address row at all when
> `client.address` is blank — read-only detail bodies omit empty sections rather
> than showing "None".

- [x] **Step 4: Run the test and commit**

Run: `flutter test test/features/clients/widgets/selected_client_card_test.dart`
Expected: `All tests passed!`

```bash
git add lib/features/clients/widgets/cards/selected_client_card.dart test/features/clients/widgets/selected_client_card_test.dart
git commit -m "Add SelectedClientCard: number-led confirmation with the address switch"
```

---

### Task 11: The job address moves into WHO

**Files:**
- Create: `lib/features/calendar/widgets/sections/job_address_section.dart`
- Test: `test/features/calendar/widgets/sections/job_address_section_test.dart`
- Modify: `lib/features/calendar/widgets/sections/appointment_form_fields.dart:504-516` (remove from `_detailsBody`)

This is the largest single edit in the plan and the one the owner signed off
separately. `AppointmentAddressField` is **not** deleted — it keeps the pill and
autocomplete branch, and `JobAddressSection` wraps it with the
previous-addresses panel.

- [x] **Step 1: Write the failing test**

Create `test/features/calendar/widgets/sections/job_address_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/widgets/sections/job_address_section.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  final marie = ClientRecord(
    id: 'c1',
    name: 'Marie Tremblay',
    firstName: 'Marie',
    phone: '5145628332',
    address: '4820 rue Wellington',
    city: 'Verdun',
  );

  Widget harness({
    required bool useCustomAddress,
    List<String> previousAddresses = const [],
    ValueChanged<String>? onPickPrevious,
    double textScale = 1,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: JobAddressSection(
          selectedClient: marie,
          useCustomAddress: useCustomAddress,
          addressController: TextEditingController(),
          previousAddresses: previousAddresses,
          onPickPrevious: onPickPrevious ?? (_) {},
          onSwitchToCustom: () {},
          onUseClientAddress: () {},
        ),
      ),
    ),
  );

  testWidgets('with the client address in use, no previous list is offered',
      (tester) async {
    await tester.pumpWidget(harness(
      useCustomAddress: false,
      previousAddresses: const ['1250 boul. LaSalle'],
    ));
    expect(find.textContaining('has been here before'), findsNothing);
  });

  testWidgets('switching off offers the client previous job addresses first',
      (tester) async {
    await tester.pumpWidget(harness(
      useCustomAddress: true,
      previousAddresses: const ['1250 boul. LaSalle', '88 rue de l\'Église'],
    ));
    expect(find.text('Marie has been here before'), findsOneWidget);
    expect(find.text('1250 boul. LaSalle'), findsOneWidget);
    expect(find.text('Search for another address…'), findsOneWidget);
  });

  testWidgets('tapping a previous address reports it', (tester) async {
    String? picked;
    await tester.pumpWidget(harness(
      useCustomAddress: true,
      previousAddresses: const ['1250 boul. LaSalle'],
      onPickPrevious: (a) => picked = a,
    ));
    await tester.tap(find.text('1250 boul. LaSalle'));
    expect(picked, '1250 boul. LaSalle');
  });

  testWidgets('with no history the autocomplete is the whole section',
      (tester) async {
    await tester.pumpWidget(harness(useCustomAddress: true));
    expect(find.textContaining('has been here before'), findsNothing);
    expect(find.text('Search for another address…'), findsNothing);
  });

  testWidgets('no overflow at 260px and 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(harness(
      useCustomAddress: true,
      previousAddresses: const ['1250 boul. LaSalle', '88 rue de l\'Église'],
      textScale: 2,
    ));
    expect(tester.takeException(), isNull);
  });
}
```

- [x] **Step 2: Run and confirm it fails**

Run: `flutter test test/features/calendar/widgets/sections/job_address_section_test.dart`
Expected: compile failure.

- [x] **Step 3: Write the section**

Create `lib/features/calendar/widgets/sections/job_address_section.dart`,
wrapping `AppointmentAddressField` and adding the previous-address panel above
it when `useCustomAddress` is true and `previousAddresses` is non-empty. Write
it against the five tests. Unit grouping is **not** in this task — a previous
address renders in full; forcing a unit column when the street part does not
group cleanly is the failure mode the design doc names.

- [x] **Step 4: Remove the address from the details section**

In `lib/features/calendar/widgets/sections/appointment_form_fields.dart`,
delete the `AppointmentAddressField(...)` block and its trailing
`SizedBox(height: AppSpacing.sp16)` from `_detailsBody` (was L506-516). Leave
`_switchToCustomAddress` and `_useClientAddress` where they are — Task 12
passes them to the new section.

- [x] **Step 5: Run the tests**

Run: `flutter test test/features/calendar/widgets/sections/`
Expected: `job_address_section_test.dart` passes.
`appointment_form_fields_test.dart` will FAIL — it has an address-in-details
expectation and the file does not compile yet. That is Task 12.

- [x] **Step 6: Commit**

```bash
git add lib/features/calendar/widgets/sections/job_address_section.dart test/features/calendar/widgets/sections/job_address_section_test.dart lib/features/calendar/widgets/sections/appointment_form_fields.dart
git commit -m "Add JobAddressSection with previous job addresses; drop the address from the details section"
```

---

### Task 11b: Group previous addresses by unit (owner, 2026-09-05)

**Files:**
- Create: `lib/features/calendar/domain/policies/previous_address_policy.dart`
- Test: `test/features/calendar/domain/previous_address_policy_test.dart`
- Modify: `lib/features/calendar/widgets/sections/job_address_section.dart`

A building client's forty jobs are forty units at one street. `AddressParser`
already parses this — `splitApt(String) -> AptAddress?` with `.apt` and
`.street`, handling the saved, labeled, dash and trailing forms — so no new
parsing is needed. **The whole risk is mis-grouping**, so the policy groups only
when it is sure and falls back to full rows otherwise.

- [x] **Step 1: Write the failing test**

Create `test/features/calendar/domain/previous_address_policy_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/policies/previous_address_policy.dart';

void main() {
  group('groupPreviousAddresses', () {
    test('two or more units on one street group under it', () {
      final grouped = groupPreviousAddresses(const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 210',
        '1751 rue Richardson, unit 118',
      ]);
      expect(grouped.sharedStreet, '1751 rue Richardson');
      expect(grouped.rows.map((r) => r.unit).toList(), ['404', '210', '118']);
    });

    test('order is preserved, newest first as given', () {
      final grouped = groupPreviousAddresses(const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 210',
      ]);
      expect(grouped.rows.first.unit, '404');
    });

    test('different streets do not group', () {
      final grouped = groupPreviousAddresses(const [
        '1250 boul. LaSalle',
        "88 rue de l'Église",
      ]);
      expect(grouped.sharedStreet, isNull);
      expect(grouped.rows.map((r) => r.full).toList(), [
        '1250 boul. LaSalle',
        "88 rue de l'Église",
      ]);
    });

    // The mis-grouping guard: one street shared but one address has no unit,
    // so a reader could not tell the rows apart in a unit column.
    test('a street shared by an address with no unit does not group', () {
      final grouped = groupPreviousAddresses(const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson',
      ]);
      expect(grouped.sharedStreet, isNull);
    });

    test('a single address never groups', () {
      final grouped = groupPreviousAddresses(const ['1751 rue Richardson, unit 404']);
      expect(grouped.sharedStreet, isNull);
      expect(grouped.rows.single.full, '1751 rue Richardson, unit 404');
    });

    test('two units on one street plus an unrelated address does not group', () {
      final grouped = groupPreviousAddresses(const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 210',
        '1250 boul. LaSalle',
      ]);
      expect(grouped.sharedStreet, isNull);
    });

    test('duplicate units collapse to one row', () {
      final grouped = groupPreviousAddresses(const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 210',
      ]);
      expect(grouped.rows, hasLength(2));
    });

    test('blank entries are dropped', () {
      final grouped = groupPreviousAddresses(const ['', '   ', '1250 boul. LaSalle']);
      expect(grouped.rows, hasLength(1));
    });

    test('an empty list yields no rows and no street', () {
      final grouped = groupPreviousAddresses(const []);
      expect(grouped.rows, isEmpty);
      expect(grouped.sharedStreet, isNull);
    });
  });
}
```

- [x] **Step 2: Run and confirm it fails**

Run: `flutter test test/features/calendar/domain/previous_address_policy_test.dart`
Expected: the policy file does not exist.

- [x] **Step 3: Write the policy**

Create `lib/features/calendar/domain/policies/previous_address_policy.dart`:

```dart
import 'package:scheduling/features/maps/domain/address_parser.dart';

/// One previous job address, with its unit lifted out when the whole list
/// shares a street.
typedef PreviousAddressRow = ({String full, String? unit});

/// The rows to render, and the street they all share when they do.
typedef PreviousAddressList = ({String? sharedStreet, List<PreviousAddressRow> rows});

/// Groups a client's previous job addresses by street, but ONLY when every
/// entry shares one street AND every entry names a unit.
///
/// A mis-grouped address reads as a different building, so the bar is
/// deliberately high: any address without a unit, any second street, or fewer
/// than two entries and the list renders in full instead.
PreviousAddressList groupPreviousAddresses(List<String> addresses) {
  final seen = <String>{};
  final cleaned = [
    for (final raw in addresses)
      if (raw.trim().isNotEmpty && seen.add(raw.trim())) raw.trim(),
  ];
  if (cleaned.length < 2) {
    return (
      sharedStreet: null,
      rows: [for (final a in cleaned) (full: a, unit: null)],
    );
  }

  final splits = [for (final a in cleaned) AddressParser.splitApt(a)];
  final streets = <String>{};
  for (var i = 0; i < cleaned.length; i++) {
    final split = splits[i];
    if (split == null || split.apt.isEmpty) {
      return (
        sharedStreet: null,
        rows: [for (final a in cleaned) (full: a, unit: null)],
      );
    }
    streets.add(split.street.toLowerCase());
  }
  if (streets.length != 1) {
    return (
      sharedStreet: null,
      rows: [for (final a in cleaned) (full: a, unit: null)],
    );
  }

  final unitSeen = <String>{};
  final rows = <PreviousAddressRow>[];
  for (var i = 0; i < cleaned.length; i++) {
    final split = splits[i]!;
    if (!unitSeen.add(split.apt.toLowerCase())) continue;
    rows.add((full: cleaned[i], unit: split.apt));
  }
  return (sharedStreet: splits.first!.street, rows: rows);
}
```

- [x] **Step 4: Run the policy test**

Run: `flutter test test/features/calendar/domain/previous_address_policy_test.dart`
Expected: `All tests passed!`

> If a case fails because `splitApt` parses "unit 404" differently than assumed,
> fix the **test data** to the real forms `splitApt` accepts (read its four
> regexes) — do not weaken the guard assertions.

- [x] **Step 5: Render the grouped form**

In `job_address_section.dart`, run `previousAddresses` through
`groupPreviousAddresses`. When `sharedStreet` is non-null, the panel header is
`calendar_unitsBilledToThisClient` and each row shows the unit in a mono
leading column with the street once in the header; otherwise the header stays
`calendar_beenHereBefore` and rows render `full`. `onPickPrevious` always
reports the **full** address, never the unit alone.

- [x] **Step 6: Extend the section test**

Add to `test/features/calendar/widgets/sections/job_address_section_test.dart`:

```dart
  testWidgets('units on one street render under a shared street header',
      (tester) async {
    await tester.pumpWidget(harness(
      useCustomAddress: true,
      previousAddresses: const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 210',
      ],
    ));
    expect(find.text('Units billed to this client'), findsOneWidget);
    expect(find.text('404'), findsOneWidget);
    expect(find.textContaining('has been here before'), findsNothing);
  });

  testWidgets('picking a unit row reports the full address', (tester) async {
    String? picked;
    await tester.pumpWidget(harness(
      useCustomAddress: true,
      previousAddresses: const [
        '1751 rue Richardson, unit 404',
        '1751 rue Richardson, unit 210',
      ],
      onPickPrevious: (a) => picked = a,
    ));
    await tester.tap(find.text('404'));
    expect(picked, '1751 rue Richardson, unit 404');
  });
```

- [x] **Step 7: Run and commit**

Run: `flutter test test/features/calendar/`
Expected: `All tests passed!`

```bash
git add lib/features/calendar/domain/policies/previous_address_policy.dart lib/features/calendar/widgets/sections/job_address_section.dart test/features/calendar/domain/previous_address_policy_test.dart test/features/calendar/widgets/sections/job_address_section_test.dart
git commit -m "Group a client's previous job addresses by unit when they share a street"
```

---

### Task 12: Wire the WHO section and both hosts

**Files:**
- Modify: `lib/features/calendar/widgets/sections/appointment_form_fields.dart:104-235,339-358`
- Modify: `lib/features/calendar/widgets/sheets/add_appointment_sheet.dart:114-121,306-341`
- Modify: `lib/features/calendar/widgets/views/details_edit_body.dart:72-84,189-206`
- Test: `test/features/calendar/widgets/sections/appointment_form_fields_test.dart`, `test/features/calendar/widgets/add_appointment_sheet_seed_test.dart`

- [x] **Step 1: Extend the widget's parameters**

In `appointment_form_fields.dart`, add beside the existing client params (L148-153):

```dart
  final ClientSearchStatus clientSearchStatus;
  final List<RecentClient> recentClients;
  final List<String> previousAddresses;
  final String? lastVisitLabel;
```

Add to `AppointmentFormCallbacks` (L68-101), beside `onSearchClients` (L88):

```dart
  final ValueChanged<ClientQueryMode> onClientQueryModeChanged;
  final VoidCallback onRetryClientSearch;
  final ValueChanged<String> onPickPreviousAddress;
```

- [x] **Step 2: Rewrite the client block in `_whoSection`**

Replace the `ClientSearchField` block (L339-358) with a branch: the card when a
client is attached, the picker when not. Both stay inside the existing
`_tour(TourStepId.apptClient, ...)` wrapper so the tour still has a target.

```dart
    if (!isPersonal) ...[
      formLabel(context, l10n.calendar_client, required: true),
      _tour(
        TourStepId.apptClient,
        selectedClient == null
            ? SheetFocusScroll(
                child: ClientPicker(
                  controller: controllers.clientSearch,
                  results: clientResults,
                  status: clientSearchStatus,
                  recentClients: recentClients,
                  isSearching: isSearchingClient,
                  onChanged: callbacks.onSearchClients,
                  onModeChanged: callbacks.onClientQueryModeChanged,
                  onSelect: _selectClient,
                  onRetry: callbacks.onRetryClientSearch,
                  errorText: _err(context, 'client'),
                  onAddNew: onRequestAddClient == null ? null : _addNewClient,
                ),
              )
            : SelectedClientCard(
                client: selectedClient!,
                useClientAddress: !useCustomAddress,
                lastVisitLabel: lastVisitLabel,
                onChange: _clearClient,
                onRemove: _clearClient,
                onUseClientAddressChanged: (useIt) =>
                    useIt ? _useClientAddress() : _switchToCustomAddress(),
              ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      formLabel(context, l10n.calendar_jobAddress, required: !isPersonal),
      const SizedBox(height: AppSpacing.sp4),
      JobAddressSection(
        selectedClient: selectedClient,
        useCustomAddress: useCustomAddress,
        addressController: controllers.address,
        previousAddresses: previousAddresses,
        onPickPrevious: callbacks.onPickPreviousAddress,
        onSwitchToCustom: _switchToCustomAddress,
        onUseClientAddress: _useClientAddress,
      ),
      const SizedBox(height: AppSpacing.sp16),
    ],
```

> `_selectClient` (L216-221) still sets `controllers.clientSearch.text` and
> `controllers.address.text` and calls `callbacks.onSelectClient` — leave it
> alone. That is what keeps `EventDetailsState`'s three-field contract intact
> (F4). Add one line to it: `FocusScope.of(context).unfocus();` — attaching is
> the ONLY thing allowed to dismiss the keyboard.

Also note: a **personal** job has no client but may still have an address. The
`isPersonal` branch above hides the address with the client. Keep a separate
`if (isPersonal && !isDayOff)` block rendering `JobAddressSection` with a null
client and `optional: true`, matching what `_detailsBody` did before.

- [x] **Step 3: Wire `add_appointment_sheet.dart`**

Replace `_onClientSearchChanged` (L114-121) so an empty query still cancels, and
add the two new handlers:

```dart
  void _onClientSearchChanged(String query) {
    if (query.trim().isEmpty) {
      _clientSearchDebounce.cancel();
      _notifier.searchClients('');
      return;
    }
    _clientSearchDebounce.run(() => _notifier.searchClients(query));
  }

  void _onClientQueryModeChanged(ClientQueryMode mode) {
    // Swapping keyboardType on a focused field does not reliably swap the
    // software keyboard, so drop focus and let the rebuilt field take it back.
    FocusScope.of(context).unfocus();
    _controllers.clientSearch.clear();
    _notifier.setClientQueryMode(mode);
  }

  void _onRetryClientSearch() =>
      _notifier.searchClients(_controllers.clientSearch.text);
```

Pass the new state and callbacks at the existing wiring sites (L306-341), and
watch the recents:

```dart
    final recents = ref.watch(recentClientsProvider).value ?? const [];
```

- [x] **Step 4: Wire `details_edit_body.dart` identically**

Same three handlers, resolving the notifier per call as the existing handler
does (L73-77). This file has **no test of its own** — that is the known coverage
gap, so read the add-sheet version and mirror it exactly rather than improvising.

- [x] **Step 5: Update the existing widget tests**

`appointment_form_fields_test.dart` has an address-in-details expectation and a
client-picker expectation. Update both to the new structure; keep every other
case, especially "inline add-client auto-selects the created client" (L169),
"switching to personal drops the CLIENT address" (L363) and the picker
validation-error case.

`add_appointment_sheet_seed_test.dart` asserts the prefilled client field and
the address pill. With a prefilled client the WHO section now renders
`SelectedClientCard`, so the assertions move from the text field to the card.

- [x] **Step 6: Run the calendar suites**

Run: `flutter test test/features/calendar/`
Expected: `All tests passed!`

- [x] **Step 7: Commit**

```bash
git add lib/features/calendar/ test/features/calendar/
git commit -m "Render the client picker, card and job address in the WHO section"
```

---

### Task 13: Tour copy, the design doc, and the rules

**Files:**
- Modify: the ARB entry for `TourStepId.apptClient`'s description
- Modify: `docs/plans/2026-09-05-add-job-client-picker.md`
- Modify: `.claude/rules/clients.md`

- [x] **Step 1: Confirm the design doc already carries the corrected ladder**

`docs/plans/2026-09-05-add-job-client-picker.md` was corrected on 2026-09-05
when this plan was written — its "On a miss" section names first-seven then
last-seven and records why. Read it and confirm; if it still says "last four",
fix it to match Task 1 before continuing. An `AppDestination`/`TourForm` member
name IS a tour storage key, so do not rename anything while editing copy.

- [x] **Step 2: Update the tour step description**

`TourStepId.apptClient` points at the client field. Its ARB description
describes a search box that no longer exists. Rewrite the EN value and its FR
twin to describe entering a phone number and tapping a match, and regenerate
(the ARB hook runs `gen-l10n`).

- [x] **Step 3: Record the new rules**

Add to `.claude/rules/clients.md`, in the client-search area:

```markdown
- **The add-job picker sends a SLICE of the typed number, not the string.**
  `PhoneQueryPolicy` drops a leading `1`, holds anything under 7 digits (a bare
  area code matches the roster twice over and costs 200 reads to prove it), and
  on a miss at 10+ digits retries the **first seven** then the **last seven**.
  First seven, not last four: a typo lands in the tail, so the head is the slice
  that survives it — `5145628233` against a stored `5145628332` misses on
  last-7 and last-4 and hits on first-7. Results from a fallback rung are
  "closest numbers on file", never matches.
- **A complete answer is narrowed locally; a truncated one is re-queried.**
  Phone matching is a substring test, so the candidate set only shrinks as
  digits land — `ClientSearchWindow.canNarrowTo` is the one owner of that, and
  it refuses when the previous answer hit `resultDisplayLimit`, because at the
  cap the client being looked for may never have come back.
- **`ClientSearchEntry.phoneDigits` is ONE ENTRY PER NUMBER.** Joining `phone`,
  `mobile` and contact phones let a query straddle the seam and match a number
  nobody has, and made `relevanceScore`'s exact tier unreachable for anyone with
  two numbers. Three sites had the blob — `ClientSearchPolicy.index`, the
  repository's relevance call site, and `recordMatchesQuery` in
  `functions/search_tokens.js`. Keep all three split.
- **A failed client search must not render as an empty one.**
  `ClientSearchStatus.failed` exists because "No clients found" on the booking
  path reads as "new customer", and that is how a duplicate gets created for a
  client already on file — carrying a number that can then never be searched.
- **Recents are free or they are nothing.** `recentClientsProvider` builds them
  from appointments' denormalized `clientId`/`clientName`/`clientPhone`, so
  showing them costs no client reads. It returns empty for a non-admin: the
  query carries no `employeeIds` constraint and adding one would need a new
  composite index.
```

- [x] **Step 4: Commit**

```bash
git add docs/plans/ .claude/rules/clients.md lib/l10n/
git commit -m "Record the picker rules and correct the fallback ladder in the design doc"
```

---

### Task 14: Full verification

- [x] **Step 1: BOM scan**

```bash
git diff --name-only HEAD~15 -- '*.dart' | while read -r f; do
  [ -f "$f" ] && [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && echo "BOM: $f"
done
```

Expected: no output.

- [x] **Step 2: Analyzer**

Run: `flutter analyze`
Expected: `No issues found!` — that is this repo's baseline, so any lint is from
this work.

- [x] **Step 3: Dead references to the deleted field**

Run: `grep -rn "ClientSearchField" lib test`
Expected: no output.

- [x] **Step 4: l10n drift**

Run: `cat lib/l10n/.gen/untranslated.json`
Expected: `{}`.

- [x] **Step 5: Full Flutter suite**

Run: `flutter test`
Expected: `All tests passed!`, at a count at or above the 3288 recorded on
2026-09-05.

- [x] **Step 6: Functions**

Run: `npm --prefix functions run lint && npm --prefix functions test`
Expected: eslint clean; all suites pass, at or above 1754.

- [x] **Step 7: Report the deploy prerequisites, do NOT deploy**

Report, do not run:

1. `functions/search_tokens.js` changed (`recordMatchesQuery`), so
   **`searchClients` and `searchHistory` must be redeployed** before an app
   build relying on the split reaches the fleet. The change is a tightening —
   it stops matching numbers nobody has — so an old app against a new backend is
   safe, and a new app against an old backend merely keeps the seam bug. There
   is no ordering hazard either way.
2. **No new Firestore index is required.** `appointments.createdAt` keeps
   default single-field indexing (verified in Task 4 Step 1). Confirm that is
   still true at deploy time.
3. No `assertPayloadShape` allowlist changed, so no `#compat` carve-out is
   needed.
4. Never pass `--force` to a Firestore deploy — it deletes TTL policies missing
   from `firestore.indexes.json` (all five went once, 2026-07-21).

- [ ] **Step 8: Device pass the two things a widget test cannot prove** (NOT
  RUN — Mac/device gated; both remain open)

Neither is coverable in `flutter test`; both are named risks in the design doc:

1. **The mode switch actually swaps the software keyboard.** Tap *Name or
   address* mid-number and confirm the QWERTY keyboard appears, the query is not
   silently kept in the wrong mode, and the sheet's scroll position does not
   jump.
2. **`SheetFocusScroll` lifts the field above the phone pad** on the smallest
   supported device, with the list still showing at least three rows.

---

## Self-review against the design doc

| Design doc section | Task |
|---|---|
| Substring monotonicity, one round trip | 3, 6 |
| Hold below seven digits | 1, 6 |
| Canonical digits / leading `1` | 1 |
| Fallback rungs on a miss | 1, 6 — **changed**: first-7/last-7, not last-7/last-4 (F1) |
| Recents from memory | 4 |
| OS phone pad, `TextInputType.phone` | 9 |
| Mode switch, live before focus | 9, 12 |
| No autofocus | 9 (the picker never requests focus) |
| Tap to attach, never automatic | 9 (test: "nothing attaches on its own") |
| Fade rather than disappear | 9 |
| Digit tally | 9 |
| Confirmation card | 10 |
| Address switch on the card | 10, 12 |
| Address moves to WHO | 11, 12 |
| Previous job addresses before a Places call | 11 |
| Unit grouping | 11b — owner chose to build it (2026-09-05). Groups only when every entry shares one street AND names a unit; falls back to full rows otherwise. |
| Query survives losing focus | 6 (the window and the status persist on the controller, not the widget) |
| Collapsed match summary when unfocused | 9 |
| Clear stale rows | 6 |
| Failure ≠ empty | 6, 9 |
| Lift the number into the phone field | 7 |
| Split `phoneDigits` | 2 |
| Rank in production | 6b — owner chose to fix it now (2026-09-05). The returned 25 are re-ranked in the repository so both search paths agree. The server's 200-doc READ cap is still `orderBy("name")` and stays out of scope. |
