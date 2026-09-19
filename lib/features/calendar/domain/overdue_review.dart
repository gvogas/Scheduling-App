import 'package:scheduling/core/utils/month_sections.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// Ids per status batch, under Firestore's 500-write batch limit.
const int kOverdueReviewChunkSize = 450;

/// One calendar month of overdue jobs, oldest first.
typedef OverdueMonthGroup = ({DateTime month, List<AppointmentRecord> jobs});

/// The jobs still overdue at [now], oldest first.
List<AppointmentRecord> overdueJobsAt(
  Iterable<AppointmentRecord> records,
  DateTime now,
) =>
    records
        .where(
          (job) =>
              AppointmentStatus.fromRaw(job.displayStatusAt(now)) ==
              AppointmentStatus.overdue,
        )
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

/// Groups an oldest-first list into consecutive calendar months.
List<OverdueMonthGroup> groupOverdueByMonth(
  List<AppointmentRecord> oldestFirst,
) => [
  for (final section in monthSectionsOf(oldestFirst))
    (
      month: section.month,
      jobs: oldestFirst.sublist(section.start, section.start + section.length),
    ),
];

/// [ids] in runs of at most [size].
List<List<String>> chunkIds(
  List<String> ids, {
  int size = kOverdueReviewChunkSize,
}) => [
  for (var i = 0; i < ids.length; i += size)
    ids.sublist(i, i + size > ids.length ? ids.length : i + size),
];
