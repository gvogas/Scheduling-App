# Shared Dart/JS Fixtures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every hand-mirrored Dart/JS pair reads its worked examples from ONE JSON fixture under `test/fixtures/shared/`, so "keep the examples equal" is enforced by the file system instead of by discipline.

**Architecture:** One JSON file per mirrored pair. The Dart test loads it with `File(...)` + `jsonDecode` (cwd is the package root under both `flutter test` and `tool/test.dart`); the jest test `require`s it by relative path. The pattern already exists and works in CI: `test/fixtures/client_building_cases.json` is read by `test/features/clients/domain/client_building_test.dart` and `functions/__tests__/client_buildings.test.js`. A registry test fails if a shared fixture loses its reader on either side. No production code changes.

**Tech Stack:** Dart `flutter_test`, Jest 29, JSON.

---

## Decisions

- **Phase 1 only (this plan): one source of truth for the shared worked examples.** Fixtures live under `test/fixtures/shared/` at the repo root so both suites reach them — Dart via `File('test/fixtures/shared/x.json')`, Jest via `require("../../test/fixtures/shared/x.json")` from `functions/__tests__/`.
- **The fixture is the UNION of both suites' shared examples.** An example that existed on one side only is added to the fixture, so the other side now runs it too. Every one-sided example below was probed against BOTH implementations on 2026-10-06 before being written into a fixture, so all fixtures are expected to pass on first run. **If one fails, that is a real divergence: stop and report it; never edit the fixture value to make it pass.**
- **Side-specific tests stay where they are** — anything that needs a generated input (200 words, a 500-char path), a model type only one side has (`AppointmentImage`, `AppointmentRecord`), or a value only one language can express (`null`, `undefined`, a `Buffer`).
- **The accent fold table gets its own fixture**, compared entry-by-entry for all 64 Latin-1 code points U+00C0–U+00FF (not only via four examples).
- **Every fixture case must assert something.** Each loop checks the case carries at least one `expect*` key, so a typo'd key cannot turn a case into a vacuous pass.
- **Phase 2 (server-only token generation) is OUT OF SCOPE** — see the end of this file.

## Mirrored pairs covered

| Fixture | Dart side | JS side | Evidence |
|---|---|---|---|
| `constants.json` | `kSearchTokenQueryLimit`, `kSearchTokenFieldLimit`, `maxAppointmentSpanDays`, image-id cap 300 | `TOKEN_QUERY_LIMIT`, `TOKEN_FIELD_LIMIT`, `MAX_APPOINTMENT_SPAN_DAYS`, `MAX_ID_LENGTH` | `day_slice_utils.test.js` "the cap matches the Dart constant"; `appointment_image_ids.test.js` "the cap matches the Dart mirror's `maxLength`" |
| `accent_fold.json` | `ClientSearchPolicy._foldAccent` (via `normalize`) | `ACCENT_FOLD` in `functions/search_tokens.js` | `search_tokens.js:6` "Hand-mirror of `ClientSearchPolicy._foldAccent`" |
| `search_tokens.json` | `lib/core/search/search_tokens.dart`, `ClientSearchPolicy.normalize`, `historyEntryMatches` | `functions/search_tokens.js` | both test headers: "shared, value for value"; `history_search_policy_test.dart:21` |
| `day_slice.json` | `appointment_day_slice.dart` (`dailyWindowsOverlap`, `expandRunWindows`) | `functions/day_slice_utils.js` | `appointment_day_slice_test.dart:1` "Mirrored value-for-value" |
| `image_ids.json` | `appointment_image_doc_id.dart` | `functions/appointment_image_ids.js` | both test headers: "shared VERBATIM" |
| `image_magic.json` | `lib/core/images/image_magic.dart` | `functions/image_magic.js` | `maintenance.test.js:8` "HAND-MIRRORED … shared verbatim" |
| `client_name_lift.json` | `ClientNamePolicy.liftPhoneFromName` | `liftPhoneFromName` in `functions/client_name_utils.js` | `client_name_utils.test.js:339,366`; `client_name_policy_test.dart:7` |
| `address.json` | `AddressParser.streetOnly` / `composeFull` | `streetFromAddress` / `composeFullAddress` in `functions/client_address_utils.js` | `client_address_utils.js:5` "JS half of a hand-mirrored pair" |
| `feature_flags.json` | `lib/core/remote_config/feature_flags.dart` | `functions/feature_flags.js` | kill-switch design §1 "One owner per side … parity test" |

**Mirrors found but NOT in this plan** (no shared example set yet, or the twin is `firestore.rules` rather than Dart): `widget_payload_utils.js` ↔ the Flutter widget payload builder, `appointment_images.js` ↔ `_imagesSubcollection`, `employee_accounts.js` ↔ `JobTitle.raw` / `PasswordRequirement`, `self_service_fields.dart` ↔ `firestore.rules`, `live_map_aggregator.dart` staleness ↔ `PRESENCE_STALE_MINUTES`, `client_name_utils.js` `stripPhone`/`composeStored`/`bareNumber`/`looksLikeBusinessName` (the Dart suite covers them with different examples). Each is a candidate for a follow-up fixture once its examples are aligned.

## Findings recorded while writing this plan

- `test/core/images/image_magic_test.dart` names `functions/__tests__/image_magic.test.js` as its twin. That file does not exist — the JS cases live in `functions/__tests__/maintenance.test.js`. Task 7 replaces the stale header.
- `test/features/maps/address_parser_street_locality_test.dart` says `streetOnly` mirrors `functions/wave/mappers.js`. The JS twin is `functions/client_address_utils.js`. Task 9 replaces the stale header.
- One-sided examples (now run on both sides through the fixtures): image magic `[00 01 02 03]` (JS only) and the JPEG fourth byte (`E0` Dart vs `00` JS — both kept); image id exact outputs for the url fallback and `/_x_/` (JS asserted, Dart only asserted shape); history seam `555-4321` → true and blank query → false (Dart only); `liftPhoneFromName` phone value for the bracket cases (JS only); `composeFull` for `1234 Rue Principale` + full locality and for the no-locality apt case (one side each).
- **Out of scope, worth a ticket:** both sides format a lifted 7-digit number as `(562) 833-2` and an 11-digit one as `(514) 562-8332 2`. The suites only assert the digits, so this formatting is unpinned on both sides. It is consistent, so not a mirror bug.

## File structure

| Path | Responsibility |
|---|---|
| Create `test/fixtures/shared/README.md` | The rule for this directory (4 lines) |
| Create `test/fixtures/shared/shared_fixture.dart` | `loadSharedFixture(name)` — the only Dart loader |
| Create `test/fixtures/shared/*.json` | One fixture per pair (9 files) |
| Create `test/shared_fixtures_registry_test.dart` | Fails if a fixture has no Dart or no jest reader |
| Create `test/core/shared_constants_test.dart`, `functions/__tests__/shared_constants.test.js` | Constant parity |
| Create `test/core/search/accent_fold_test.dart`, `functions/__tests__/accent_fold.test.js` | Fold table parity |
| Modify the 7 Dart and 6 JS test files named per task | Replace inline shared examples with a fixture loop |
| Modify `CLAUDE.md`, `.claude/rules/testing.md`, `docs/ARCHITECTURE.md` | Point the rule at the fixtures |

**Before writing any JSON:** save every fixture as UTF-8 **without a BOM** (several hold `é`, `ñ`, `Å`). After each task, check with `head -c 3 <file> | od -An -tx1` — the output must not be ` ef bb bf`.

---

### Task 1: Loader, README and the constants fixture

**Files:**
- Create: `test/fixtures/shared/README.md`
- Create: `test/fixtures/shared/shared_fixture.dart`
- Create: `test/fixtures/shared/constants.json`
- Create: `test/core/shared_constants_test.dart`
- Create: `functions/__tests__/shared_constants.test.js`

- [ ] **Step 1: Write the README**

```markdown
# Shared Dart/JS fixtures

Worked examples for code that exists twice — once in `lib/`, once in `functions/`.
Both suites read these files; neither keeps its own copy. Add a new example HERE, never inline in one test.
Dart: `loadSharedFixture('x.json')` (`shared_fixture.dart`). Jest: `require("../../test/fixtures/shared/x.json")`.
`test/shared_fixtures_registry_test.dart` fails if a file here loses its reader on either side.
```

- [ ] **Step 2: Write the Dart loader**

