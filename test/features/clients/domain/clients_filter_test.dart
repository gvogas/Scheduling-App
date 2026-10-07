import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';

void main() {
  test('type and archived are distinct states', () {
    const archived = ClientsFilterArchived();
    const typed = ClientsFilterType(ClientType.commercial);

    expect(archived, isNot(equals(typed)));
    expect(const ClientsFilterAll(), isNot(equals(archived)));
    expect(const ClientsFilterAll(), isNot(equals(typed)));
  });

  test('two filters of the same type compare equal', () {
    expect(
      const ClientsFilterType(ClientType.commercial),
      equals(const ClientsFilterType(ClientType.commercial)),
    );
    expect(
      const ClientsFilterType(ClientType.commercial),
      isNot(equals(const ClientsFilterType(ClientType.residential))),
    );
  });
}
