import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/data/firebase_clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// The six-tier relevance ladder `matchClientDocs` sorts by.
///
/// One test covered tiers 1 and 3. Tier 0 (exact), tier 2 (phone prefix) and
/// tier 4 (phone/contacts substring) were untested, as was the 25-result
/// truncation — and since `clients/{id}.name` **IS the bare phone number** for
/// a person, the phone tiers are the ones that matter most on real data. A
/// mis-rank there does not error: it silently pushes the right client past
/// position 25 and out of the dropdown entirely.
void main() {
  RawClientDoc doc(
    String id, {
    String? name,
    String firstName = '',
    String lastName = '',
    String phone = '',
    String mobile = '',
    List<Map<String, dynamic>> contacts = const [],
  }) => (
    id: id,
    data: <String, dynamic>{
      'name': name ?? id,
      'firstName': firstName,
      'lastName': lastName,
      'phone': phone,
      'mobile': mobile,
      'contacts': contacts,
    },
  );

  List<String> rank(List<RawClientDoc> docs, String query) => matchClientDocs(
    ClientSearchScan(docs: docs, query: query),
  ).map((c) => c.id).toList();

  test('tier 0: an exact name match outranks a prefix match', () {
    final order = rank([
      doc('prefix', name: 'Tremblay Plumbing'),
      doc('exact', name: 'Tremblay'),
    ], 'Tremblay');

    expect(order.first, 'exact');
  });

  test('tier 0: an exact PHONE match outranks a name prefix', () {
    // A person's `name` IS their bare number, so an admin typing a full phone
    // number expects that person first, not the business whose name starts
    // with the same digits.
    final order = rank([
      doc('business', name: '5145554321 Plumbing'),
      doc('person', name: '5145554321', phone: '(514) 555-4321'),
    ], '5145554321');

    expect(order.first, 'person');
  });

  test('tier 2: a phone PREFIX outranks a name substring', () {
    // Typing an area code should surface the numbers that START with it
    // before a client whose name merely contains those digits somewhere.
    final order = rank([
      doc('substring', name: 'Unit 514555 Storage'),
      doc('prefixed', name: 'Alpha', phone: '(514) 555-9999'),
    ], '514555');

    expect(order.first, 'prefixed');
  });

  test(
    'tier 4: a phone SUBSTRING still matches, ranked last of the matches',
    () {
      // The final phone rung — digits in the middle of a number. It must match
      // (an admin often knows only the last four), but it must not outrank a
      // name hit.
      final order = rank([
        doc('midphone', name: 'Zeta', phone: '(514) 555-4321'),
        doc('nameHit', name: 'A 5554 Company'),
      ], '5554');

      expect(order, ['nameHit', 'midphone']);
    },
  );

  test("tier 4: a CONTACT's phone matches when the client's own does not", () {
    // The site contact's number is the one on the work order more often than
    // the account holder's.
    final order = rank([
      doc(
        'viaContact',
        name: 'Beta Corp',
        contacts: const [
          {'name': 'Site', 'phone': '(438) 870-3782', 'email': ''},
        ],
      ),
    ], '8703782');

    expect(order, ['viaContact']);
  });

  test('a non-matching client is excluded entirely', () {
    expect(rank([doc('nope', name: 'Unrelated')], 'Tremblay'), isEmpty);
  });

  test('the full ladder ranks exact < prefix < phone-prefix < substring', () {
    // All four rungs in one query, so a reordering of the branches shows up
    // as a reordering here rather than as a silently worse dropdown.
    final order = rank([
      doc('t3_substring', name: 'The 5145 Group'),
      doc('t2_phonePrefix', name: 'Zeta', phone: '5145550000'),
      doc('t1_prefix', name: '5145 Holdings'),
      doc('t0_exact', name: '5145'),
    ], '5145');

    expect(order, ['t0_exact', 't1_prefix', 't2_phonePrefix', 't3_substring']);
  });

  test('equal-scoring clients are ordered by display name', () {
    final order = rank([
      doc('c', name: 'Tremblay Charlie'),
      doc('a', name: 'Tremblay Alpha'),
      doc('b', name: 'Tremblay Bravo'),
    ], 'Tremblay');

    expect(order, ['a', 'b', 'c']);
  });

  test('the result list is truncated to the display limit', () {
    // The window is up to 5000 documents; handing all the matches to a
    // dropdown that shows a couple of screens' worth is what the limit is for.
    final many = [
      for (var i = 0; i < ClientSearchPolicy.resultDisplayLimit + 10; i++)
        doc('c$i', name: 'Tremblay ${i.toString().padLeft(3, '0')}'),
    ];

    expect(
      rank(many, 'Tremblay'),
      hasLength(ClientSearchPolicy.resultDisplayLimit),
    );
  });

  test('truncation keeps the BEST matches, not the first scanned', () {
    // The failure that hides a correct match: truncating before sorting drops
    // the exact hit when it happens to sit late in the name-ordered window.
    final docs = [
      for (var i = 0; i < ClientSearchPolicy.resultDisplayLimit + 5; i++)
        doc(
          'filler$i',
          name: 'Tremblay Filler ${i.toString().padLeft(3, '0')}',
        ),
      doc('exact', name: 'Tremblay'),
    ];

    expect(rank(docs, 'Tremblay').first, 'exact');
  });

  group('scoreRecord', () {
    const exact = ClientRecord(id: 'a', name: 'Zed Ltd', phone: '5145628332');
    const prefix = ClientRecord(id: 'b', name: 'Abe Inc', phone: '5145628901');
    const contains = ClientRecord(id: 'c', name: 'Bee Co', phone: '4385145628');

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
        ..sort(
          (a, b) => score(a, '5145628332').compareTo(score(b, '5145628332')),
        );
      expect(sorted.first.id, 'a');
    });
  });
}