```dart
import 'dart:convert';
import 'dart:io';

/// Reads a fixture shared with the jest suite (see README.md beside this file).
Map<String, dynamic> loadSharedFixture(String name) =>
    jsonDecode(File('test/fixtures/shared/$name').readAsStringSync())
        as Map<String, dynamic>;

/// The cases under [key], typed for iteration.
List<Map<String, dynamic>> sharedCases(Map<String, dynamic> fixture, String key) =>
    (fixture[key] as List).cast<Map<String, dynamic>>();

/// Fails a case that carries none of [keys], so a typo'd key can't pass vacuously.
void expectAsserts(Map<String, dynamic> c, List<String> keys) {
  if (!keys.any(c.containsKey)) {
    throw StateError('Shared fixture case asserts nothing: $c');
  }
}
```

- [ ] **Step 3: Write `constants.json`**

```json
{
  "searchTokenQueryLimit": 10,
  "searchTokenFieldLimit": 240,
  "maxAppointmentSpanDays": 14,
  "appointmentImageIdMaxLength": 300
}
```

- [ ] **Step 4: Write the Dart constants test**

`test/core/shared_constants_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';

import '../fixtures/shared/shared_fixture.dart';

void main() {
  final constants = loadSharedFixture('constants.json');

  test('search token limits match the shared fixture', () {
    expect(kSearchTokenQueryLimit, constants['searchTokenQueryLimit']);
    expect(kSearchTokenFieldLimit, constants['searchTokenFieldLimit']);
  });

  test('the multi-day span cap matches the shared fixture', () {
    expect(maxAppointmentSpanDays, constants['maxAppointmentSpanDays']);
  });
}
```

(The image-id cap is a function-local `const` on the Dart side; Task 6 pins it through the length test instead.)

- [ ] **Step 5: Write the jest constants test**

`functions/__tests__/shared_constants.test.js`:

```js
"use strict";

const constants = require("../../test/fixtures/shared/constants.json");
const {TOKEN_QUERY_LIMIT, TOKEN_FIELD_LIMIT} = require("../search_tokens");
const {MAX_APPOINTMENT_SPAN_DAYS} = require("../day_slice_utils");
const {MAX_ID_LENGTH} = require("../appointment_image_ids");

describe("constants shared with the Dart side", () => {
  test("search token limits", () => {
    expect(TOKEN_QUERY_LIMIT).toBe(constants.searchTokenQueryLimit);
    expect(TOKEN_FIELD_LIMIT).toBe(constants.searchTokenFieldLimit);
  });

  test("the multi-day span cap", () => {
    expect(MAX_APPOINTMENT_SPAN_DAYS).toBe(constants.maxAppointmentSpanDays);
  });

  test("the appointment image id cap", () => {
    expect(MAX_ID_LENGTH).toBe(constants.appointmentImageIdMaxLength);
  });
});
```

- [ ] **Step 6: Run both, expect PASS**

Run: `flutter test test/core/shared_constants_test.dart`
Expected: `All tests passed!`
Run: `cd functions && npx jest __tests__/shared_constants.test.js`
Expected: `Tests: 3 passed`

- [ ] **Step 7: Prove both sides read the file**

Change `"maxAppointmentSpanDays": 14` to `15` in `constants.json`, re-run both commands, and confirm BOTH fail on that assertion. Revert to `14`, re-run, and confirm both pass.

- [ ] **Step 8: Remove the two now-duplicated JS constant pins**

In `functions/__tests__/day_slice_utils.test.js`, delete the test `"the cap matches the Dart constant"` (inside `describe("day_slice_utils", ...)`). In `functions/__tests__/appointment_image_ids.test.js`, delete the test `"the cap matches the Dart mirror's \`maxLength\`"`. Run `cd functions && npx jest __tests__/day_slice_utils.test.js __tests__/appointment_image_ids.test.js`. Expected: PASS. If `MAX_APPOINTMENT_SPAN_DAYS` or `MAX_ID_LENGTH` is now unused in either file, remove it from that file's `require` destructuring so lint stays clean.

- [ ] **Step 9: Commit**

```bash
git add test/fixtures/shared test/core/shared_constants_test.dart functions/__tests__/shared_constants.test.js functions/__tests__/day_slice_utils.test.js functions/__tests__/appointment_image_ids.test.js
git commit -m "Share Dart/JS constants through one fixture"
```

---

### Task 2: The accent fold table, entry by entry

**Files:**
- Create: `test/fixtures/shared/accent_fold.json`
- Create: `test/core/search/accent_fold_test.dart`
- Create: `functions/__tests__/accent_fold.test.js`

- [ ] **Step 1: Write `accent_fold.json`**

Code points, not literal characters, so no editor can mangle them. `""` means "a separator": the character normalizes to nothing on both sides.

```json
{
  "folds": [
    [192, "a"], [193, "a"], [194, "a"], [195, "a"], [196, "a"], [197, "a"], [198, ""], [199, "c"],
    [200, "e"], [201, "e"], [202, "e"], [203, "e"], [204, "i"], [205, "i"], [206, "i"], [207, "i"],
    [208, ""], [209, "n"], [210, "o"], [211, "o"], [212, "o"], [213, "o"], [214, "o"], [215, ""],
    [216, ""], [217, "u"], [218, "u"], [219, "u"], [220, "u"], [221, "y"], [222, ""], [223, ""],
    [224, "a"], [225, "a"], [226, "a"], [227, "a"], [228, "a"], [229, "a"], [230, ""], [231, "c"],
    [232, "e"], [233, "e"], [234, "e"], [235, "e"], [236, "i"], [237, "i"], [238, "i"], [239, "i"],
    [240, ""], [241, "n"], [242, "o"], [243, "o"], [244, "o"], [245, "o"], [246, "o"], [247, ""],
    [248, ""], [249, "u"], [250, "u"], [251, "u"], [252, "u"], [253, "y"], [254, ""], [255, "y"]
  ]
}
```

- [ ] **Step 2: Write the Dart test**

`test/core/search/accent_fold_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  final folds = (loadSharedFixture('accent_fold.json')['folds'] as List)
      .cast<List<dynamic>>();

  test('covers every Latin-1 letter from U+00C0 to U+00FF', () {
    expect(folds.map((f) => f[0]), [for (var c = 0xC0; c <= 0xFF; c++) c]);
  });

  for (final fold in folds) {
    final codePoint = fold[0] as int;
    test('U+${codePoint.toRadixString(16).toUpperCase()} folds to "${fold[1]}"', () {
      expect(
        ClientSearchPolicy.normalize(String.fromCharCode(codePoint)),
        fold[1],
      );
    });
  }
}
```

- [ ] **Step 3: Write the jest test**

`functions/__tests__/accent_fold.test.js`:

```js
"use strict";

const {folds} = require("../../test/fixtures/shared/accent_fold.json");
const {normalize} = require("../search_tokens");

describe("ACCENT_FOLD matches the Dart table entry by entry", () => {
  test("covers every Latin-1 letter from U+00C0 to U+00FF", () => {
    const expected = [];
    for (let c = 0xC0; c <= 0xFF; c++) expected.push(c);
    expect(folds.map((f) => f[0])).toEqual(expected);
  });

  test.each(folds)("U+%s folds to \"%s\"", (codePoint, fold) => {
    expect(normalize(String.fromCharCode(codePoint))).toBe(fold);
  });
});
```

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/core/search/accent_fold_test.dart` — Expected: `+65: All tests passed!`
Run: `cd functions && npx jest __tests__/accent_fold.test.js` — Expected: `Tests: 65 passed`

- [ ] **Step 5: Prove it bites**

Change `[241, "n"]` (ñ) to `[241, "x"]`, run both, and confirm both fail on U+F1. Revert, and confirm both pass.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/accent_fold.json test/core/search/accent_fold_test.dart functions/__tests__/accent_fold.test.js
git commit -m "Pin the accent fold table entry by entry on both sides"
```

---

### Task 3: Search token examples

**Files:**
- Create: `test/fixtures/shared/search_tokens.json`
- Modify (rewrite): `test/core/search/search_tokens_test.dart`
- Modify: `functions/__tests__/search_tokens.test.js` — the `searchQueryTokens`, `searchIndexTokens` and `normalize` describe blocks and the header comment

- [ ] **Step 1: Write `search_tokens.json`**

