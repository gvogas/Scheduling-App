import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/utils/current_day_provider.dart';

/// Walks the states in the order the OS reports them.
void _lifecycle(List<AppLifecycleState> states) =>
    states.forEach(WidgetsBinding.instance.handleAppLifecycleStateChanged);

const _background = [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

const _foreground = [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

void main() {
  late DateTime now;

  // Disposed in the body: teardown runs after the pending-timer check.
  ProviderContainer containerAt(DateTime start) {
    now = start;
    return ProviderContainer(
      overrides: [currentDayClockProvider.overrideWithValue(() => now)],
    );
  }

  testWidgets('resuming on a later day moves today', (tester) async {
    final container = containerAt(DateTime(2026, 10, 14, 23, 30));
    expect(container.read(currentDayProvider), DateTime(2026, 10, 14));

    _lifecycle(_background);
    now = DateTime(2026, 10, 15, 7);
    _lifecycle(_foreground);

    expect(container.read(currentDayProvider), DateTime(2026, 10, 15));
    container.dispose();
  });

  testWidgets('resuming on the same day keeps today', (tester) async {
    final container = containerAt(DateTime(2026, 10, 14, 23, 30));
    final before = container.read(currentDayProvider);

    _lifecycle(_background);
    now = DateTime(2026, 10, 14, 23, 50);
    _lifecycle(_foreground);

    expect(identical(container.read(currentDayProvider), before), isTrue);
    container.dispose();
  });
}
