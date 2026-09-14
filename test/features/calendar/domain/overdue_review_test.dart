import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/overdue_review.dart';

AppointmentRecord _job(
  String id,
  DateTime start, {
  String status = 'pending',
  bool isPersonal = false,
  bool isDayOff = false,
}) => AppointmentRecord(
  id: id,
  title: id,
  startTime: start,
  endTime: start.add(const Duration(hours: 2)),
  status: status,
  isPersonal: isPersonal,
  isDayOff: isDayOff,
);

void main() {
  final now = DateTime(2026, 9, 30, 18);

  group('overdueJobsAt', () {
    test('keeps every open job that has ended, however old, oldest first', () {
      final jobs = overdueJobsAt([
        _job('recent', DateTime(2026, 9, 30, 9)),
        _job('ancient', DateTime(2025, 1, 4, 9), status: 'in_progress'),
      ], now);
      expect(jobs.map((j) => j.id), ['ancient', 'recent']);
    });

    test('drops closed, personal, time off and not-yet-ended jobs', () {
      final jobs = overdueJobsAt([
        _job('done', DateTime(2026, 9, 2), status: 'done'),
        _job('cancelled', DateTime(2026, 9, 2), status: 'cancelled'),
        _job('personal', DateTime(2026, 9, 2), isPersonal: true),
        _job('dayOff', DateTime(2026, 9, 2), isPersonal: true, isDayOff: true),
        _job('later', DateTime(2026, 9, 30, 17)),
      ], now);
      expect(jobs, isEmpty);
    });
  });

  group('groupOverdueByMonth', () {
    test('runs oldest month first across a year boundary', () {
      final groups = groupOverdueByMonth([
        _job('dec', DateTime(2025, 12, 30, 9)),
        _job('jan2', DateTime(2026, 1, 2, 9)),
        _job('jan20', DateTime(2026, 1, 20, 9)),
      ]);
      expect(groups.map((g) => g.month), [DateTime(2025, 12), DateTime(2026)]);
      expect(groups.last.jobs.map((j) => j.id), ['jan2', 'jan20']);
    });

    test('an empty list has no groups', () {
      expect(groupOverdueByMonth(const []), isEmpty);
    });
  });

  group('chunkIds', () {
    test('splits at 450 so a batch stays under the 500-write limit', () {
      final ids = [for (var i = 0; i < 1000; i++) 'id$i'];
      expect(chunkIds(ids).map((c) => c.length), [450, 450, 100]);
      expect(kOverdueReviewChunkSize, 450);
    });

    test('an exact multiple leaves no empty tail, and none gives none', () {
      final ids = [for (var i = 0; i < 450; i++) 'id$i'];
      expect(chunkIds(ids).map((c) => c.length), [450]);
      expect(chunkIds(const []), isEmpty);
    });
  });
}
