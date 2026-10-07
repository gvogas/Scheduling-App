import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/adaptive/adaptive_pickers.dart';
import 'package:scheduling/core/adaptive/cupertino_time_picker.dart';
import 'package:scheduling/features/calendar/domain/appointment_time_step.dart';
import 'package:scheduling/l10n/l10n.dart';

TimeOfDay? _lastResult;

Future<TimeOfDay?> _open(WidgetTester tester, TimeOfDay initial) async {
  _lastResult = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => _lastResult = await showAdaptiveTimePicker(
                context,
                initialTime: initial,
                minuteInterval: appointmentMinuteStep,
              ),
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('pick'));
  await tester.pumpAndSettle();
  return _lastResult;
}

void main() {
  // CupertinoDatePicker ASSERTS that its initial minute is a multiple of the
  // interval, so an arbitrary stored time has to land on the step first.
  test('snaps to the nearest step', () {
    const cases = <(TimeOfDay, TimeOfDay)>[
      (TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 9, minute: 0)),
      (TimeOfDay(hour: 9, minute: 7), TimeOfDay(hour: 9, minute: 0)),
      (TimeOfDay(hour: 9, minute: 8), TimeOfDay(hour: 9, minute: 15)),
      (TimeOfDay(hour: 9, minute: 22), TimeOfDay(hour: 9, minute: 15)),
      (TimeOfDay(hour: 9, minute: 23), TimeOfDay(hour: 9, minute: 30)),
      (TimeOfDay(hour: 9, minute: 53), TimeOfDay(hour: 10, minute: 0)),
    ];
    for (final (input, expected) in cases) {
      expect(
        snapToMinuteInterval(input, appointmentMinuteStep),
        expected,
        reason: '$input',
      );
    }
  });

  test('every snapped minute is one the picker offers', () {
    for (var minute = 0; minute < 60; minute++) {
      final snapped = snapToMinuteInterval(
        TimeOfDay(hour: 13, minute: minute),
        appointmentMinuteStep,
      );
      expect(const {0, 15, 30, 45}.contains(snapped.minute), isTrue);
    }
  });

  // Rounding up from 23:53 would give an hour of 24, which TimeOfDay rejects.
  test('floors rather than leaving the day', () {
    expect(
      snapToMinuteInterval(
        const TimeOfDay(hour: 23, minute: 53),
        appointmentMinuteStep,
      ),
      const TimeOfDay(hour: 23, minute: 45),
    );
  });

  test('an interval of 1 leaves the time alone', () {
    const time = TimeOfDay(hour: 9, minute: 7);
    expect(snapToMinuteInterval(time, 1), time);
  });

  // The wheel is what enforces the step on the only platform that ships, so
  // assert the interval actually reaches it rather than only the snapping.
  testWidgets('the wheel is built with the appointment step', (tester) async {
    await _open(tester, const TimeOfDay(hour: 9, minute: 7));

    final wheel = tester.widget<CupertinoDatePicker>(
      find.byType(CupertinoDatePicker),
    );
    expect(wheel.minuteInterval, appointmentMinuteStep);
    // And it opened on a minute the wheel can actually show — otherwise
    // CupertinoDatePicker asserts rather than rendering.
    expect(wheel.initialDateTime.minute % appointmentMinuteStep, 0);
    expect(tester.takeException(), isNull);
  });
}
