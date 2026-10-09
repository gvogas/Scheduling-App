import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/calendar/widgets/fields/repeat_interval_picker.dart';
import 'package:scheduling/features/calendar/widgets/sections/photo_picker_section.dart';
import 'package:scheduling/features/calendar/widgets/views/details_view_widgets.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';

class DetailsEditChip extends StatelessWidget {
  const DetailsEditChip({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.r8),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp12,
            vertical: AppSpacing.sp4,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            border: Border.all(color: scheme.outlineVariant, width: 1.5),
            borderRadius: BorderRadius.circular(AppRadius.r8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_outlined, size: 13, color: scheme.onSurface),
              const SizedBox(width: AppSpacing.sp4),
              Text(
                context.l10n.common_edit,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DetailsHeader extends StatelessWidget {
  const DetailsHeader({
    required this.appointment,
    required this.status,
    required this.compact,
    super.key,
  });

  final AppointmentRecord appointment;
  final AppointmentStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text(appointment.title, style: theme.textTheme.headlineLarge);
    final chip = StatusChip(status: status);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact) ...[
            title,
            const SizedBox(height: AppSpacing.sp8),
            chip,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: title),
                const SizedBox(width: AppSpacing.sp12),
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sp4),
                  child: chip,
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.sp8),
          // One mono line replaces the old calendar/clock icon rows.
          _buildWhenLine(context, theme),
          if (appointment.repeat != RepeatInterval.none) ...[
            const SizedBox(height: AppSpacing.sp4),
            _buildRepeatRow(context, theme),
          ],
        ],
      ),
    );
  }

  Widget _buildWhenLine(BuildContext context, ThemeData theme) {
    return Text(
      DateUtilsHelper.formatWhenLine(
        appointment.startTime,
        appointment.endTime,
        allDayLabel: appointment.isAllDay ? context.l10n.calendar_allDay : null,
        // The sheet is not day-scoped, so it names the whole run rather
        // than a "Day N of M" counter — otherwise a 5-day job opened from
        // its day 3 card still read as day 1 with no hint it ran on.
        lastDay: lastWorkDayOf(appointment),
      ),
      style: theme.monoType.data,
    );
  }

  Widget _buildRepeatRow(BuildContext context, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.repeat, size: 13, color: theme.palette.textTertiary),
        const SizedBox(width: AppSpacing.sp4),
        Flexible(
          child: Text(
            repeatIntervalLabel(context.l10n, appointment.repeat),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

/// "Started 9:12 AM · Finished 11:40 AM · 2 h 28 min" — the job's time record,
/// one mono line under the header.
class DetailsTimeRecordRow extends StatelessWidget {
  const DetailsTimeRecordRow({
    required this.startedAt,
    required this.completedAt,
    super.key,
  });

  final DateTime? startedAt;
  final DateTime? completedAt;

  /// The segments, joined by the same middot the when-line uses.
  static String label(
    AppLocalizations l10n,
    DateTime? started,
    DateTime? done,
  ) {
    final parts = <String>[
      if (started != null)
        l10n.calendar_timeRecordStarted(DateUtilsHelper.formatTime(started)),
      if (done != null)
        l10n.calendar_timeRecordFinished(DateUtilsHelper.formatTime(done)),
      if (started != null && done != null && done.isAfter(started))
        elapsedLabel(l10n, done.difference(started)),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.sp4,
        right: AppSpacing.sp4,
        top: AppSpacing.sp4,
      ),
      child: Text(
        label(context.l10n, startedAt, completedAt),
        style: theme.monoType.data.copyWith(color: theme.palette.textTertiary),
      ),
    );
  }
}

/// "2 h 28 min" / "45 min".
String elapsedLabel(AppLocalizations l10n, Duration elapsed) {
  final hours = elapsed.inHours;
  final minutes = elapsed.inMinutes % 60;
  return hours > 0
      ? l10n.calendar_elapsedHoursMinutes(hours, minutes)
      : l10n.calendar_elapsedMinutes(minutes);
}

class DetailsMaterialsRow extends StatelessWidget {
  const DetailsMaterialsRow({required this.items, super.key});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DetailsSectionRow(
      label: context.l10n.calendar_materialsNeeded,
      value: '',
      customValue: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: items
            .map(
              (m) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(AppRadius.rFull),
                ),
                child: Text(
                  m,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class DetailsEmployeesView extends ConsumerWidget {
  const DetailsEmployeesView({required this.appointment, super.key});

  final AppointmentRecord appointment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedEmployees = ref.watch(
      eventDetailsControllerProvider(
        EventDetailsKey(appointment),
      ).select((s) => s.selectedEmployees),
    );
    if (selectedEmployees.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp16),
        DetailsSectionRow(
          label: context.l10n.calendar_assignedLabel,
          value: '',
          customValue: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in selectedEmployees)
                DetailsEmployeePill(employee: e),
            ],
          ),
        ),
      ],
    );
  }
}

class DetailsPhotosView extends ConsumerWidget {
  const DetailsPhotosView({
    required this.appointment,
    required this.isCancelled,
    required this.onRetry,
    super.key,
  });

  final AppointmentRecord appointment;
  final bool isCancelled;

  /// Null when the viewer has no action that could retry — a dead Retry that
  /// only cleared the failure record is worse than none.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(appointment),
    );
    final existingImages = ref.watch(provider.select((s) => s.existingImages));
    final newImages = ref.watch(provider.select((s) => s.newImages));
    final loading = ref.watch(provider.select((s) => s.isLoadingPictures));
    final notifier = ref.watch(photoUploadNotifierProvider);
    final appointmentId = appointment.id;
    // The gate must WATCH the queue: a view-mode background upload changes only the pending count (ADR-0010).
    return ListenableBuilder(
      listenable: Listenable.merge([notifier.pending, notifier.failures]),
      builder: (context, _) {
        final pendingCount = appointmentId == null
            ? 0
            : notifier.pending.value[appointmentId] ?? 0;
        final failure = appointmentId == null
            ? null
            : notifier.failureFor(appointmentId);
        final failedCount = failure?.failedCount ?? 0;
        final hasPhotos =
            existingImages.isNotEmpty ||
            newImages.isNotEmpty ||
            failedCount > 0 ||
            pendingCount > 0 ||
            loading;
        if (!hasPhotos) return const SizedBox.shrink();
        return _buildSection(
          context,
          notifier: notifier,
          appointmentId: appointmentId,
          existingImages: existingImages,
          newImages: newImages,
          pendingCount: pendingCount,
          failedCount: failedCount,
          failure: failure,
        );
      },
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required PhotoUploadNotifier notifier,
    required String? appointmentId,
    required List<AppointmentImage> existingImages,
    required List<File> newImages,
    required int pendingCount,
    required int failedCount,
    required PhotoUploadFailure? failure,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp16),
        DetailsSectionRow(
          label: context.l10n.calendar_photosLabel,
          value: '',
          customValue: PhotoPickerSection(
            existingImages: existingImages,
            newImages: newImages,
            isEditing: false,
            onPickImages: () {},
            onRemoveExisting: (_) {},
            onRemoveNew: (_) {},
            failedCount: failedCount,
            pendingCount: pendingCount,
            tooLargeFileNames: failure?.tooLargeFileNames ?? const [],
            onRetry: failedCount > 0 && !isCancelled && onRetry != null
                ? () {
                    if (appointmentId != null) {
                      notifier.clearFailure(appointmentId);
                    }
                    onRetry!();
                  }
                : null,
          ),
        ),
      ],
    );
  }
}
