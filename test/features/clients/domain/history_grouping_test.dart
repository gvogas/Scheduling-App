import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/domain/history_grouping.dart';

AppointmentRecord _appt(DateTime start, {String status = 'done'}) =>
    AppointmentRecord(
      id: '${start.microsecondsSinceEpoch}-$status',
      title: 'Job',
      startTime: start,
      endTime: start.add(const Duration(hours: 1)),
      status: status,
    );

void main() {
  group('startsDay', () {
    test('is true on the first row and on each change of day', () {
      final rows = [
        _appt(DateTime(2026, 8, 11, 9)),
        _appt(DateTime(2026, 8, 11, 14)),
        _appt(DateTime(2026, 8, 10, 9)),
      ];

      expect(startsDay(rows, 0), isTrue);
      // Same day, later job — the rail stays empty so the date is not repeated
      // beside every row of a busy day.
      expect(startsDay(rows, 1), isFalse);
      expect(startsDay(rows, 2), isTrue);
    });
  });

  group('tallyOf', () {
    test('counts cancelled as a subset of the total', () {
      final rows = [
        _appt(DateTime(2026, 8, 11, 9)),
        _appt(DateTime(2026, 8, 10, 9), status: 'cancelled'),
        _appt(DateTime(2026, 8, 9, 9), status: 'completed'),
      ];

      expect(tallyOf(rows), (total: 3, cancelled: 1));
    });

    test('counts nothing for an empty list', () {
      expect(tallyOf(const []), (total: 0, cancelled: 0));
    });
  });

  group('HistoryStatusFilter', () {
    test('complete matches both spellings of done and never cancelled', () {
      expect(
        HistoryStatusFilter.complete.matches(_appt(DateTime(2026, 8, 11))),
        isTrue,
      );
      // The legacy `completed` alias still exists on old docs; missing one
      // would hide it from the filter with no error anywhere.
      expect(
        HistoryStatusFilter.complete.matches(
          _appt(DateTime(2026, 8, 11), status: 'completed'),
        ),
        isTrue,
      );
      expect(
        HistoryStatusFilter.complete.matches(
          _appt(DateTime(2026, 8, 11), status: 'cancelled'),
        ),
        isFalse,
      );
    });

    test('cancelled matches only cancelled', () {
      expect(
        HistoryStatusFilter.cancelled.matches(
          _appt(DateTime(2026, 8, 11), status: 'cancelled'),
        ),
        isTrue,
      );
      expect(
        HistoryStatusFilter.cancelled.matches(_appt(DateTime(2026, 8, 11))),
        isFalse,
      );
    });
  });
}