```json
{
  "queryTokens": [
    {"name": "emits one whole-word token per word plus the full digit run", "query": "Marc 514", "expect": ["t:marc", "t:514", "p:514"]},
    {"name": "is empty for a query with nothing searchable in it", "query": "  --  ", "expect": []},
    {"name": "never sends more than the query limit", "query": "a b c d e f g h i j k l m", "expectLength": 10}
  ],
  "indexTokens": [
    {"name": "emits each whole word before any of its prefixes", "texts": ["Marc"], "phones": [], "expect": ["t:marc", "t:m", "t:ma", "t:mar"]},
    {"name": "interleaves phones so a long name cannot starve them out", "texts": ["Marc Tremblay"], "phones": ["(514) 555-4321"], "limit": 10,
     "expect": ["t:marc", "p:5145554321", "t:m", "p:514", "t:ma", "p:5145", "t:mar", "p:51455", "t:tremblay", "p:514555"]},
    {"name": "a whole word and the whole number survive the tightest budget", "texts": ["Tremblay"], "phones": ["5145554321"], "limit": 2, "expect": ["t:tremblay", "p:5145554321"]},
    {"name": "accent folding makes an accented name reachable unaccented", "texts": ["Éric"], "phones": [], "expectContains": "t:eric"},
    {"name": "a run shorter than three digits is not indexed", "texts": [], "phones": ["12"], "expect": []}
  ],
  "normalize": [
    {"input": "Muñoz", "expect": "munoz"},
    {"input": "Éric Tremblay", "expect": "eric tremblay"},
    {"input": "Ångström", "expect": "angstrom"},
    {"input": "Šarko", "expect": "arko"}
  ]
}
```

- [ ] **Step 2: Rewrite the Dart test**

`test/core/search/search_tokens_test.dart`, full contents:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

import '../../fixtures/shared/shared_fixture.dart';

// Shared examples live in test/fixtures/shared/search_tokens.json.
void main() {
  final fixture = loadSharedFixture('search_tokens.json');

  group('searchQueryTokens', () {
    for (final c in sharedCases(fixture, 'queryTokens')) {
      test(c['name'] as String, () {
        _expectTokens(searchQueryTokens(c['query'] as String), c);
      });
    }
  });

  group('searchIndexTokens', () {
    for (final c in sharedCases(fixture, 'indexTokens')) {
      test(c['name'] as String, () {
        final texts = (c['texts'] as List).cast<String>();
        final phones = (c['phones'] as List).cast<String>();
        final limit = c['limit'] as int?;
        final tokens = limit == null
            ? searchIndexTokens(texts: texts, phones: phones)
            : searchIndexTokens(texts: texts, phones: phones, limit: limit);
        _expectTokens(tokens, c);
      });
    }

    test('honours the field cap', () {
      final tokens = searchIndexTokens(
        texts: [for (var i = 0; i < 200; i++) 'word$i'],
        phones: ['5145554321'],
      );
      expect(tokens.length, kSearchTokenFieldLimit);
    });
  });

  group('normalize', () {
    for (final c in sharedCases(fixture, 'normalize')) {
      test(c['input'] as String, () {
        expect(ClientSearchPolicy.normalize(c['input'] as String), c['expect']);
      });
    }
  });
}

void _expectTokens(List<String> tokens, Map<String, dynamic> c) {
  expectAsserts(c, const ['expect', 'expectContains', 'expectLength']);
  if (c.containsKey('expect')) expect(tokens, c['expect']);
  if (c.containsKey('expectContains')) {
    expect(tokens, contains(c['expectContains']));
  }
  if (c.containsKey('expectLength')) {
    expect(tokens, hasLength(c['expectLength']));
  }
}
```

- [ ] **Step 3: Edit the jest test**

In `functions/__tests__/search_tokens.test.js`:

(a) Replace the header comment (the four lines starting `// The worked examples here are shared`) with:

```js
// Examples shared with the Dart suite live in
// test/fixtures/shared/search_tokens.json.
```

(b) Below the `require("../search_tokens")` block, add:

```js
const fixture = require("../../test/fixtures/shared/search_tokens.json");

const expectTokens = (tokens, c) => {
  expect(["expect", "expectContains", "expectLength"].some((k) => k in c))
      .toBe(true);
  if ("expect" in c) expect(tokens).toEqual(c.expect);
  if ("expectContains" in c) expect(tokens).toContain(c.expectContains);
  if ("expectLength" in c) expect(tokens).toHaveLength(c.expectLength);
};
```

(c) Replace the whole `describe("searchQueryTokens", ...)` block with:

```js
describe("searchQueryTokens", () => {
  test.each(fixture.queryTokens)("$name", (c) => {
    expectTokens(searchQueryTokens(c.query), c);
  });
});
```

(d) Replace the whole `describe("searchIndexTokens", ...)` block with:

```js
describe("searchIndexTokens", () => {
  test.each(fixture.indexTokens)("$name", (c) => {
    const args = {texts: c.texts, phones: c.phones};
    if (c.limit != null) args.limit = c.limit;
    expectTokens(searchIndexTokens(args), c);
  });

  test("honours the field cap", () => {
    const texts = [];
    for (let i = 0; i < 200; i++) texts.push(`word${i}`);
    expect(searchIndexTokens({texts, phones: ["5145554321"]}))
        .toHaveLength(TOKEN_FIELD_LIMIT);
  });
});
```

(e) Replace the whole `describe("normalize", ...)` block with:

```js
describe("normalize", () => {
  test.each(fixture.normalize)("$input", (c) => {
    expect(normalize(c.input)).toBe(c.expect);
  });
});
```

(f) If `TOKEN_QUERY_LIMIT` is no longer referenced in the file, remove it from the `require` destructuring.

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/core/search/search_tokens_test.dart` — Expected: `+13: All tests passed!`
Run: `cd functions && npx jest __tests__/search_tokens.test.js` — Expected: PASS, 0 failed.

- [ ] **Step 5: Prove it bites**

In the fixture, change `"t:mar"` in the first `indexTokens` case to `"t:maX"`, and confirm both sides fail on that case. Revert, and confirm both pass.

- [ ] **Step 6: Lint and commit**

Run: `cd functions && npx eslint __tests__/search_tokens.test.js` — Expected: no output.

```bash
git add test/fixtures/shared/search_tokens.json test/core/search/search_tokens_test.dart functions/__tests__/search_tokens.test.js
git commit -m "Read search token examples from one shared fixture"
```

---

### Task 4: The history client/employee seam

**Files:**
- Modify: `test/fixtures/shared/search_tokens.json` (add `historySeam`)
- Modify: `test/features/calendar/domain/policies/history_search_policy_test.dart` — the `historyEntryMatches client/employee seam` group
- Modify: `functions/__tests__/search_tokens.test.js` — the `recordMatchesQuery client/employee seam` describe

- [ ] **Step 1: Add `historySeam` to `search_tokens.json`**

Add this key beside `normalize` (mind the comma after the `normalize` array):

```json
  "historySeam": {
    "record": {"clientName": "Marie Tremblay", "clientPhone": "5145554321", "employeeNames": ["Marc Dubois"]},
    "cases": [
      {"name": "does not match across the client/employee seam", "query": "tremblay marc", "expect": false},
      {"name": "matches within the client field", "query": "marie tremblay", "expect": true},
      {"name": "matches within the crew field", "query": "marc dubois", "expect": true},
      {"name": "matches the client phone by digits", "query": "555-4321", "expect": true},
      {"name": "a blank query matches nothing", "query": "  ", "expect": false}
    ]
  }
```

- [ ] **Step 2: Edit the Dart test**

In `history_search_policy_test.dart`, add `import '../../../../fixtures/shared/shared_fixture.dart';` as the last import (its own group after a blank line), and replace the whole `group('historyEntryMatches client/employee seam', ...)` block (with its two comment lines above it) with:

```dart
  // Shared with the jest suite: test/fixtures/shared/search_tokens.json.
  group('historyEntryMatches client/employee seam', () {
    final seam =
        loadSharedFixture('search_tokens.json')['historySeam']
            as Map<String, dynamic>;
    final record = seam['record'] as Map<String, dynamic>;
    final appointment = AppointmentRecord(
      id: 'a1',
      startTime: DateTime(2026, 9, 5, 9),
      endTime: DateTime(2026, 9, 5, 11),
      clientName: record['clientName'] as String,
      clientPhone: record['clientPhone'] as String,
      employeeNames: (record['employeeNames'] as List).cast<String>(),
    );

    for (final c in sharedCases(seam, 'cases')) {
      test(c['name'] as String, () {
        expect(_matches(appointment, c['query'] as String), c['expect']);
      });
    }
  });
```

Leave `_rawDoc()` and the `matchHistoryDocs` group unchanged.

- [ ] **Step 3: Edit the jest test**

Replace the whole `describe("recordMatchesQuery client/employee seam", ...)` block in `search_tokens.test.js` with:

```js
describe("recordMatchesQuery client/employee seam", () => {
  const {record, cases} = fixture.historySeam;
  test.each(cases)("$name", (c) => {
    expect(recordMatchesQuery(record, c.query)).toBe(c.expect);
  });
});
```

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/features/calendar/domain/policies/history_search_policy_test.dart` — Expected: PASS.
Run: `cd functions && npx jest __tests__/search_tokens.test.js` — Expected: PASS.

- [ ] **Step 5: Prove it bites**

