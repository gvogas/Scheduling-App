import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';

import '../fixtures/shared/shared_fixture.dart';

void main() {
  final constants = loadSharedFixture('constants.json');

  test('search token limits match the shared fixture', () {
    expect(kSearchTokenQueryLimit, constants['searchTokenQueryLimit']);
    expect(kSearchTokenFieldLimit, constants['searchTokenFieldLimit']);
  });

  test('the multi-day span cap matches the shared fixture', () {
    expect(maxAppointmentSpanDays, constants['maxAppointmentSpanDays']);
  });
}
