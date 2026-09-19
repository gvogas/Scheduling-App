import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/presence/data/location_share_ask_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a uid reads as asked on the build it was marked on', () async {
    final store = LocationShareAskStore();
    expect(await store.hasAsked('uid-a', build: '1.62.0+91'), isFalse);

    await store.markAsked('uid-a', build: '1.62.0+91');

    expect(await store.hasAsked('uid-a', build: '1.62.0+91'), isTrue);
  });

  test('an app update makes the page due again', () async {
    final store = LocationShareAskStore();

    await store.markAsked('uid-a', build: '1.62.0+91');

    expect(await store.hasAsked('uid-a', build: '1.62.0+92'), isFalse);
  });

  test('marking one person does not count as asking another on the same '
      'device', () async {
    final store = LocationShareAskStore();

    await store.markAsked('uid-a', build: '1.62.0+91');

    expect(await store.hasAsked('uid-b', build: '1.62.0+91'), isFalse);
  });
}