Flip `"tremblay marc"`'s `"expect"` to `true`, and confirm both fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/search_tokens.json test/features/calendar/domain/policies/history_search_policy_test.dart functions/__tests__/search_tokens.test.js
git commit -m "Share the history search seam cases with the jest suite"
```

---

### Task 5: Day-slice windows

**Files:**
- Create: `test/fixtures/shared/day_slice.json`
- Modify: `test/features/calendar/domain/appointment_day_slice_test.dart` — header line, `dailyWindowsOverlap` group, `expandRunWindows` group
- Modify: `functions/__tests__/day_slice_utils.test.js` — header comment, `dailyWindowsOverlap` and `expandRunWindows` describes

Instants are Toronto wall-clock with their explicit UTC offset (`-04:00` in August, `-05:00` on 2027-03-12, before DST). JS parses the whole string. Dart takes the first 19 characters and parses them as a LOCAL `DateTime`, which is what the existing Dart cases already do.

- [ ] **Step 1: Write `day_slice.json`**

```json
{
  "dailyWindowsOverlap": [
    {"name": "a 9-5 week does not clash with a 7pm job inside it",
     "a": ["2026-08-01T09:00:00-04:00", "2026-08-05T17:00:00-04:00"], "b": ["2026-08-03T19:00:00-04:00", "2026-08-03T20:00:00-04:00"], "expect": false},
    {"name": "the same week DOES clash with a midday job inside it",
     "a": ["2026-08-01T09:00:00-04:00", "2026-08-05T17:00:00-04:00"], "b": ["2026-08-03T12:00:00-04:00", "2026-08-03T13:00:00-04:00"], "expect": true},
    {"name": "runs that share no day never clash",
     "a": ["2026-08-01T09:00:00-04:00", "2026-08-02T17:00:00-04:00"], "b": ["2026-08-04T09:00:00-04:00", "2026-08-05T17:00:00-04:00"], "expect": false},
    {"name": "touching windows on a shared day do not clash",
     "a": ["2026-08-01T09:00:00-04:00", "2026-08-03T12:00:00-04:00"], "b": ["2026-08-02T12:00:00-04:00", "2026-08-02T14:00:00-04:00"], "expect": false},
    {"name": "an overnight shift clashes with a job in its small hours",
     "a": ["2026-08-01T22:00:00-04:00", "2026-08-03T06:00:00-04:00"], "b": ["2026-08-02T02:00:00-04:00", "2026-08-02T03:00:00-04:00"], "expect": true},
    {"name": "a corrupt window whose end precedes its start never clashes",
     "a": ["2026-08-10T09:00:00-04:00", "2026-08-01T17:00:00-04:00"], "b": ["2026-08-10T09:00:00-04:00", "2026-08-10T17:00:00-04:00"], "expect": false}
  ],
  "expandRunWindows": [
    {"name": "a one-day window yields one pair unchanged",
     "run": ["2026-08-03T09:00:00-04:00", "2026-08-03T17:00:00-04:00"],
     "expectWindows": [["2026-08-03T09:00:00-04:00", "2026-08-03T17:00:00-04:00"]]},
    {"name": "a 5-day 9-to-5 window yields five one-day windows",
     "run": ["2026-08-03T09:00:00-04:00", "2026-08-07T17:00:00-04:00"],
     "expectWindows": [
       ["2026-08-03T09:00:00-04:00", "2026-08-03T17:00:00-04:00"],
       ["2026-08-04T09:00:00-04:00", "2026-08-04T17:00:00-04:00"],
       ["2026-08-05T09:00:00-04:00", "2026-08-05T17:00:00-04:00"],
       ["2026-08-06T09:00:00-04:00", "2026-08-06T17:00:00-04:00"],
       ["2026-08-07T09:00:00-04:00", "2026-08-07T17:00:00-04:00"]]},
    {"name": "a night shift yields one window per NIGHT, ending the morning after",
     "run": ["2026-08-03T22:00:00-04:00", "2026-08-05T06:00:00-04:00"],
     "expectWindows": [
       ["2026-08-03T22:00:00-04:00", "2026-08-04T06:00:00-04:00"],
       ["2026-08-04T22:00:00-04:00", "2026-08-05T06:00:00-04:00"]]},
    {"name": "an all-day multi-day block yields a midnight-to-23:59 window a day",
     "run": ["2026-08-03T00:00:00-04:00", "2026-08-04T23:59:00-04:00"],
     "expectWindows": [
       ["2026-08-03T00:00:00-04:00", "2026-08-03T23:59:00-04:00"],
       ["2026-08-04T00:00:00-04:00", "2026-08-04T23:59:00-04:00"]]},
    {"name": "a span past the cap clamps to the max span",
     "run": ["2026-08-03T09:00:00-04:00", "2027-03-12T17:00:00-05:00"], "expectLength": 14},
    {"name": "a corrupt pair whose end precedes its start yields one window",
     "run": ["2026-08-07T09:00:00-04:00", "2026-08-03T17:00:00-04:00"], "expectLength": 1, "expectFirstStart": "2026-08-07T09:00:00-04:00"}
  ]
}
```

- [ ] **Step 2: Edit the Dart test**

In `appointment_day_slice_test.dart`:

(a) Replace line 1 (`// Mirrored value-for-value by …`) with:
`// dailyWindowsOverlap / expandRunWindows examples are shared with jest: test/fixtures/shared/day_slice.json.`

(b) Add `import '../../../fixtures/shared/shared_fixture.dart';` as the last import, after a blank line.

(c) Add this top-level helper below `_record`:

```dart
/// A fixture instant as the LOCAL wall-clock time it names (offset dropped).
DateTime _wall(Object? value) => DateTime.parse((value! as String).substring(0, 19));
```

(d) Add `final fixture = loadSharedFixture('day_slice.json');` as the first line of `main()`.

(e) Replace the whole `group('dailyWindowsOverlap', ...)` block with:

```dart
  group('dailyWindowsOverlap', () {
    for (final c in sharedCases(fixture, 'dailyWindowsOverlap')) {
      test(c['name'] as String, () {
        final a = c['a'] as List;
        final b = c['b'] as List;
        expect(
          dailyWindowsOverlap(
            aStart: _wall(a[0]),
            aEnd: _wall(a[1]),
            bStart: _wall(b[0]),
            bEnd: _wall(b[1]),
          ),
          c['expect'],
        );
      });
    }
  });
```

(f) Replace the whole `group('expandRunWindows', ...)` block with:

```dart
  group('expandRunWindows', () {
    for (final c in sharedCases(fixture, 'expandRunWindows')) {
      test(c['name'] as String, () {
        expectAsserts(c, const ['expectWindows', 'expectLength']);
        final run = c['run'] as List;
        final windows = expandRunWindows(_wall(run[0]), _wall(run[1]));
        if (c.containsKey('expectWindows')) {
          expect(
            [for (final w in windows) [w.start, w.end]],
            [
              for (final pair in (c['expectWindows'] as List).cast<List>())
                [_wall(pair[0]), _wall(pair[1])],
            ],
          );
        }
        if (c.containsKey('expectLength')) {
          expect(windows, hasLength(c['expectLength']));
        }
        if (c.containsKey('expectFirstStart')) {
          expect(windows.first.start, _wall(c['expectFirstStart']));
        }
      });
    }
  });
```

- [ ] **Step 3: Edit the jest test**

In `day_slice_utils.test.js`:

(a) In the header JSDoc, replace the sentence `These are deliberately the SAME worked examples as … instead of shipping.` with:
` * The dailyWindowsOverlap / expandRunWindows examples are read from test/fixtures/shared/day_slice.json, which the Dart suite reads too.`

(b) Below the `require("../day_slice_utils")` block, add:

```js
const fixture = require("../../test/fixtures/shared/day_slice.json");
```

(c) Replace the whole `describe("dailyWindowsOverlap", ...)` block with:

```js
describe("dailyWindowsOverlap", () => {
  test.each(fixture.dailyWindowsOverlap)("$name", (c) => {
    expect(dailyWindowsOverlap(win(...c.a), win(...c.b))).toBe(c.expect);
  });
});
```

(d) Replace the whole `describe("expandRunWindows", ...)` block with:

```js
describe("expandRunWindows", () => {
  test.each(fixture.expandRunWindows)("$name", (c) => {
    expect(["expectWindows", "expectLength"].some((k) => k in c)).toBe(true);
    const windows = expandRunWindows(win(...c.run));
    if (c.expectWindows) {
      expect(windows).toEqual(c.expectWindows.map(([s, e]) => ({
        startMs: at(s), endMs: at(e),
      })));
    }
    if (c.expectLength != null) expect(windows).toHaveLength(c.expectLength);
    if (c.expectFirstStart) {
      expect(windows[0].startMs).toBe(at(c.expectFirstStart));
    }
  });
});
```

