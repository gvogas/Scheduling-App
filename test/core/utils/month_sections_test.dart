import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/utils/month_sections.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

AppointmentRecord _appt(DateTime start) => AppointmentRecord(
  id: '${start.microsecondsSinceEpoch}',
  title: 'Job',
  startTime: start,
  endTime: start.add(const Duration(hours: 1)),
  status: 'done',
);

void main() {
  group('monthSectionsOf', () {
    test('opens one section per calendar month, in list order', () {
      final rows = [
        _appt(DateTime(2026, 8, 11, 9)),
        _appt(DateTime(2026, 8, 3, 9)),
        _appt(DateTime(2026, 7, 31, 9)),
      ];

      final sections = monthSectionsOf(rows);

      expect(sections, hasLength(2));
      expect(sections[0], (month: DateTime(2026, 8), start: 0, length: 2));
      expect(sections[1], (month: DateTime(2026, 7), start: 2, length: 1));
    });

    test('separates the same month in different years', () {
      final rows = [
        _appt(DateTime(2026, 8, 1, 9)),
        _appt(DateTime(2025, 8, 1, 9)),
      ];

      expect(monthSectionsOf(rows), hasLength(2));
    });

    test('start indexes address the flat list, not the section', () {
      final rows = [
        _appt(DateTime(2026, 8, 11, 9)),
        _appt(DateTime(2026, 7, 31, 9)),
        _appt(DateTime(2026, 6, 30, 9)),
      ];

      // The tour wraps row 0 and the pager prefetches near the end; both ask
      // about the whole list, so a section index that restarted at 0 would wrap
      // three rows instead of one.
      expect([for (final s in monthSectionsOf(rows)) s.start], [0, 1, 2]);
    });

    test('is empty for no rows', () {
      expect(monthSectionsOf(const []), isEmpty);
    });
  });
}
