import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/policies/client_name_policy.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

import '../../../fixtures/shared/shared_fixture.dart';

/// liftPhoneFromName examples are shared with jest: test/fixtures/shared/client_name_lift.json.
void main() {
  group('stripPhone', () {
    test('removes the number this app appended', () {
      expect(
        ClientNamePolicy.stripPhone(
          'Marc Tremblay (514) 555-1234',
          phone: '(514) 555-1234',
        ),
        'Marc Tremblay',
      );
    });

    test('removes a legacy number typed in another shape', () {
      // The doc's stored phone is the masked form; the name was typed years
      // earlier with dashes. An exact-suffix test alone misses this.
      expect(
        ClientNamePolicy.stripPhone(
          'Marc Tremblay 514-555-1234',
          phone: '(514) 555-1234',
        ),
        'Marc Tremblay',
      );
    });

    test('matches an 11-digit form against the stored 10-digit one', () {
      expect(
        ClientNamePolicy.stripPhone(
          'Marc Tremblay 1-514-555-1234',
          phone: '(514) 555-1234',
        ),
        'Marc Tremblay',
      );
    });

    test('falls back to mobile when phone is empty', () {
      expect(
        ClientNamePolicy.stripPhone(
          'Marc Tremblay (514) 555-1234',
          mobile: '(514) 555-1234',
        ),
        'Marc Tremblay',
      );
    });

    test('leaves a trailing number that is NOT this client’s', () {
      // The whole reason the digits are compared rather than the shape: a
      // business genuinely named with a number must survive.
      expect(
        ClientNamePolicy.stripPhone(
          'Depanneur 5148889999',
          phone: '(514) 555-1234',
        ),
        'Depanneur 5148889999',
      );
    });

    test('leaves the name alone when the doc has no number at all', () {
      expect(
        ClientNamePolicy.stripPhone('Marc Tremblay 514-555-1234'),
        'Marc Tremblay 514-555-1234',
      );
    });

    test('returns empty when the name is nothing but the number', () {
      // Load-bearing: this is what lets displayFor fall through to the halves
      // rather than rendering a phone number as somebody's name.
      expect(
        ClientNamePolicy.stripPhone(
          '(514) 555-1234',
          phone: '(514) 555-1234',
        ),
        '',
      );
    });

    test('is idempotent', () {
      const stored = 'Marc Tremblay (514) 555-1234';
      final once = ClientNamePolicy.stripPhone(stored, phone: '(514) 555-1234');
      expect(
        ClientNamePolicy.stripPhone(once, phone: '(514) 555-1234'),
        once,
      );
    });
  });

  group('composeStored', () {
    test('names a PERSON by their phone number, BARE', () {
      // The `phone` field keeps its formatting; only the Wave customer name is
      // reduced (owner call 2026-08-16).
      expect(
        ClientNamePolicy.composeStored(
          baseName: 'Marc Tremblay',
          phone: '(514) 555-1234',
        ),
        '5145551234',
      );
    });

    test('is idempotent', () {
      // Every ordinary save runs through this, so a second pass over an
      // already-composed name must be a no-op.
      expect(
        ClientNamePolicy.composeStored(
          baseName: '5145551234',
          phone: '(514) 555-1234',
        ),
        '5145551234',
      );
    });

    test('reduces a name still stored in the formatted shape', () {
      // `stripPhone` digit-matches, which is what carries the docs written
      // before the bare rule over to it.
      expect(
        ClientNamePolicy.composeStored(
          baseName: '(514) 555-1234',
          phone: '(514) 555-1234',
        ),
        '5145551234',
      );
    });

    test('keeps the country code of an international number', () {
      expect(
        ClientNamePolicy.composeStored(
          baseName: 'Amelie Roy',
          phone: '+33 1 42 68 53 00',
        ),
        '+33142685300',
      );
    });

    test('keeps a BUSINESS name — that is its identity in Wave', () {
      expect(
        ClientNamePolicy.composeStored(
          baseName: 'Vogas Plumbing',
          phone: '(514) 555-1234',
          type: ClientType.commercial,
        ),
        'Vogas Plumbing',
      );
    });

    test('keeps a business recognisable only by its NAME', () {
      // The Wave import sets no `type`, so these carry none at all.
      for (final name in [
        '3101-5696 qc inc.',
        '1505 Village de Bergerac',
        'Information technology group',
        // The digit is not always leading.
        'Condo 706',
        'Syndicat de copropriété du Parc',
      ]) {
        expect(
          ClientNamePolicy.composeStored(
            baseName: name,
            phone: '(514) 555-1234',
          ),
          name,
        );
      }
    });

    test('renames a person whose name merely contains those letters', () {
      for (final name in ['Vincent Cormier', 'Marc Enrico']) {
        expect(
          ClientNamePolicy.composeStored(
            baseName: name,
            phone: '(514) 555-1234',
          ),
          '5145551234',
        );
      }
    });

    test('leaves the name bare when there is no phone', () {
      expect(
        ClientNamePolicy.composeStored(baseName: 'Marc Tremblay', phone: ''),
        'Marc Tremblay',
      );
    });

    test('a nameless client is stored as its number, not as blank', () {
      // A blank name floats the doc to the top of the name-ordered client list
      // and leaves its avatar with no initial.
      expect(
        ClientNamePolicy.composeStored(
          baseName: '',
          phone: '(514) 555-1234',
        ),
        '5145551234',
      );
    });

    test('a BUSINESS named only by its own number keeps the number', () {
      // `stripPhone` correctly reduces such a name to '' — it IS nothing but
      // this client's number — and the business branch used to return that
      // blank. An empty `name` is rejected by Wave on every push, so the
      // customer dead-letters permanently and 'Retry failed' re-sends the same
      // refusal (client o0KcOnJSgjvMHYpmcZ44, 2026-08-30). A business has no
      // first/last to fall back on, so the number is the only identity left.
      for (final type in [ClientType.commercial, ClientType.building]) {
        expect(
          ClientNamePolicy.composeStored(
            baseName: '5144586186',
            phone: '(514) 458-6186',
            type: type,
          ),
          '5144586186',
        );
      }
      expect(
        ClientNamePolicy.composeStored(
          baseName: '(514) 458-6186',
          phone: '(514) 458-6186',
          businessName: '3101-5696 qc inc.',
        ),
        '5144586186',
      );
    });

    test('never returns blank while a base name or a number exists', () {
      // The invariant the case above is one instance of: `name` is the Wave
      // customer identity, so composing one away is never the right answer.
      for (final type in ClientType.values) {
        expect(
          ClientNamePolicy.composeStored(
            baseName: '514-458-6186',
            phone: '(514) 458-6186',
            type: type,
          ),
          isNot(''),
        );
      }
    });
  });

  group('displayFor — a PERSON shows their halves', () {
    test('prefers the first/last halves over the stored name', () {
      expect(
        ClientNamePolicy.displayFor(
          name: 'Marc Tremblay (514) 555-1234',
          phone: '(514) 555-1234',
          firstName: 'Marc',
          lastName: 'Tremblay',
          type: ClientType.residential,
        ),
        'Marc Tremblay',
      );
    });

    test('takes a single half on its own', () {
      expect(
        ClientNamePolicy.displayFor(
          name: 'Marc (514) 555-1234',
          phone: '(514) 555-1234',
          firstName: 'Marc',
          type: ClientType.residential,
        ),
        'Marc',
      );
    });

    test('falls back to the stored name with the number stripped', () {
      expect(
        ClientNamePolicy.displayFor(
          name: 'Marc Tremblay (514) 555-1234',
          phone: '(514) 555-1234',
          type: ClientType.residential,
        ),
        'Marc Tremblay',
      );
    });

    test('a bare number beats an empty display name', () {
      expect(
        ClientNamePolicy.displayFor(
          name: '(514) 555-1234',
          phone: '(514) 555-1234',
          type: ClientType.residential,
        ),
        '(514) 555-1234',
      );
    });
  });

  group('displayFor — a BUSINESS shows its business name', () {
    test('a commercial client keeps its business name', () {
      // The load-bearing case: first/last is the CONTACT PERSON here, not the
      // client, so preferring the halves would render the company as a person.
      expect(
        ClientNamePolicy.displayFor(
          name: 'Vogas Plumbing (514) 555-1234',
          phone: '(514) 555-1234',
          firstName: 'Marc',
          lastName: 'Tremblay',
          type: ClientType.commercial,
        ),
        'Vogas Plumbing',
      );
    });

    test('property management counts as a business', () {
      expect(
        ClientNamePolicy.displayFor(
          name: 'Gestion Immobiliere ABC',
          firstName: 'Marc',
          lastName: 'Tremblay',
          type: ClientType.building,
        ),
        'Gestion Immobiliere ABC',
      );
    });

    test('a legacy businessName doc is a business even with no type', () {
      // Pre-Wave-reshape docs predate `type`, so they arrive `unset` and would
      // otherwise be read as people.
      expect(
        ClientNamePolicy.displayFor(
          name: 'Acme Industries',
          businessName: 'Acme Industries',
          firstName: 'Marc',
          lastName: 'Tremblay',
          // No type at all: the legacy businessName is what makes it a
          // business, which is the branch this asserts.
          type: ClientType.unset,
        ),
        'Acme Industries',
      );
    });

    test('falls back to the legacy businessName when name is blank', () {
      expect(
        ClientNamePolicy.displayFor(
          name: '',
          businessName: 'Acme Inc',
          type: ClientType.unset,
        ),
        'Acme Inc',
      );
    });

    test(
      'falls back to the contact person when no company name is on file',
      () {
        // Better than rendering the phone number as the client's name.
        expect(
          ClientNamePolicy.displayFor(
            name: '(514) 555-1234',
            phone: '(514) 555-1234',
            firstName: 'Marc',
            lastName: 'Tremblay',
            type: ClientType.commercial,
          ),
          'Marc Tremblay',
        );
      },
    );
  });

  // I2: `baseNameFor` seeds the edit sheet's name field on EVERY client edit,
  // and its own docstring says getting it wrong renames real Wave customers —
  // yet it had no Dart coverage at all. It is deliberately Dart-only (the
  // backfill composes from the raw stored name and never needs the fallback),
  // so there is no JS twin to lean on either.
  group('baseNameFor', () {
    test('returns the stored name with this client’s number stripped', () {
      expect(
        ClientNamePolicy.baseNameFor(
          name: 'Vogas Plumbing (514) 555-1234',
          phone: '(514) 555-1234',
        ),
        'Vogas Plumbing',
      );
    });

    test('prefers the STORED name over the halves — never displayFor', () {
      // The whole point of the split: on a business the stored name holds the
      // BUSINESS and the halves hold its contact person, so seeding from the
      // display name and saving would rename the customer in Wave.
      expect(
        ClientNamePolicy.baseNameFor(
          name: 'Vogas Plumbing',
          firstName: 'Marc',
          lastName: 'Tremblay',
        ),
        'Vogas Plumbing',
      );
    });

    test('falls back to the halves when the name is only a number', () {
      // A person's stored name IS their number, so stripping leaves nothing —
      // and a required form field cannot be seeded with blank.
      expect(
        ClientNamePolicy.baseNameFor(
          name: '(514) 555-1234',
          phone: '(514) 555-1234',
          firstName: 'Marc',
          lastName: 'Tremblay',
        ),
        'Marc Tremblay',
      );
    });

    test('takes a single half on its own', () {
      expect(
        ClientNamePolicy.baseNameFor(
          name: '(514) 555-1234',
          phone: '(514) 555-1234',
          lastName: 'Tremblay',
        ),
        'Tremblay',
      );
    });

    test('falls back to the legacy businessName last of all', () {
      expect(
        ClientNamePolicy.baseNameFor(name: '', businessName: 'Acme Inc'),
        'Acme Inc',
      );
    });

    test('round-trips through composeStored for a business', () {
      // The property the edit sheet depends on: seed the field, save it back
      // unchanged, and the stored name must be byte-identical — otherwise an
      // ordinary save renames the customer on live invoices.
      const stored = 'Vogas Plumbing';
      final seeded = ClientNamePolicy.baseNameFor(
        name: stored,
        phone: '(514) 555-1234',
        businessName: stored,
      );
      expect(
        ClientNamePolicy.composeStored(
          baseName: seeded,
          phone: '(514) 555-1234',
          type: ClientType.commercial,
          businessName: stored,
        ),
        stored,
      );
    });
  });

  group('isBusiness', () {
    test('the two organization types', () {
      expect(ClientNamePolicy.isBusiness(type: ClientType.commercial), isTrue);
      expect(
        ClientNamePolicy.isBusiness(type: ClientType.building),
        isTrue,
      );
    });

    test('a residential or untyped client is a person', () {
      expect(
        ClientNamePolicy.isBusiness(type: ClientType.residential),
        isFalse,
      );
      expect(ClientNamePolicy.isBusiness(), isFalse);
    });

    test('a legacy businessName makes it a business regardless of type', () {
      expect(ClientNamePolicy.isBusiness(businessName: 'Acme Inc'), isTrue);
    });
  });

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

  group('splitPersonName', () {
    test('takes the last token as the surname', () {
      final split = ClientNamePolicy.splitPersonName('Marc Tremblay');
      expect(split.firstName, 'Marc');
      expect(split.lastName, 'Tremblay');
    });

    test('keeps every earlier token in the given name', () {
      final split = ClientNamePolicy.splitPersonName('Jean Paul Belanger');
      expect(split.firstName, 'Jean Paul');
      expect(split.lastName, 'Belanger');
    });

    test('leaves a one-token name with no surname', () {
      final split = ClientNamePolicy.splitPersonName('  Cher  ');
      expect(split.firstName, 'Cher');
      expect(split.lastName, '');
    });

    test('yields nothing for an empty name', () {
      final split = ClientNamePolicy.splitPersonName('   ');
      expect(split.firstName, '');
      expect(split.lastName, '');
    });
  });

  group('composeSave', () {
    test('rescues a person typed name into the halves', () {
      // THE BUG THIS EXISTS FOR: Name is required on both sheets while the two
      // halves are optional, so the composed name replacing the typed one with
      // the phone number destroyed the only copy of it.
      final saved = ClientNamePolicy.composeSave(
        baseName: 'Marc Tremblay',
        phone: '(514) 555-1234',
      );
      expect(saved.name, '5145551234');
      expect(saved.firstName, 'Marc');
      expect(saved.lastName, 'Tremblay');
    });

    test('never clobbers a half that is already there', () {
      // Also what makes an ordinary re-save idempotent.
      final saved = ClientNamePolicy.composeSave(
        baseName: 'Marc Tremblay',
        phone: '(514) 555-1234',
        firstName: 'Marc-Andre',
      );
      expect(saved.name, '5145551234');
      expect(saved.firstName, 'Marc-Andre');
      expect(saved.lastName, '');
    });

    test('leaves a business name and its CONTACT halves alone', () {
      // On a business the halves are the contact person, not the client —
      // overwriting them renders the company as its contact.
      final saved = ClientNamePolicy.composeSave(
        baseName: 'Vogas Plumbing',
        phone: '(514) 555-1234',
        type: ClientType.commercial,
      );
      expect(saved.name, 'Vogas Plumbing');
      expect(saved.firstName, '');
      expect(saved.lastName, '');
    });

    test('leaves a legacy business carrying businessName alone', () {
      final saved = ClientNamePolicy.composeSave(
        baseName: 'Vogas Plumbing',
        phone: '(514) 555-1234',
        businessName: 'Vogas Plumbing',
      );
      expect(saved.name, 'Vogas Plumbing');
      expect(saved.firstName, '');
    });

    test('leaves a name the heuristic reads as a business alone', () {
      final saved = ClientNamePolicy.composeSave(
        baseName: '1505 Village de Bergerac',
        phone: '(514) 555-1234',
      );
      expect(saved.name, '1505 Village de Bergerac');
      expect(saved.firstName, '');
    });

    test('rescues nothing when the name was not replaced', () {
      // No number on file, so `composeStored` returns the base unchanged and
      // there is nothing at risk.
      final saved = ClientNamePolicy.composeSave(
        baseName: 'Marc Tremblay',
        phone: '',
      );
      expect(saved.name, 'Marc Tremblay');
      expect(saved.firstName, '');
    });

    test('is idempotent on a doc it already repaired', () {
      final first = ClientNamePolicy.composeSave(
        baseName: 'Marc Tremblay',
        phone: '(514) 555-1234',
      );
      // Second save seeds from the stored name, which is now the number.
      final second = ClientNamePolicy.composeSave(
        baseName: first.name,
        phone: '(514) 555-1234',
        firstName: first.firstName,
        lastName: first.lastName,
      );
      expect(second.name, '5145551234');
      expect(second.firstName, 'Marc');
      expect(second.lastName, 'Tremblay');
    });
  });
}
