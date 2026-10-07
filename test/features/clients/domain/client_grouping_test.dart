import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/client_grouping.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';

ClientRecord _person(String id, String first, String last) =>
    ClientRecord(id: id, name: '5145550$id', firstName: first, lastName: last);

void main() {
  test('an empty list groups to nothing', () {
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