`at` and `win` are the existing helpers in this file. `at` already accepts an offset ISO string (it is `new Date(iso).getTime()`).

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/features/calendar/domain/appointment_day_slice_test.dart` — Expected: PASS.
Run: `cd functions && npx jest __tests__/day_slice_utils.test.js` — Expected: PASS.

- [ ] **Step 5: Prove it bites**

Change the third window of the 5-day case to end at `17:30`, and confirm both fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/day_slice.json test/features/calendar/domain/appointment_day_slice_test.dart functions/__tests__/day_slice_utils.test.js
git commit -m "Read day-slice window examples from one shared fixture"
```

---

### Task 6: Appointment image ids

**Files:**
- Create: `test/fixtures/shared/image_ids.json`
- Modify (rewrite): `test/features/calendar/domain/appointment_image_doc_id_test.dart`
- Modify (rewrite): `functions/__tests__/appointment_image_ids.test.js`

- [ ] **Step 1: Write `image_ids.json`**

```json
{
  "cases": [
    {"name": "keys on storagePath, which renders and deletes the photo",
     "storagePath": "appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg",
     "url": "https://firebasestorage.googleapis.com/v0/b/schedulingapp-88727.firebasestorage.app/o/appointments%2FaBc123XyZ%2Fimages%2F1754835600000_image_picker_A1.jpg?alt=media&token=8f3e1c2a-4b5d-6e7f-8a9b-0c1d2e3f4a5b",
     "expect": "img_appointments_aBc123XyZ_images_1754835600000_image_picker_A1.jpg"},
    {"name": "storagePath alone gives the same id",
     "storagePath": "appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg", "url": "",
     "expect": "img_appointments_aBc123XyZ_images_1754835600000_image_picker_A1.jpg"},
    {"name": "a second photo on the same appointment gets its own id",
     "storagePath": "appointments/aBc123XyZ/images/1754835600001_image_picker_A2.jpg", "url": "",
     "expect": "img_appointments_aBc123XyZ_images_1754835600001_image_picker_A2.jpg"},
    {"name": "falls back to url when storagePath is empty",
     "storagePath": "",
     "url": "https://firebasestorage.googleapis.com/v0/b/schedulingapp-88727.firebasestorage.app/o/appointments%2FaBc123XyZ%2Fimages%2F1754835600000_image_picker_A1.jpg?alt=media&token=8f3e1c2a-4b5d-6e7f-8a9b-0c1d2e3f4a5b",
     "expect": "img_https___firebasestorage.googleapis.com_v0_b_schedulingapp-88727.firebasestorage.app_o_appointments_2FaBc123XyZ_2Fimages_2F1754835600000_image_picker_A1.jpg_alt_media_token_8f3e1c2a-4b5d-6e7f-8a9b-0c1d2e3f4a5b"},
    {"name": "a second legacy photo with a different url gets its own id",
     "storagePath": "",
     "url": "https://firebasestorage.googleapis.com/v0/b/schedulingapp-88727.firebasestorage.app/o/appointments%2FaBc123XyZ%2Fimages%2F1754835600000_image_picker_A1.jpg?alt=media&token=9a4f2d3b-4b5d-6e7f-8a9b-0c1d2e3f4a5b",
     "expect": "img_https___firebasestorage.googleapis.com_v0_b_schedulingapp-88727.firebasestorage.app_o_appointments_2FaBc123XyZ_2Fimages_2F1754835600000_image_picker_A1.jpg_alt_media_token_9a4f2d3b-4b5d-6e7f-8a9b-0c1d2e3f4a5b"},
    {"name": "a whitespace-only storagePath still falls back",
     "storagePath": "   ",
     "url": "https://firebasestorage.googleapis.com/v0/b/schedulingapp-88727.firebasestorage.app/o/appointments%2FaBc123XyZ%2Fimages%2F1754835600000_image_picker_A1.jpg?alt=media&token=8f3e1c2a-4b5d-6e7f-8a9b-0c1d2e3f4a5b",
     "expect": "img_https___firebasestorage.googleapis.com_v0_b_schedulingapp-88727.firebasestorage.app_o_appointments_2FaBc123XyZ_2Fimages_2F1754835600000_image_picker_A1.jpg_alt_media_token_8f3e1c2a-4b5d-6e7f-8a9b-0c1d2e3f4a5b"},
    {"name": "the img_ prefix keeps the reserved __.*__ shape unreachable", "storagePath": "/_x_/", "url": "", "expect": "img___x__"},
    {"name": "is never '.'", "storagePath": ".", "url": "", "expect": "img_."},
    {"name": "is never '..'", "storagePath": "..", "url": "", "expect": "img_.."},
    {"name": "an image with no identity at all yields an empty id", "storagePath": "", "url": "", "expect": ""}
  ]
}
```

- [ ] **Step 2: Rewrite the Dart test**

`test/features/calendar/domain/appointment_image_doc_id_test.dart`, full contents:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_image_doc_id.dart';

import '../../../fixtures/shared/shared_fixture.dart';

// Exact-id examples are shared with jest: test/fixtures/shared/image_ids.json.
void main() {
  final cap =
      loadSharedFixture('constants.json')['appointmentImageIdMaxLength'] as int;

  group('shared examples', () {
    for (final c in sharedCases(loadSharedFixture('image_ids.json'), 'cases')) {
      test(c['name'] as String, () {
        expect(
          appointmentImageDocIdFor(
            storagePath: c['storagePath'] as String,
            url: c['url'] as String,
          ),
          c['expect'],
        );
      });
    }
  });

  test('fields other than storagePath and url do not change the id', () {
    const path = 'appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg';
    expect(
      appointmentImageDocId(const AppointmentImage(storagePath: path)),
      appointmentImageDocId(
        const AppointmentImage(storagePath: path, fileName: 'something_else.jpg'),
      ),
    );
    expect(appointmentImageDocId(const AppointmentImage()), '');
  });

  test('caps length while keeping the unique tail', () {
    final long = 'appointments/${'x' * 500}/images/UNIQUE_TAIL.jpg';
    final id = appointmentImageDocIdFor(storagePath: long, url: '');
    expect(id.length, 'img_'.length + cap);
    expect(id, endsWith('UNIQUE_TAIL.jpg'));
  });

  test('two long paths differing only in their tail do not collide', () {
    final a = 'appointments/${'x' * 500}/images/TAIL_A.jpg';
    final b = 'appointments/${'x' * 500}/images/TAIL_B.jpg';
    expect(
      appointmentImageDocIdFor(storagePath: a, url: ''),
      isNot(appointmentImageDocIdFor(storagePath: b, url: '')),
    );
  });
}
```

(The length assertion is now exact — `4 + 300` — where it was `<= 304`. The probe returned 304, so it holds, and it pins the Dart-local cap against the shared constant.)

- [ ] **Step 3: Rewrite the jest test**

`functions/__tests__/appointment_image_ids.test.js`, full contents:

```js
/**
 * @fileoverview Exact-id examples are shared with the Dart suite through
 * test/fixtures/shared/image_ids.json; only JS-specific shapes live here.
 */
const {appointmentImageDocId, MAX_ID_LENGTH} =
  require("../appointment_image_ids");
const {cases} = require("../../test/fixtures/shared/image_ids.json");

describe("shared examples", () => {
  test.each(cases)("$name", (c) => {
    expect(appointmentImageDocId({storagePath: c.storagePath, url: c.url}))
        .toBe(c.expect);
  });
});

test("fields other than storagePath and url do not change the id", () => {
  const storagePath =
    "appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg";
  expect(appointmentImageDocId({storagePath})).toBe(appointmentImageDocId({
    storagePath,
    fileName: "something_else.jpg",
    uploadedAt: new Date("2020-01-01T00:00:00.000Z"),
  }));
});

test("a missing or null image yields an empty id", () => {
  expect(appointmentImageDocId({})).toBe("");
  expect(appointmentImageDocId(null)).toBe("");
});

test("caps length while keeping the unique tail", () => {
  const long = `appointments/${"x".repeat(500)}/images/UNIQUE_TAIL.jpg`;
  const id = appointmentImageDocId({storagePath: long});
  expect(id.length).toBe("img_".length + MAX_ID_LENGTH);
  expect(id.endsWith("UNIQUE_TAIL.jpg")).toBe(true);
});

test("two long paths differing only in their tail do not collide", () => {
  const a = `appointments/${"x".repeat(500)}/images/TAIL_A.jpg`;
  const b = `appointments/${"x".repeat(500)}/images/TAIL_B.jpg`;
  expect(appointmentImageDocId({storagePath: a}))
      .not.toBe(appointmentImageDocId({storagePath: b}));
});
```

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/features/calendar/domain/appointment_image_doc_id_test.dart` — Expected: PASS.
Run: `cd functions && npx jest __tests__/appointment_image_ids.test.js __tests__/shared_constants.test.js` — Expected: PASS.

