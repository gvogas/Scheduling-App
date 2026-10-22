import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';

void main() {
  group('ClientType.fromRaw', () {
    test('maps each stored value to its enum member', () {
      expect(ClientType.fromRaw('residential'), ClientType.residential);
      expect(ClientType.fromRaw('commercial'), ClientType.commercial);
      expect(ClientType.fromRaw('building'), ClientType.building);
    });

    test('maps empty, null and unknown values to unset', () {
      expect(ClientType.fromRaw(''), ClientType.unset);
      expect(ClientType.fromRaw(null), ClientType.unset);
      expect(ClientType.fromRaw('  '), ClientType.unset);
      expect(ClientType.fromRaw('industrial'), ClientType.unset);
    });

    test('round-trips through raw', () {
      for (final type in ClientType.values) {
        expect(ClientType.fromRaw(type.raw), type);
      }
    });

    test('unset stores as an empty string', () {
      expect(ClientType.unset.raw, '');
    });
  });
}
