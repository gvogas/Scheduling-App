import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/l10n/l10n.dart';

/// A dated card that opens the job, with its own 48pt checkbox on the right.
class OverdueReviewJobRow extends StatelessWidget {
  const OverdueReviewJobRow({
    required this.job,
    required this.crew,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    super.key,
  });

  final AppointmentRecord job;
  final List<AppointmentCrew> crew;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppointmentCard(
            appointment: job,
            crew: crew,
            selected: selected,
            showStatusChip: false,
            showDate: true,
            onTap: onOpen,
          ),
        ),
        const SizedBox(width: AppSpacing.sp4),
        SizedBox.square(
          dimension: 48,
          child: Checkbox.adaptive(
            key: Key('overdueReviewCheck-${job.id}'),
            value: selected,
            semanticLabel: context.l10n.calendar_overdueReviewSelectJob(
              job.title,
            ),
            onChanged: (_) => onToggle(),
          ),
        ),
      ],
    );
  }
}
