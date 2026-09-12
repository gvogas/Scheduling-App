import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// [time] moved to the nearest multiple of [interval] minutes.
///
/// Nearest, not floor, so 10:08 opens the wheel on 10:15 — except where
/// rounding up would leave the day (23:53 with a 15-minute step), which floors
/// instead rather than producing an hour of 24.
TimeOfDay snapToMinuteInterval(TimeOfDay time, int interval) {
  if (interval <= 1) return time;
  final total = time.hour * 60 + time.minute;
  var snapped = ((total + interval ~/ 2) ~/ interval) * interval;
  if (snapped >= Duration.minutesPerDay) {
    snapped = (total ~/ interval) * interval;
  }
  return TimeOfDay(hour: snapped ~/ 60, minute: snapped % 60);
}

Future<TimeOfDay?> showCupertinoTimePicker(
  BuildContext context, {
  TimeOfDay? initialTime,
  int minuteInterval = 1,
}) {
  final now = DateTime.now();
  // CupertinoDatePicker ASSERTS that the initial minute is a multiple of the
  // interval, so a caller's arbitrary time has to be snapped before it opens.
  final init = snapToMinuteInterval(
    initialTime ?? TimeOfDay.now(),
    minuteInterval,
  );
  var tempPicked = DateTime(
    now.year,
    now.month,
    now.day,
    init.hour,
    init.minute,
  );

  return showPickerSheet<TimeOfDay>(
    context,
    onDone: () => TimeOfDay(hour: tempPicked.hour, minute: tempPicked.minute),
    bodyBuilder: (ctx) => CupertinoDatePicker(
      mode: CupertinoDatePickerMode.time,
      minuteInterval: minuteInterval,
      initialDateTime: tempPicked,
      use24hFormat: MediaQuery.alwaysUse24HourFormatOf(ctx),
      onDateTimeChanged: (dateTime) {
        tempPicked = dateTime;
      },
    ),
  );
}

/// Cupertino date wheel in the same bottom-sheet chrome as the time picker.
Future<DateTime?> showCupertinoDatePickerSheet(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  var tempPicked = DateTime(
    initialDate.year,
    initialDate.month,
    initialDate.day,
  );
  if (tempPicked.isBefore(firstDate)) tempPicked = firstDate;
  if (tempPicked.isAfter(lastDate)) tempPicked = lastDate;
  final initial = tempPicked;

  return showPickerSheet<DateTime>(
    context,
    onDone: () => tempPicked,
    bodyBuilder: (ctx) => CupertinoDatePicker(
      mode: CupertinoDatePickerMode.date,
      initialDateTime: initial,
      minimumDate: firstDate,
      maximumDate: lastDate,
      onDateTimeChanged: (dateTime) {
        tempPicked = dateTime;
      },
    ),
  );
}

/// Shared bottom-sheet chrome for the pickers: a Cancel/Done header over a
/// body. Used by the Cupertino wheels and by the quarter-hour step picker.
Future<T?> showPickerSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext) bodyBuilder,
  required T Function() onDone,
  double height = 300,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    sheetAnimationStyle: AppMotion.sheetStyle,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.r20)),
    ),
    builder: (ctx) {
      return SizedBox(
        height: height + MediaQuery.viewPaddingOf(ctx).bottom,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sp16,
                  vertical: AppSpacing.sp8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: Text(
                        ctx.l10n.common_cancel,
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: Text(
                        ctx.l10n.common_done,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, onDone()),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: bodyBuilder(ctx)),
            ],
          ),
        ),
      );
    },
  );
}
