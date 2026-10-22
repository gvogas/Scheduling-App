import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

// The clients list filters its loaded pages through this exact policy method,
// so these tests exercise the real matcher (no hand-copied mirror to drift).
bool _matches(ClientRecord c, String query) =>
    ClientSearchPolicy.matchesClient(c, query);

void main() {
  group('ClientSearchPolicy.shouldSearch', () {
    test('rejects empty and whitespace queries', () {
      expect(ClientSearchPolicy.shouldSearch(''), isFalse);
      expect(ClientSearchPolicy.shouldSearch('   '), isFalse);
    });

    test('rejects punctuation-only queries (nothing searchable)', () {
      expect(ClientSearchPolicy.shouldSearch('@'), isFalse);
      expect(ClientSearchPolicy.shouldSearch('---'), isFalse);
    });

    test('searches from the first character; single letters trigger it', () {
      expect(ClientSearchPolicy.shouldSearch('a'), isTrue);
      expect(ClientSearchPolicy.shouldSearch('\u00E9'), isTrue);
    });

    test('searches from the first digit; single digits trigger it', () {
      expect(ClientSearchPolicy.shouldSearch('5'), isTrue);
    });

    test('accepts longer text and phone queries', () {
      expect(ClientSearchPolicy.shouldSearch('ab'), isTrue);
      expect(ClientSearchPolicy.shouldSearch('Jo'), isTrue);
      expect(ClientSearchPolicy.shouldSearch('514'), isTrue);
      expect(ClientSearchPolicy.shouldSearch('5-14'), isTrue);
    });
  });

  group('ClientSearchPolicy.normalize', () {
    test('lowercases', () {
      expect(ClientSearchPolicy.normalize('ABC'), 'abc');
    });

    test('strips accents', () {
      expect(ClientSearchPolicy.normalize('Montr\u00E9al'), 'montreal');
      expect(ClientSearchPolicy.normalize('Fa\u00E7ade'), 'facade');
      expect(
        ClientSearchPolicy.normalize(
          '\u00E0\u00E1\u00E2\u00E3\u00E4\u00E5 '
          '\u00E8\u00E9\u00EA\u00EB '
          '\u00EC\u00ED\u00EE\u00EF '
          '\u00F2\u00F3\u00F4\u00F5\u00F6 '
          '\u00F9\u00FA\u00FB\u00FC',
        ),
        'aaaaaa eeee iiii ooooo uuuu',
      );
    });

    test('collapses non-alphanumerics to single spaces and trims', () {
      expect(ClientSearchPolicy.normalize('  Hello, World!  '), 'hello world');
      expect(ClientSearchPolicy.normalize('a---b'), 'a b');
    });
  });

  group('ClientSearchPolicy.digitsOnly', () {
    test('keeps only 0-9', () {
      expect(ClientSearchPolicy.digitsOnly('+1 (514) 555-0101'), '15145550101');
      expect(ClientSearchPolicy.digitsOnly('abc'), '');
    });
  });

  group('ClientSearchPolicy.cacheKey', () {
    test('two queries that normalize identically share a cache key', () {
      expect(
        ClientSearchPolicy.cacheKey('Montr\u00E9al'),
        ClientSearchPolicy.cacheKey('  MONTREAL  '),
      );
    });
  });

  group('ClientSearchPolicy.matchesClient', () {
    const sophie = ClientRecord(
      id: 'c1',
      name: 'Tremblay Services',
      firstName: 'Sophie',
      lastName: 'Tremblay',
      address: '123 Rue Sainte-Catherine',
      city: 'Montr\u00E9al',
      mobile: '438-555-0199',
      email: 'sophie@tremblay.com',
      contacts: [
        ClientContact(
          name: 'Marc Lefebvre',
          phone: '514-555-7777',
          email: 'marc@lefebvre.ca',
        ),
      ],
    );

    test('firstName-only query matches the client', () {
      expect(_matches(sophie, 'Sophie'), isTrue);
    });

    test('partial firstName match (case-insensitive) matches the client', () {
      expect(_matches(sophie, 'soph'), isTrue);
    });

    test('business/display name matches the client', () {
      expect(_matches(sophie, 'Tremblay Services'), isTrue);
    });

    test('email query matches the client', () {
      expect(_matches(sophie, 'sophie@tremblay.com'), isTrue);
    });

    test('address query matches the client', () {
      expect(_matches(sophie, 'Sainte-Catherine'), isTrue);
    });

    test('accent-insensitive city query matches the client', () {
      expect(_matches(sophie, 'montreal'), isTrue);
    });

    test('contact name matches the client', () {
      expect(_matches(sophie, 'Lefebvre'), isTrue);
    });

    test('contact email matches the client', () {
      expect(_matches(sophie, 'marc@lefebvre.ca'), isTrue);
    });

    test('contact phone digits match the client', () {
      expect(_matches(sophie, '5145557777'), isTrue);
    });

    test('mobile-only query matches the client', () {
      expect(_matches(sophie, '4385550199'), isTrue);
    });

    test('partial mobile digits match the client', () {
      expect(_matches(sophie, '5550199'), isTrue);
    });

    test('unrelated query does not match', () {
      expect(_matches(sophie, 'Xavier'), isFalse);
    });

    test('blank query does not match', () {
      expect(_matches(sophie, '   '), isFalse);
    });
  });

  group('legacy businessName', () {
    test('a business-only doc is searchable by its business name', () {
      // The documented legacy shape: `name` empty, business under its own
      // field. fromMap promotes it into `name`, so this has always worked.
      final doc = ClientRecord.fromMap('c1', const {
        'name': '',
        'businessName': 'Plomberie Rivard',
      });
      expect(doc.name, 'Plomberie Rivard');
      expect(_matches(doc, 'Rivard'), isTrue);
    });

    test('a doc with BOTH a name and a business name matches either', () {
      // The gap: `name` is non-empty so the fallback never fires, and indexing
      // `name` alone made the business name unfindable.
      final doc = ClientRecord.fromMap('c2', const {
        'name': 'Sophie Tremblay',
        'businessName': 'Plomberie Rivard',
      });
      expect(doc.name, 'Sophie Tremblay');
      expect(_matches(doc, 'Sophie'), isTrue);
      expect(_matches(doc, 'Rivard'), isTrue);
    });

    test('businessName is never written back', () {
      // Read-only legacy field: emitting it would persist it on every save and
      // resurrect a field no UI can edit.
      final doc = ClientRecord.fromMap('c3', const {
        'name': 'Sophie Tremblay',
        'businessName': 'Plomberie Rivard',
      });
      expect(doc.toMap().containsKey('businessName'), isFalse);
    });
  });

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

    test('rawMatches honours the same seam as index/entryMatches', () {
      final data = <String, dynamic>{
        'name': 'Marie Tremblay',
        'phone': '5145628332',
        'mobile': '4385551212',
      };
      expect(
        ClientSearchPolicy.rawMatches(
          data,
          queryText: '',
          queryDigits: '83324385',
        ),
        isFalse,
      );
      expect(
        ClientSearchPolicy.rawMatches(
          data,
          queryText: '',
          queryDigits: '4385551212',
        ),
        isTrue,
      );
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

    test('a number stored with its NANP leading 1 is still exact', () {
      final score = ClientSearchPolicy.relevanceScore(
        displayName: 'marie tremblay',
        personName: 'marie tremblay',
        phoneDigits: const ['15145628332'],
        contactsDigits: const [],
        queryText: '5145628332',
        queryDigits: '5145628332',
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
}
