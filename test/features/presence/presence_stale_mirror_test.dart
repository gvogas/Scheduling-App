import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';

/// `presenceStaleAfter` and `PRESENCE_STALE_MINUTES` are a hand-mirrored pair,
/// and they were the only documented mirror in this repo with no test on
/// either side — every other one (`day_slice_utils`, the span bound, the status
/// values, the self-service field set) is pinned.
///
/// Drift fails in the worst direction, silently: the admin live map decides
/// whether to label a fix "fresh" from the Dart value, while `decideOrigin`
/// decides whether to USE that same fix from the JS value. If the Dart window
/// is the wider of the two, the map tells an admin a tech's position is
/// current while the travel sweep has already discarded it as stale and fallen
/// back to the job-address chain. Nothing errors; the pin is the only signal.
///
/// Dart and JS cannot share a constant, so this reads the JS back as text —
/// the same mechanism `appointment_span_rules_test.dart` uses for CEL.
void main() {
  test('presenceStaleAfter mirrors PRESENCE_STALE_MINUTES', () {
    final source = File('functions/travel_policy.js').readAsStringSync();
    final match = RegExp(
      r'const PRESENCE_STALE_MINUTES\s*=\s*(\d+)\s*;',
    ).firstMatch(source);

    expect(
      match,
      isNotNull,
      reason:
          'PRESENCE_STALE_MINUTES was renamed or removed in '
          'functions/travel_policy.js — update this mirror test with it',
    );
    expect(int.parse(match!.group(1)!), presenceStaleAfter.inMinutes);
  });
}
