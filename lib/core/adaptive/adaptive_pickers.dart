import 'package:flutter/material.dart';
import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/adaptive/cupertino_time_picker.dart';

/// Platform-adaptive date picker: Cupertino wheel on iOS/macOS, Material
/// calendar elsewhere.
Future<DateTime?> showAdaptiveDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  if (context.isCupertino) {
    return showCupertinoDatePickerSheet(
      context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
  }
  return showDatePicker(
    context: context,
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
  );
}

/// Platform-adaptive time picker: Cupertino wheel on iOS/macOS, Material
/// picker elsewhere.
Future<TimeOfDay?> showAdaptiveTimePicker(
  BuildContext context, {
  TimeOfDay? initialTime,
  int minuteInterval = 1,
}) async {
  if (context.isCupertino) {
    return await showCupertinoTimePicker(
      context,
      initialTime: initialTime,
      minuteInterval: minuteInterval,
    );
  }
  // Material's picker cannot restrict its minutes, so the interval is honoured
  // on the way OUT instead — the caller asked for a step, not a suggestion.
  final picked = await showTimePicker(
    context: context,
    initialTime: snapToMinuteInterval(
      initialTime ?? TimeOfDay.now(),
      minuteInterval,
    ),
  );
  return picked == null ? null : snapToMinuteInterval(picked, minuteInterval);
}
