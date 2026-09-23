import 'dart:developer';

import 'package:flutter/foundation.dart';

/// Fixed labels prevent customer data, paths or credentials entering traces.
enum PerformanceOperation {
  dartToFirstFrame,
  clientsPage,
  calendarRange,
  photoUpload,
}

/// Opt-in, local DevTools traces. Compiled out of normal release builds.
abstract final class PerformanceTrace {
  static const enabled = kProfileMode && bool.fromEnvironment('PROFILE_APP');

  static TimelineTask? start(PerformanceOperation operation) =>
      enabled ? (TimelineTask()..start(operation.name)) : null;

  static Future<T> measure<T>(
    PerformanceOperation operation,
    Future<T> Function() work,
  ) async {
    final task = start(operation);
    try {
      return await work();
    } finally {
      task?.finish();
    }
  }
}
