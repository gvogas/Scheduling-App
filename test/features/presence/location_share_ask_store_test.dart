import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/presence/data/location_share_ask_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a uid reads as asked once it has been marked', () async {
    final store = LocationShareAskStore();
    expect(await store.hasAsked('uid-a'), isFalse);

    await store.markAsked('uid-a');

    expect(await store.hasAsked('uid-a'), isTrue);
  });

  test('marking one person does not count as asking another on the same '
      'device', () async {
    final store = LocationShareAskStore();

    await store.markAsked('uid-a');

    expect(await store.hasAsked('uid-b'), isFalse);
  });
}
