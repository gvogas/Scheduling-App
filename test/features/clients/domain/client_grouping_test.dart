import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/client_grouping.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';

ClientRecord _person(String id, String first, String last) =>
    ClientRecord(id: id, name: '5145550$id', firstName: first, lastName: last);

ClientRecord _business(String id, String name) =>
    ClientRecord(id: id, name: name, type: ClientType.commercial);

void main() {
  test('an accented initial files under its bare letter', () {
    expect(clientInitialOf(_person('1', 'Étienne', 'Roy')), 'E');
  });

  test('a client with nothing but digits to show files under #', () {
    expect(clientInitialOf(_business('1', '5145551234')), '#');
  });

  test('one group per run of shared initials, in the order given', () {
    final groups = letterGroupsOf([
      _person('1', 'Alice', 'Brown'),
      _person('2', 'Adam', 'Cole'),
      _person('3', 'Bob', 'Carter'),
    ]);

    expect(groups, [
      (heading: 'A', start: 0, length: 2),
      (heading: 'B', start: 2, length: 1),
    ]);
  });

  // The page arrives orderBy('name') from the server, so a repeat of an
  // earlier letter is a second run rather than a reason to re-sort.
  test('a repeated initial opens a second group rather than re-sorting', () {
    final groups = letterGroupsOf([
      _person('1', 'Alice', 'Brown'),
      _person('2', 'Bob', 'Carter'),
      _person('3', 'Anna', 'Dubois'),
    ]);

    expect(groups.map((g) => g.heading), ['A', 'B', 'A']);
  });

  test('an empty list groups to nothing', () {
    expect(letterGroupsOf(const []), isEmpty);
    expect(singleGroupOf(const []), isEmpty);
  });

  test('a single group covers the whole list under its heading', () {
    final groups = singleGroupOf([
      _person('1', 'Alice', 'Brown'),
      _person('2', 'Bob', 'Carter'),
    ], heading: '4450 Prom. Paton');

    expect(groups, [(heading: '4450 Prom. Paton', start: 0, length: 2)]);
  });
}
