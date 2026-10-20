import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';

void main() {
  final afternoon = DateTime(2026, 10, 20, 14, 30);

  setUpAll(() async {
    await initializeDateFormatting('en_CA');
  });

  setUp(() => Intl.defaultLocale = 'en_CA');

  tearDown(() {
    DateUtilsHelper.use24Hour = false;
    Intl.defaultLocale = null;
  });

  test('formatTime follows the 12-hour clock by default', () {
    expect(DateUtilsHelper.formatTime(afternoon), contains('2:30'));
  });

  test('formatTime renders 14:30 under the 24-hour setting', () {
    DateUtilsHelper.use24Hour = true;
    expect(DateUtilsHelper.formatTime(afternoon), '14:30');
  });

  test('the cache is keyed on the flag, so toggling it switches format', () {
    DateUtilsHelper.use24Hour = true;
    final h24 = DateUtilsHelper.formatTime(afternoon);
    DateUtilsHelper.use24Hour = false;
    expect(DateUtilsHelper.formatTime(afternoon), isNot(h24));
  });
}