- [ ] **Step 5: Prove it bites**

Change `"img___x__"` to `"img__x_"`, and confirm both fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/image_ids.json test/features/calendar/domain/appointment_image_doc_id_test.dart functions/__tests__/appointment_image_ids.test.js
git commit -m "Read appointment image id examples from one shared fixture"
```

---

### Task 7: Image magic bytes

**Files:**
- Create: `test/fixtures/shared/image_magic.json`
- Modify (rewrite): `test/core/images/image_magic_test.dart`
- Modify: `functions/__tests__/maintenance.test.js` — header JSDoc and the `describe("hasValidImageMagic", ...)` block

- [ ] **Step 1: Write `image_magic.json`**

Bytes are decimal (`255` = `0xFF`).

```json
{
  "cases": [
    {"name": "accepts a JPEG signature (FF D8 FF E0)", "bytes": [255, 216, 255, 224], "expect": true},
    {"name": "accepts a JPEG signature with any fourth byte (FF D8 FF 00)", "bytes": [255, 216, 255, 0], "expect": true},
    {"name": "accepts a PNG signature (89 50 4E 47)", "bytes": [137, 80, 78, 71], "expect": true},
    {"name": "rejects the three PNG bytes with the wrong fourth", "bytes": [137, 80, 78, 0], "expect": false},
    {"name": "rejects a three-byte PNG prefix", "bytes": [137, 80, 78], "expect": false},
    {"name": "accepts a three-byte JPEG prefix", "bytes": [255, 216, 255], "expect": true},
    {"name": "rejects a PDF signature", "bytes": [37, 80, 68, 70], "expect": false},
    {"name": "rejects a GIF signature", "bytes": [71, 73, 70, 56], "expect": false},
    {"name": "rejects arbitrary non-image bytes", "bytes": [0, 1, 2, 3], "expect": false},
    {"name": "rejects a truncated JPEG prefix", "bytes": [255, 216], "expect": false},
    {"name": "rejects an empty file", "bytes": [], "expect": false}
  ]
}
```

- [ ] **Step 2: Rewrite the Dart test**

`test/core/images/image_magic_test.dart`, full contents. This replaces the stale header that named a nonexistent `image_magic.test.js`.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/images/image_magic.dart';

import '../../fixtures/shared/shared_fixture.dart';

// Shared with functions/__tests__/maintenance.test.js through
// test/fixtures/shared/image_magic.json — the server half DELETES a failing upload.
void main() {
  group('hasValidImageMagic', () {
    for (final c in sharedCases(loadSharedFixture('image_magic.json'), 'cases')) {
      test(c['name'] as String, () {
        expect(
          hasValidImageMagic((c['bytes'] as List).cast<int>()),
          c['expect'],
        );
      });
    }
  });
}
```

- [ ] **Step 3: Edit the jest test**

In `functions/__tests__/maintenance.test.js`, replace the sentence in the header JSDoc that begins `HAND-MIRRORED by` and runs to `Change both together.` with:

```
 * HAND-MIRRORED by `hasValidImageMagic` in `lib/core/images/image_magic.dart`;
 * both suites read test/fixtures/shared/image_magic.json, because THIS side
 * deletes the object and a divergence is a photo that uploads and then vanishes.
```

Then replace the whole `describe("hasValidImageMagic", ...)` block with:

```js
describe("hasValidImageMagic", () => {
  const {cases} = require("../../test/fixtures/shared/image_magic.json");

  test.each(cases)("$name", (c) => {
    expect(hasValidImageMagic(Buffer.from(c.bytes))).toBe(c.expect);
  });

  test("rejects a missing buffer", () => {
    expect(hasValidImageMagic(null)).toBe(false);
  });
});
```

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/core/images/image_magic_test.dart` — Expected: `+11: All tests passed!`
Run: `cd functions && npx jest __tests__/maintenance.test.js` — Expected: PASS.

- [ ] **Step 5: Prove it bites**

Flip "rejects the three PNG bytes with the wrong fourth" to `"expect": true`, and confirm both fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/image_magic.json test/core/images/image_magic_test.dart functions/__tests__/maintenance.test.js
git commit -m "Read image magic examples from one shared fixture"
```

---

### Task 8: `liftPhoneFromName`

**Files:**
- Create: `test/fixtures/shared/client_name_lift.json`
- Modify: `test/features/clients/domain/client_name_policy_test.dart` — the `liftPhoneFromName` and `liftPhoneFromName at other digit counts` groups
- Modify: `functions/__tests__/client_name_utils.test.js` — the matching two describes and their comments

- [ ] **Step 1: Write `client_name_lift.json`**

A case asserts `expectNull`, or any of `expectName` / `expectPhone` / `expectPhoneDigits`.

```json
{
  "cases": [
    {"name": "moves a pasted number into the phone field", "input": "Marc Tremblay 514-555-1234", "phone": "", "expectName": "Marc Tremblay", "expectPhone": "(514) 555-1234"},
    {"name": "takes the number off the front of the name too", "input": "514-555-1234 - Marc Tremblay", "phone": "", "expectName": "Marc Tremblay", "expectPhone": "(514) 555-1234"},
    {"name": "a typed phone always wins", "input": "Marc Tremblay 514-555-1234", "phone": "(438) 222-3333", "expectNull": true},
    {"name": "keeps the name when it is nothing but the number", "input": "5145551234", "phone": "", "expectName": "5145551234", "expectPhone": "(514) 555-1234"},
    {"name": "leaves an ambiguous digit run for a human", "input": "Suite 12345", "phone": "", "expectNull": true},
    {"name": "leaves an international number in a name", "input": "Marc +33 6 12 34 56 78", "phone": "", "expectNull": true},
    {"name": "takes the number's own brackets with it (trailing)", "input": "Marc Tremblay (514) 555-1234", "phone": "", "expectName": "Marc Tremblay", "expectPhone": "(514) 555-1234"},
    {"name": "takes the number's own brackets with it (leading)", "input": "(514) 555-1234 Marc Tremblay", "phone": "", "expectName": "Marc Tremblay", "expectPhone": "(514) 555-1234"},
    {"name": "takes the number's own brackets with it (bare digits)", "input": "Marc Tremblay (5145551234)", "phone": "", "expectName": "Marc Tremblay", "expectPhone": "(514) 555-1234"},
    {"name": "a bracketed number alone is still nothing but the number", "input": "(514) 555-1234", "phone": "", "expectName": "(514) 555-1234", "expectPhone": "(514) 555-1234"},
    {"name": "a bracket that belongs to the NAME survives", "input": "Depanneur (Nord) 5145551234", "phone": "", "expectName": "Depanneur (Nord)", "expectPhone": "(514) 555-1234"},
    {"name": "does nothing to an ordinary name", "input": "Marc Tremblay", "phone": "", "expectNull": true},
    {"name": "a ten-digit number still lifts and formats", "input": "5145628332", "phone": "", "expectPhone": "(514) 562-8332"},
    {"name": "a seven-digit number lifts rather than being left in the name", "input": "5628332", "phone": "", "expectPhoneDigits": "5628332"},
    {"name": "an eleven-digit typo still lifts", "input": "51456283322", "phone": "", "expectPhoneDigits": "51456283322"},
    {"name": "an international number alone stays in the name", "input": "+33 6 12 34 56 78", "phone": "", "expectNull": true},
    {"name": "too few digits to dial is not a phone", "input": "4820", "phone": "", "expectNull": true},
    {"name": "a name with a number in it keeps the name", "input": "Marie Tremblay 5145628332", "phone": "", "expectName": "Marie Tremblay", "expectPhone": "(514) 562-8332"},
    {"name": "eight digits are no NANP shape, so nothing lifts", "input": "3101-5696", "phone": "", "expectNull": true},
    {"name": "nine digits are no NANP shape, so nothing lifts", "input": "310 156 969", "phone": "", "expectNull": true}
  ]
}
```

- [ ] **Step 2: Edit the Dart test**

In `client_name_policy_test.dart`:

(a) Replace the doc comment above `void main()` (the five `///` lines) with:
`/// liftPhoneFromName examples are shared with jest: test/fixtures/shared/client_name_lift.json.`

(b) Add `import '../../../fixtures/shared/shared_fixture.dart';` as the last import, after a blank line.

(c) Delete the whole `group('liftPhoneFromName at other digit counts', ...)` block.

(d) Replace the whole `group('liftPhoneFromName', ...)` block with:

