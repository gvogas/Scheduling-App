import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/policies/client_name_policy.dart';
import 'package:scheduling/features/employees/domain/policies/employee_name_policy.dart';

/// S2: `TextLimits` caps must be applied through
/// `LengthLimitingTextInputFormatter`, which truncates a too-long paste
/// rather than rejecting it outright.
void main() {
  test('LengthLimitingTextInputFormatter truncates to cap', () {
    final formatter = LengthLimitingTextInputFormatter(
      TextLimits.appointmentTitle,
    );
    final tooLong = 'x' * (TextLimits.appointmentTitle + 50);

    final result = formatter.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: tooLong,
        selection: TextSelection.collapsed(offset: tooLong.length),
      ),
    );

    expect(result.text.length, TextLimits.appointmentTitle);
  });

  test('caps stay within Firestore safe ranges', () {
    // Guards against a cap being bumped into the megabyte range, which
    // would blow past Firestore's 1 MiB doc-size ceiling.
    expect(TextLimits.appointmentTitle, lessThan(10000));
    expect(TextLimits.appointmentAddress, lessThan(10000));
    expect(TextLimits.appointmentNotes, lessThan(50000));
    expect(TextLimits.appointmentMaterials, lessThan(50000));
    expect(TextLimits.personName, lessThan(10000));
    expect(TextLimits.phone, lessThan(100));
    expect(TextLimits.email, lessThan(1000));
  });

  group('client caps never exceed the firestore.rules caps', () {
    // Dart, CEL and JS cannot share a constant, so these caps are a
    // hand-mirror — and this repo has been bitten in BOTH directions: a
    // client cap above the rules cap makes every long value fail the write
    // with an opaque `permission-denied`, and a rules cap below the widest
    // value a shipped write path can produce makes those docs permanently
    // un-updatable. Reading the rules text back is the only mechanism
    // available to turn that comment into a failing build.
    late final rules = File('firestore.rules').readAsStringSync();

    /// The TIGHTEST cap firestore.rules puts on `field`, across both forms the
    /// rules use: the `isBoundedString(d.x, N)` helper and the inline
    /// `data.x.size() <= N` the client-data validator is written with.
    ///
    /// The minimum, not the first match: several names appear in more than one
    /// collection's validator (`phone` is 40 on `/users` but 32 on `/clients`),
    /// and a client cap has to clear whichever rule can reject the write.
    int rulesCapFor(String field) {
      final name = RegExp.escape(field);
      final caps = [
        ...RegExp(
          r'isBoundedString\(\s*(?:d|data|request\.resource\.data)\.' +
              name +
              r'\s*,\s*(\d+)\s*\)',
        ).allMatches(rules),
        ...RegExp(
          r'(?:d|data|request\.resource\.data)\.' +
              name +
              r'\.size\(\)\s*<=\s*(\d+)',
        ).allMatches(rules),
      ].map((m) => int.parse(m.group(1)!)).toList();
      expect(
        caps,
        isNotEmpty,
        reason: 'no length cap found for "$field" in firestore.rules',
      );
      return caps.reduce((a, b) => a < b ? a : b);
    }

    /// The cap `isValidClientData` puts on `field`, scoped to that ONE
    /// validator's body.
    ///
    /// `rulesCapFor` takes the MINIMUM across the whole file, which is right
    /// for a value the app writes into more than one collection but cannot
    /// express a client cap that is deliberately WIDER than the appointment
    /// cap on the same field name: `address` is 533 on `/clients` and 500 on
    /// `/appointments`, so an unscoped lookup measures a client-only write
    /// path against a bound belonging to a collection it never touches.
    ///
    /// The body is extracted first rather than regexing the whole file for
    /// the inline `data.x.size() <= N` form. That form happens to be unique
    /// to this validator today, which makes an unscoped search right by
    /// accident of file order — the trap
    /// `appointment_span_rules_test.dart:80-83` documents and scopes around.
    int clientRulesCapFor(String field) {
      final body = RegExp(
        r'function isValidClientData\(data\) \{(.*?)\n    \}',
        dotAll: true,
      ).firstMatch(rules);
      expect(body, isNotNull, reason: 'isValidClientData not found');

      final match = RegExp(
        r'data\.' + RegExp.escape(field) + r'\.size\(\)\s*<=\s*(\d+)',
      ).firstMatch(body!.group(1)!);
      expect(
        match,
        isNotNull,
        reason: 'isValidClientData puts no length cap on "$field"',
      );
      return int.parse(match!.group(1)!);
    }

    // Appointment fields — all four are currently exactly equal, so a bump on
    // either side breaks the write. That is the point of pinning them.
    test('appointment title', () {
      expect(
        TextLimits.appointmentTitle,
        lessThanOrEqualTo(rulesCapFor('title')),
      );
    });

    test('appointment address', () {
      expect(
        TextLimits.appointmentAddress,
        lessThanOrEqualTo(rulesCapFor('address')),
      );
    });

    test('appointment notes', () {
      expect(
        TextLimits.appointmentNotes,
        lessThanOrEqualTo(rulesCapFor('notes')),
      );
    });

    test('appointment materials', () {
      expect(
        TextLimits.appointmentMaterials,
        lessThanOrEqualTo(rulesCapFor('materialsNeeded')),
      );
    });

    test('client name, with the phone number appended for Wave', () {
      // The stored `clients/{id}.name` is NOT just what the admin typed — it
      // is `"<typed name> <phone>"`, because that field is synced verbatim as
      // the Wave customer name (ClientNamePolicy.composeStored). So the value
      // the rules have to admit is the sum of the two field caps plus the
      // separating space, and sizing the rule to `personName` alone rejects
      // every long client save with an opaque `permission-denied`.
      expect(
        TextLimits.personName + 1 + TextLimits.phone,
        lessThanOrEqualTo(rulesCapFor('name')),
      );
    });

    test('the widest crew-note author name fits the fieldNotes cap', () {
      // `authorName` on a crew note is `displayEmployeeName`, which joins two
      // 100-char halves with a space (201) and falls back to the stored
      // `users.name` or the email. A cap sized under any of those refuses the
      // note outright as an opaque `permission-denied`, with no field for the
      // author to correct.
      final widestComposed = composeEmployeeName(
        firstName: 'a' * TextLimits.employeeNameHalf,
        lastName: 'b' * TextLimits.employeeNameHalf,
        fallback: '',
      );
      expect(
        widestComposed.length,
        lessThanOrEqualTo(rulesCapFor('authorName')),
      );
      expect(rulesCapFor('name'), lessThanOrEqualTo(rulesCapFor('authorName')));
    });

    test('the widest name composeStored can emit fits the client cap', () {
      // `composeStored` returns the phone number for a person and the stripped
      // base name for a business, so its widest output is a full-length
      // business name — never the two joined. A regression to the old
      // "<name> <number>" shape would push this past the cap and fail every
      // long client save with an opaque `permission-denied`, so pin the
      // ACTUAL output rather than the arithmetic.
      final widestPerson = ClientNamePolicy.composeStored(
        baseName: 'a' * TextLimits.personName,
        phone: '0' * TextLimits.phone,
        mobile: '0' * TextLimits.mobile,
      );
      final widestBusiness = ClientNamePolicy.composeStored(
        baseName: 'a' * TextLimits.personName,
        phone: '0' * TextLimits.phone,
        mobile: '0' * TextLimits.mobile,
        type: ClientType.commercial,
      );
      expect(widestPerson.length, lessThanOrEqualTo(rulesCapFor('name')));
      expect(widestBusiness.length, lessThanOrEqualTo(rulesCapFor('name')));
    });

    test('a client address carries its apt, so the cap is the SUM', () {
      // Both client sheets store `AddressParser.canonicalFrom(street, apt)`,
      // which joins the street field and the apt field with a separator. Sized
      // to the street field alone, the rule rejects the whole client save.
      expect(
        TextLimits.appointmentAddress + 1 + TextLimits.aptUnit,
        lessThanOrEqualTo(clientRulesCapFor('address')),
      );
    });

    test('an appointment clientName is the two client name halves', () {
      // Denormalized from `ClientRecord.displayName`, which composes
      // `firstName` + " " + `lastName` on a person — two 200-char fields, not
      // one. Sized to `personName` the appointment save fails outright.
      expect(
        TextLimits.firstName + 1 + TextLimits.lastName,
        lessThanOrEqualTo(rulesCapFor('clientName')),
      );
    });

    test('an appointment photo fileName', () {
      // Capped by the appointment-images subcollection rule, and
      // `appendAppointmentPictures` writes a whole photo batch in ONE
      // WriteBatch — so one over-long basename fails the batch with an opaque
      // `permission-denied` and takes every valid photo beside it down too.
      expect(
        TextLimits.imageFileName,
        lessThanOrEqualTo(rulesCapFor('fileName')),
      );
    });

    test('the widest name composeFileName can emit fits that cap', () {
      // Pin the ACTUAL output, not the constant: `ImageStorageService` builds
      // `<millis>_<originalName>` from whatever the picker hands it, so the
      // millisecond prefix has to be inside the bound too.
      final widest = ImageStorageService.composeFileName(
        '${'x' * 5000}.jpg',
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      expect(widest.length, lessThanOrEqualTo(rulesCapFor('fileName')));
    });

    test('client email', () {
      expect(TextLimits.email, lessThanOrEqualTo(rulesCapFor('email')));
    });

    test('phone', () {
      expect(TextLimits.phone, lessThanOrEqualTo(rulesCapFor('phone')));
    });

    test('the Wave import truncates below every rules cap', () {
      // The import writes client docs with the Admin SDK, which BYPASSES the
      // rules — so a cap here that exceeds the rules cap does not fail the
      // import, it writes a doc the APP can never update again (every later
      // save is an opaque `permission-denied`). `IMPORT_FIELD_CAPS` is a third
      // hand-mirror of `isValidClientData` and was the only one with nothing
      // pinning it.
      final source = File('functions/wave/mappers.js').readAsStringSync();
      final block = RegExp(
        r'const IMPORT_FIELD_CAPS = \{([^}]*)\}',
      ).firstMatch(source);
      expect(block, isNotNull, reason: 'IMPORT_FIELD_CAPS not found');

      final caps = {
        for (final m in RegExp(r'(\w+):\s*(\d+)').allMatches(block!.group(1)!))
          m.group(1)!: int.parse(m.group(2)!),
      };
      expect(caps, isNotEmpty);

      // Deny by default. An allowlist here filtered `caps` down to 6 of the 12
      // fields the map defines and skipped the rest in silence, which is the
      // one thing this test exists to prevent: adding a capped field to
      // `mappers.js` has to FAIL here until it is checked, not sail through.
      for (final entry in caps.entries) {
        final rulesCap = switch (entry.key) {
          'name' ||
          'firstName' ||
          'lastName' ||
          'email' ||
          'phone' ||
          'mobile' ||
          'address' ||
          'addressLine2' ||
          'city' ||
          'province' ||
          'country' ||
          'postalCode' => clientRulesCapFor(entry.key),
          _ => fail(
            'IMPORT_FIELD_CAPS.${entry.key} is new and unchecked. Add it here '
            'with the /clients rules cap it must clear — an import cap above '
            'the rules cap writes a doc the app can never update again.',
          ),
        };
        expect(
          entry.value,
          lessThanOrEqualTo(rulesCap),
          reason: 'IMPORT_FIELD_CAPS.${entry.key} exceeds its rules cap',
        );
      }
    });
  });

  test('an auth email fits what the account callables accept', () {
    // createEmployeeAccount / changeEmployeeEmail both
    // `requireString(req.data, "email", 254)`. A looser client cap lets the
    // admin type a value the callable rejects as `invalid-argument`, which
    // surfaces as an unexplained "Something went wrong" they cannot fix.
    expect(TextLimits.authEmail, lessThanOrEqualTo(254));

    final source = [
      'functions/employee_accounts_admin.js',
      'functions/employee_accounts_self.js',
    ].map((path) => File(path).readAsStringSync()).join('\n');
    final caps = RegExp(
      r'requireString\(\s*req\.data,\s*"email",\s*(\d+)\s*\)',
    ).allMatches(source).map((m) => int.parse(m.group(1)!)).toList();
    expect(caps, isNotEmpty);
    for (final cap in caps) {
      expect(TextLimits.authEmail, lessThanOrEqualTo(cap));
    }
  });

  // A longer passphrase passed every client check, then failed server-side as
  // "weak password".
  test('a new password fits what completeEmployeeSetup accepts', () {
    final source = File(
      'functions/employee_accounts_self.js',
    ).readAsStringSync();
    final caps = RegExp(
      r'requireString\(\s*req\.data,\s*"newPassword",\s*(\d+)\s*\)',
    ).allMatches(source).map((m) => int.parse(m.group(1)!)).toList();
    expect(caps, isNotEmpty);
    for (final cap in caps) {
      expect(TextLimits.password, lessThanOrEqualTo(cap));
    }
  });
}
