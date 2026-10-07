import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/busy_button_icon.dart';

class DetailsActionBar extends StatelessWidget {
  const DetailsActionBar({
    required this.isDone,
    required this.isCancelled,
    required this.isSaving,
    required this.onMarkDone,
    required this.onCancel,
    super.key,
    this.showCancel = true,
    this.onEdit,
    this.onStart,
    this.onBookAgain,
    this.isInProgress = false,
    this.tourWrap,
  });

  final bool isDone;
  final bool isCancelled;
  final bool isSaving;
  final bool showCancel;
  final VoidCallback onMarkDone;
  final VoidCallback onCancel;

  /// "Start job" — offered on an open job that is not yet under way.
  final VoidCallback? onStart;

  /// The STORED status is already `in_progress`, so there is nothing to start.
  final bool isInProgress;

  /// Edit action for a job that is already done.
  final VoidCallback? onEdit;

  /// "Book again" — opens the add sheet pre-filled from this job.
  final VoidCallback? onBookAgain;

  /// Wraps a button as its tour step; null off-tour, so the bar stays usable
  /// untoured. One parameter, not one per button.
  final Widget Function(TourStepId, Widget)? tourWrap;

  Widget _tour(TourStepId id, Widget child) =>
      tourWrap?.call(id, child) ?? child;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp24),
        if (onStart != null && !isDone && !isCancelled && !isInProgress) ...[
          _tour(TourStepId.jobStart, _startButton(context, compact)),
          const SizedBox(height: AppSpacing.sp8),
        ],
        if (!isDone && !isCancelled)
          _tour(TourStepId.jobMarkDone, _markDoneButton(context, compact)),
        if (isDone) ..._doneSlot(context, compact),
        if (showCancel && !isCancelled && !isDone)
          ..._cancelSlot(context, compact),
        if (onBookAgain != null) ..._bookAgainSlot(context, compact),
      ],
    );
  }

  /// Last in the bar in every state: it is the one action that does not change
  /// THIS job, so it sits below everything that does.
  List<Widget> _bookAgainSlot(BuildContext context, bool compact) => [
    // A cancelled job renders nothing above this.
    if (!isCancelled) const SizedBox(height: AppSpacing.sp8),
    _tour(
      TourStepId.jobBookAgain,
      OutlinedButton(
        onPressed: onBookAgain,
        child: _ActionButtonContent(
          compact: compact,
          icon: const Icon(Icons.event_repeat_outlined, size: 18),
          label: context.l10n.calendar_bookAgain,
        ),
      ),
    ),
  ];

  /// The arrival tap. Same haptic contract as mark-done below: felt on press,
  /// never awaited, so it can neither delay nor be delayed by the write.
  Widget _startButton(BuildContext context, bool compact) => OutlinedButton(
    onPressed: isSaving
        ? null
        : () {
            unawaited(HapticFeedback.mediumImpact());
            onStart!();
          },
    child: _ActionButtonContent(
      compact: compact,
      icon: BusyButtonIcon(
        isBusy: isSaving,
        icon: Icons.play_arrow_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      label: context.l10n.calendar_startJob,
    ),
  );

  /// Offered for the whole life of an open job — there is no "has it started
  /// yet" gate (owner call, 2026-08-17).
  Widget _markDoneButton(BuildContext context, bool compact) {
    // The design's complete action is a filled GREEN button, so it reads as the
    // success it is rather than as the generic secondary.
    final successFill = Theme.of(context).statusColors.success;
    final onSuccessFill = contrastingForegroundFor(successFill);
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
        backgroundColor: successFill,
        foregroundColor: onSuccessFill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.r16),
        ),
      ),
      // The one button a gloved field worker presses while glancing away, and
      // the only confirmation it had was a notice they have to look at.
      onPressed: isSaving
          ? null
          : () {
              unawaited(HapticFeedback.mediumImpact());
              onMarkDone();
            },
      child: _ActionButtonContent(
        compact: compact,
        icon: BusyButtonIcon(
          isBusy: isSaving,
          icon: Icons.check,
          color: onSuccessFill,
        ),
        label: context.l10n.calendar_markAsDone,
      ),
    );
  }

  /// A done job has no mark-done or cancel action left, so this slot is where
  /// its Edit lives — the read view's top chip is hidden for it.
  List<Widget> _doneSlot(BuildContext context, bool compact) {
    final scheme = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: AppSpacing.sp8),
      if (onEdit != null)
        OutlinedButton(
          onPressed: onEdit,
          child: _ActionButtonContent(
            compact: compact,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: context.l10n.common_edit,
          ),
        )
      else
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
            foregroundColor: scheme.secondary,
            side: BorderSide(color: scheme.secondary),
          ),
          onPressed: null,
          child: _ActionButtonContent(
            compact: compact,
            icon: Icon(
              Icons.check_circle_outline,
              size: 18,
              color: scheme.secondary,
            ),
            label: context.l10n.calendar_completed,
          ),
        ),
    ];
  }

  List<Widget> _cancelSlot(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    return [
      // The complete button is always above this on an open job, so the gap is
      // unconditional.
      const SizedBox(height: AppSpacing.sp8),
      OutlinedButton(
        style: destructiveOutlinedButtonStyle(context),
        onPressed: isSaving ? null : onCancel,
        child: _ActionButtonContent(
          compact: compact,
          icon: const Icon(Icons.close, size: 15),
          label: context.l10n.calendar_cancelAppointment,
        ),
      ),
      const SizedBox(height: AppSpacing.sp4),
      Center(
        child: Text(
          context.l10n.calendar_cancelledJobsAreSavedToHistory,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ];
  }
}

class _ActionButtonContent extends StatelessWidget {
  const _ActionButtonContent({
    required this.compact,
    required this.icon,
    required this.label,
  });

  final bool compact;
  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      textAlign: TextAlign.center,
      maxLines: compact ? 3 : 2,
      overflow: TextOverflow.ellipsis,
    );

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: AppSpacing.sp4),
          text,
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        icon,
        const SizedBox(width: AppSpacing.sp8),
        Flexible(child: text),
      ],
    );
  }
}