```dart
  group('liftPhoneFromName', () {
    final cases = sharedCases(
      loadSharedFixture('client_name_lift.json'),
      'cases',
    );
    for (final c in cases) {
      test(c['name'] as String, () {
        expectAsserts(c, const [
          'expectNull',
          'expectName',
          'expectPhone',
          'expectPhoneDigits',
        ]);
        final lifted = ClientNamePolicy.liftPhoneFromName(
          name: c['input'] as String,
          phone: c['phone'] as String,
        );
        if (c['expectNull'] == true) {
          expect(lifted, isNull);
          return;
        }
        expect(lifted, isNotNull);
        if (c.containsKey('expectName')) expect(lifted!.name, c['expectName']);
        if (c.containsKey('expectPhone')) {
          expect(lifted!.phone, c['expectPhone']);
        }
        if (c.containsKey('expectPhoneDigits')) {
          expect(
            ClientSearchPolicy.digitsOnly(lifted!.phone),
            c['expectPhoneDigits'],
          );
        }
      });
    }
  });
```

- [ ] **Step 3: Edit the jest test**

In `client_name_utils.test.js`:

(a) Delete the whole `describe("liftPhoneFromName at other digit counts", ...)` block and the two comment lines above it.

(b) Replace the whole `describe("liftPhoneFromName", ...)` block with:

```js
describe("liftPhoneFromName", () => {
  const {cases} = require("../../test/fixtures/shared/client_name_lift.json");

  test.each(cases)("$name", (c) => {
    expect(["expectNull", "expectName", "expectPhone", "expectPhoneDigits"]
        .some((k) => k in c)).toBe(true);
    const lifted = liftPhoneFromName({name: c.input, phone: c.phone});
    if (c.expectNull) {
      expect(lifted).toBeNull();
      return;
    }
    expect(lifted).not.toBeNull();
    if ("expectName" in c) expect(lifted.name).toBe(c.expectName);
    if ("expectPhone" in c) expect(lifted.phone).toBe(c.expectPhone);
    if ("expectPhoneDigits" in c) {
      expect(lifted.phone.replace(/\D/g, "")).toBe(c.expectPhoneDigits);
    }
  });
});
```

(c) In the file's header JSDoc (lines 15–20), add one line at the end: ` * liftPhoneFromName reads test/fixtures/shared/client_name_lift.json.`

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/features/clients/domain/client_name_policy_test.dart` — Expected: PASS.
Run: `cd functions && npx jest __tests__/client_name_utils.test.js` — Expected: PASS.

- [ ] **Step 5: Prove it bites**

Change "a bracket that belongs to the NAME survives" to `"expectName": "Depanneur Nord"`, and confirm both fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/client_name_lift.json test/features/clients/domain/client_name_policy_test.dart functions/__tests__/client_name_utils.test.js
git commit -m "Read liftPhoneFromName examples from one shared fixture"
```

---

### Task 9: Street / composed address

**Files:**
- Create: `test/fixtures/shared/address.json`
- Modify (rewrite): `test/features/maps/address_parser_street_locality_test.dart`
- Modify (rewrite): `functions/__tests__/client_address_utils.test.js`

- [ ] **Step 1: Write `address.json`**

```json
{
  "streetOnly": [
    {"name": "strips the locality tail the structured fields already carry", "stored": "1234 Rue Principale, Montréal, QC H2X 1Y4, Canada",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "1234 Rue Principale"},
    {"name": "keeps a street whose own second segment is not a locality", "stored": "100 Main St, Building A, Montréal, QC H2X 1Y4, Canada",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "100 Main St, Building A"},
    {"name": "is idempotent: an already-reduced street passes through", "stored": "1234 Rue Principale",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "1234 Rue Principale"},
    {"name": "keeps the apt prefix on the canonical stored form", "stored": "4-1234 Rue Principale, Montréal, QC H2X 1Y4, Canada",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "4-1234 Rue Principale"},
    {"name": "matches a province and postal code joined in one segment", "stored": "55 Boulevard Saint-Laurent, Laval, QC H7N 1A1",
     "locality": {"city": "Laval", "province": "QC", "postalCode": "H7N 1A1"}, "expect": "55 Boulevard Saint-Laurent"},
    {"name": "matches regardless of case and inner spacing", "stored": "12 Rue Ontario,  MONTREAL , qc,  h2x   1y4",
     "locality": {"city": "Montreal", "province": "QC", "postalCode": "H2X 1Y4"}, "expect": "12 Rue Ontario"},
    {"name": "with no locality fields it keeps the first segment", "stored": "77 Rue Peel, Montréal, QC", "locality": {}, "expect": "77 Rue Peel"},
    {"name": "never strips the last remaining segment", "stored": "Montréal", "locality": {"city": "Montréal"}, "expect": "Montréal"},
    {"name": "an empty address stays empty", "stored": "",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": ""}
  ],
  "composeFull": [
    {"name": "re-spells the apt the way the app books it", "stored": "4-1234 Rue Principale",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "1234 Rue Principale #4, Montréal, QC H2X 1Y4, Canada"},
    {"name": "a legacy full-string doc composes to the SAME string", "stored": "4-1234 Rue Principale, Montréal, QC H2X 1Y4, Canada",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "1234 Rue Principale #4, Montréal, QC H2X 1Y4, Canada"},
    {"name": "rejoins the parts around a street with no apt", "stored": "1234 Rue Principale",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "1234 Rue Principale, Montréal, QC H2X 1Y4, Canada"},
    {"name": "both stored shapes of a no-apt address compose identically", "stored": "1234 Rue Principale, Montréal, QC H2X 1Y4, Canada",
     "locality": {"city": "Montréal", "province": "QC", "postalCode": "H2X 1Y4", "country": "Canada"}, "expect": "1234 Rue Principale, Montréal, QC H2X 1Y4, Canada"},
    {"name": "omits parts that are missing", "stored": "1234 Rue Principale", "locality": {"city": "Montréal"}, "expect": "1234 Rue Principale, Montréal"},
    {"name": "with no locality fields it is just the displayed street", "stored": "4-1234 Rue Principale", "locality": {}, "expect": "1234 Rue Principale #4"},
    {"name": "an empty address yields no leading comma", "stored": "", "locality": {"city": "Montréal", "province": "QC"}, "expect": "Montréal, QC"},
    {"name": "everything empty stays empty", "stored": "", "locality": {}, "expect": ""}
  ]
}
```

- [ ] **Step 2: Rewrite the Dart test**

`test/features/maps/address_parser_street_locality_test.dart`, full contents. This replaces the stale header that named `functions/wave/mappers.js`.

```dart
// AddressParser.streetOnly / composeFull hand-mirror functions/client_address_utils.js;
// both suites read test/fixtures/shared/address.json.

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/maps/domain/address_parser.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  final fixture = loadSharedFixture('address.json');

  group('AddressParser.streetOnly', () {
    for (final c in sharedCases(fixture, 'streetOnly')) {
      test(c['name'] as String, () {
        final l = c['locality'] as Map<String, dynamic>;
        expect(
          AddressParser.streetOnly(
            c['stored'] as String,
            city: l['city'] as String? ?? '',
            province: l['province'] as String? ?? '',
            postalCode: l['postalCode'] as String? ?? '',
            country: l['country'] as String? ?? '',
          ),
          c['expect'],
        );
      });
    }
  });

  group('AddressParser.composeFull', () {
    for (final c in sharedCases(fixture, 'composeFull')) {
      test(c['name'] as String, () {
        final l = c['locality'] as Map<String, dynamic>;
        expect(
          AddressParser.composeFull(
            c['stored'] as String,
            city: l['city'] as String? ?? '',
            province: l['province'] as String? ?? '',
            postalCode: l['postalCode'] as String? ?? '',
            country: l['country'] as String? ?? '',
          ),
          c['expect'],
        );
      });
    }

    test('composing an already-composed value is stable', () {
      const city = 'Montréal';
      const province = 'QC';
      const postalCode = 'H2X 1Y4';
      const country = 'Canada';
      final once = AddressParser.composeFull(
        '4-1234 Rue Principale',
        city: city,
        province: province,
        postalCode: postalCode,
        country: country,
      );
      expect(
        AddressParser.composeFull(
          once,
          city: city,
          province: province,
          postalCode: postalCode,
          country: country,
        ),
        once,
      );
    });
  });
}
```

- [ ] **Step 3: Rewrite the jest test**

`functions/__tests__/client_address_utils.test.js`, full contents:

```js
"use strict";

// The JS half of a hand-mirrored pair (AddressParser in lib/features/maps/).
// Both suites read test/fixtures/shared/address.json.

const {
  streetFromAddress,
  composeFullAddress,
} = require("../client_address_utils");
const fixture = require("../../test/fixtures/shared/address.json");

describe("streetFromAddress", () => {
  test.each(fixture.streetOnly)("$name", (c) => {
    expect(streetFromAddress(c.stored, c.locality)).toBe(c.expect);
  });

  test("an undefined address stays empty", () => {
    expect(streetFromAddress(undefined, {city: "Montréal"})).toBe("");
  });
});

describe("composeFullAddress", () => {
  test.each(fixture.composeFull)("$name", (c) => {
    expect(composeFullAddress({address: c.stored, ...c.locality}))
        .toBe(c.expect);
  });

  test("a null doc composes to nothing", () => {
    expect(composeFullAddress(null)).toBe("");
  });
});
```

