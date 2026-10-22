import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/application/field_notes_provider.dart';
import 'package:scheduling/features/calendar/data/appointment_field_notes_store.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// The crew's notes on a job, read-only, shown to ANYONE who may read the job
/// — which is the admin and the assignees, exactly the set the rules admit.
///
/// The dispatcher's brief lives in the appointment's own `notes` and is
/// rendered by the client panel above; this is the other half of that
/// distinction, and the reason the two fields are separate.
class DetailsFieldNotesView extends ConsumerWidget {
  const DetailsFieldNotesView({required this.appointment, super.key});

  final AppointmentRecord appointment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Resolved here, never in the listener: `ref` dies with this consumer.
    final logger = ref.read(loggerProvider);
    // The provider answers `const []` for an empty id.
    final key = appointment.id ?? '';
    ref.listen(appointmentFieldNotesProvider(key), (previous, next) {
      if (!isFirstAsyncError(previous, next)) return;
      logger.warn(
        'APPT-FIELDNOTE crew notes read failed',
        next.error,
        next.stackTrace,
      );
    });
    final thread = ref.watch(appointmentFieldNotesProvider(key));
    final stored = thread.value?.notes ?? const <FieldNote>[];
    final truncated = thread.value?.truncated ?? false;
    final failed = thread.hasError;

    final legacy = appointment.fieldNotes.trim();
    final notes = [if (legacy.isNotEmpty) FieldNote.legacy(legacy), ...stored];
    // Empty omitted, but a failed read must not read as "no notes".
    if (notes.isEmpty && !failed) return const SizedBox.shrink();

    // The rules pin `authorId`, not `authorName`, so the stored name is only a
    // fallback for an id the roster cannot resolve (removed staff, or a reader
    // who may not list users).
    final nameMap = ref.watch(employeeNameMapProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp16),
        MonoSectionLabel(context.l10n.calendar_crewNotesLabel),
        const SizedBox(height: AppSpacing.sp8),
        for (final note in notes) ...[
          _Note(
            note: note,
            authorName: nameMap[note.authorId] ?? note.authorName,
          ),
          const SizedBox(height: AppSpacing.sp12),
        ],
        if (truncated)
          WarningNote(
            message: context.l10n.calendar_crewNotesTruncated(
              AppointmentFieldNotesStore.scanLimit,
            ),
          ),
        if (failed) WarningNote(message: context.l10n.calendar_crewNotesUnread),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.note, required this.authorName});

  final FieldNote note;

  /// Resolved from `note.authorId` where possible — never rendered from the
  /// unvalidated stored name when the roster can answer.
  final String authorName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final createdAt = note.createdAt;
    final stamp = createdAt == null
        ? ''
        : '${DateUtilsHelper.formatMonthDay(createdAt)} '
              '${DateUtilsHelper.formatTime(createdAt)}';
    final hasAuthor = authorName.trim().isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasAuthor) ...[
          AppAvatar(name: authorName, size: AvatarSize.sm),
          const SizedBox(width: AppSpacing.sp8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasAuthor)
                Text(
                  l10n.calendar_noteBy(authorName, stamp),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Text(note.text, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