- [ ] **Step 4: Run both, expect PASS**

Run: `flutter test test/features/maps/address_parser_street_locality_test.dart` — Expected: PASS.
Run: `cd functions && npx jest __tests__/client_address_utils.test.js` — Expected: PASS.

- [ ] **Step 5: Prove it bites**

Change the first `composeFull` expectation's `#4` to `Apt 4`, and confirm both fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/shared/address.json test/features/maps/address_parser_street_locality_test.dart functions/__tests__/client_address_utils.test.js
git commit -m "Read street/compose address examples from one shared fixture"
```

---

### Task 10: Feature-flag defaults (runs AFTER the kill-switch plan)

**Prerequisite:** the kill-switch implementation plan's tasks that create `lib/core/remote_config/feature_flags.dart` and `functions/feature_flags_policy.js` are merged. This task replaces that plan's two hand-written parity tests with one fixture; if that plan already added parity tests, delete them in Step 4.

**Files:**
- Create: `test/fixtures/shared/feature_flags.json`
- Create: `test/core/remote_config/feature_flags_parity_test.dart`
- Create: `functions/__tests__/feature_flags_parity.test.js`

- [ ] **Step 1: Confirm the exported names**

Run: `grep -nE "toRemoteConfigDefaults|FLAG_DEFAULTS =" lib/core/remote_config/feature_flags.dart functions/feature_flags_policy.js`
Expected: one hit per file. The kill-switch plan defines `FeatureFlags.defaults.toRemoteConfigDefaults()` (a `Map<String, Object>`) and `FLAG_DEFAULTS` exported from `functions/feature_flags_policy.js`.

- [ ] **Step 2: Write `feature_flags.json`**

```json
{
  "defaults": {
    "feature_address_autocomplete": true,
    "feature_presence": true,
    "feature_live_activities": true,
    "feature_wave_sync": true,
    "min_supported_build": 0
  }
}
```

- [ ] **Step 3: Write both tests**

`test/core/remote_config/feature_flags_parity_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  test('in-code Remote Config defaults match the shared fixture', () {
    expect(
      FeatureFlags.defaults.toRemoteConfigDefaults(),
      loadSharedFixture('feature_flags.json')['defaults'],
    );
  });
}
```

`functions/__tests__/feature_flags_parity.test.js`:

```js
"use strict";

const {FLAG_DEFAULTS} = require("../feature_flags_policy");
const {defaults} = require("../../test/fixtures/shared/feature_flags.json");

test("in-code Remote Config defaults match the shared fixture", () => {
  expect(FLAG_DEFAULTS).toEqual(defaults);
});
```

- [ ] **Step 4: Run, prove, clean up**

Run: `flutter test test/core/remote_config/feature_flags_parity_test.dart` and `cd functions && npx jest __tests__/feature_flags_parity.test.js`. Expected: PASS on both.
Flip `"feature_presence"` to `false` in the fixture, and confirm both fail. Revert.
Delete any key-list parity test the kill-switch plan added on either side (`grep -rn "feature_wave_sync" test functions/__tests__` — only the two files above may assert the whole key set).

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/shared/feature_flags.json test/core/remote_config/feature_flags_parity_test.dart functions/__tests__/feature_flags_parity.test.js
git commit -m "Pin Remote Config defaults on both sides with one fixture"
```

---

### Task 11: Registry guard

**Files:**
- Create: `test/shared_fixtures_registry_test.dart`

- [ ] **Step 1: Write the test**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every shared fixture is read by a Dart test AND a jest test', () {
    final fixtures = Directory('test/fixtures/shared')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .toList();
    expect(fixtures, isNotEmpty);

    final dartSources = _sources('test', '.dart');
    final jestSources = _sources('functions/__tests__', '.js');
    for (final name in fixtures) {
      expect(
        dartSources.any((s) => s.contains("'$name'")),
        isTrue,
        reason: '$name has no Dart reader (loadSharedFixture)',
      );
      expect(
        jestSources.any((s) => s.contains('fixtures/shared/$name')),
        isTrue,
        reason: '$name has no jest reader',
      );
    }
  });
}

List<String> _sources(String root, String extension) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith(extension))
    .map((f) => f.readAsStringSync())
    .toList();
```

- [ ] **Step 2: Run, expect PASS**

Run: `flutter test test/shared_fixtures_registry_test.dart` — Expected: `All tests passed!`

- [ ] **Step 3: Prove it bites**

Create an empty `test/fixtures/shared/orphan.json` containing `{}`, and confirm the test fails with `orphan.json has no Dart reader`. Delete the file, and confirm it passes.

- [ ] **Step 4: Commit**

```bash
git add test/shared_fixtures_registry_test.dart
git commit -m "Fail when a shared fixture loses its Dart or jest reader"
```

---

### Task 12: Point the rules at the fixtures, then run everything

**Files:**
- Modify: `CLAUDE.md` (two bullets in the "Entity search" section)
- Modify: `.claude/rules/testing.md` (new section before `## Harness requirements`)
- Modify: `docs/ARCHITECTURE.md` (same section under `## Test Strategy`, kept in step with testing.md as CLAUDE.md requires)

- [ ] **Step 1: Edit `CLAUDE.md`**

Replace:

```
    search that silently returns nothing. `test/core/search/search_tokens_test.dart`
    and `functions/__tests__/search_tokens.test.js` share their worked examples
    value-for-value; change both sides in one commit and keep the examples equal.
```

with:

```
    search that silently returns nothing. Both suites read their worked examples
    from `test/fixtures/shared/search_tokens.json`; change both implementations
    in one commit and add new examples to the fixture, never inline.
```

Replace:

```
    nobody can find. Add a letter to both tables or to neither, and keep the
    shared accent examples in the two suites equal.
```

with:

```
    nobody can find. Add a letter to both tables or to neither;
    `test/fixtures/shared/accent_fold.json` pins all 64 Latin-1 entries on both sides.
```

- [ ] **Step 2: Add the section to `.claude/rules/testing.md`**

Insert before `## Harness requirements`:

```markdown
## Hand-mirrored Dart/JS pairs

- Their worked examples live in ONE JSON file under `test/fixtures/shared/`,
  read by both suites (`loadSharedFixture` in Dart, `require` in jest). Never
  restate an example inline on one side. That is how the image-magic and
  address pairs drifted while both suites stayed green.
- A fixture case that fails on first run is a real divergence. Fix the code,
  never the fixture value.
- `test/shared_fixtures_registry_test.dart` fails when a fixture loses its
  reader on either side. Side-specific cases (generated inputs, `null`,
  model types) stay in their own suite.
```

- [ ] **Step 3: Mirror it in `docs/ARCHITECTURE.md`**

Add the same section, at `###` level, inside `## Test Strategy` (line ~1797), in the same relative position as in testing.md.

- [ ] **Step 4: Full verification**

Run: `flutter analyze` — Expected: `No issues found!`
Run: `dart run tool/test.dart` — Expected: all shards pass.
Run: `cd functions && npm test && npm run lint` — Expected: all suites pass, coverage thresholds met, no lint output.
Run: `for f in test/fixtures/shared/*.json; do head -c 3 "$f" | od -An -tx1; done` — Expected: no line reads ` ef bb bf`.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md .claude/rules/testing.md docs/ARCHITECTURE.md
git commit -m "Document shared Dart/JS fixtures as the home for mirrored examples"
```

---

## Phase 2 — future option, NOT in this plan

Generate search tokens server-side only: a Firestore `onDocumentWritten` trigger on `clients` and `appointments` writes `searchTokens` / `historySearchScopes`, and the Dart `searchIndexTokens` copy plus its fixture half are deleted.
- **Cost — backfill:** every existing doc needs the trigger's tokens, the same way `backfill-search-tokens.js` was a release prerequisite, and an app build that still writes tokens must not fight the trigger during rollout.
- **Cost — write amplification:** every client or appointment write becomes two writes (the save, then the trigger's token patch), plus one function invocation. The trigger must also skip its own echo write.
- **Cost — sole writer:** the trigger becomes the ONLY index writer, so a failed or lagging invocation is a record that is briefly or permanently unsearchable. `firestore.rules` would then forbid client writes to the token fields.
- **Gain:** the Dart tokenizer, its fold table and this fixture's index half all disappear; the query side stays JS-only.
