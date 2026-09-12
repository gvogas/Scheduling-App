import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/layout/text_measure.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';

/// The calendar's fixed header.
class CalendarHeaderBlock extends StatelessWidget {
  const CalendarHeaderBlock({
    required this.monthLabel,
    required this.monthLabelShort,
    required this.yearLabel,
    required this.onPickMonth,
    required this.routeButton,
    super.key,
    this.crewFilterButton,
    this.weekStrip,
  });

  final String monthLabel;

  /// The locale's abbreviated month, used when the full name doesn't fit the
  /// row.
  final String monthLabelShort;
  final String yearLabel;
  final VoidCallback onPickMonth;

  /// The Day-route icon button.
  final Widget routeButton;

  /// The admin's crew-filter button, drawn before [routeButton].
  final Widget? crewFilterButton;

  /// The collapsed week strip, or null while the month grid is expanded.
  final Widget? weekStrip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.scaffoldBackgroundColor;
    final topInset = MediaQuery.paddingOf(context).top;

    // No AppBar means nothing sets the system overlay style for this screen.
    final overlay =
        ThemeData.estimateBrightnessForColor(surface) == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    final title = _TitleColumn(
      monthLabel: monthLabel,
      monthLabelShort: monthLabelShort,
      yearLabel: yearLabel,
      onPickMonth: onPickMonth,
    );
    final controls = _Controls(
      routeButton: routeButton,
      crewFilterButton: crewFilterButton,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: ColoredBox(
        color: surface,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, topInset + 10, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The title and the controls never fit side by side once the
              // Calendar pill's label is scaled up, so they stack instead.
              if (context.isCompact) ...[
                title,
                const SizedBox(height: AppSpacing.sp8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: controls,
                ),
              ] else
                Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: AppSpacing.sp8),
                    controls,
                  ],
                ),
              _WeekStripSlot(strip: weekStrip),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slides the week strip in from above as the month grid collapses, and takes
/// no space at all while there is no strip.
class _WeekStripSlot extends StatelessWidget {
  const _WeekStripSlot({required this.strip});

  final Widget? strip;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.riseInShort,
    switchInCurve: AppMotion.emphasized,
    transitionBuilder: (child, animation) => SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: animation, child: child),
    ),
    child: strip ?? const SizedBox.shrink(),
  );
}

class _TitleColumn extends StatelessWidget {
  const _TitleColumn({
    required this.monthLabel,
    required this.monthLabelShort,
    required this.yearLabel,
    required this.onPickMonth,
  });

  final String monthLabel;
  final String monthLabelShort;
  final VoidCallback onPickMonth;
  final String yearLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.calendar_scheduleLabel, style: theme.monoType.label),
        const SizedBox(height: AppSpacing.sp4),
        _MonthRow(
          monthLabel: monthLabel,
          monthLabelShort: monthLabelShort,
          yearLabel: yearLabel,
          onTap: onPickMonth,
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.routeButton, this.crewFilterButton});

  final Widget routeButton;
  final Widget? crewFilterButton;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (crewFilterButton != null) ...[
        crewFilterButton!,
        const SizedBox(width: 6),
      ],
      routeButton,
      const SizedBox(width: 6),
      // No Calendar pill here — this IS the calendar.
      const AppHeaderPair(showCalendarPill: false),
    ],
  );
}

class _MonthRow extends StatelessWidget {
  const _MonthRow({
    required this.monthLabel,
    required this.monthLabelShort,
    required this.yearLabel,
    required this.onTap,
  });

  final String monthLabel;
  final String monthLabelShort;
  final String yearLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monthStyle = theme.textTheme.displayLarge;
    final yearStyle = theme.textTheme.titleMedium?.copyWith(
      color: theme.palette.textTertiary,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Everything the month has to share the row with: the gap, the year,
        // the gap before the chevron, and the chevron.
        final reserved =
            AppSpacing.sp8 + measureTextWidth(context, yearLabel, yearStyle) + 6 + 18;
        final available = constraints.maxWidth - reserved;
        final label =
            !constraints.hasBoundedWidth ||
                measureTextWidth(context, monthLabel, monthStyle) <= available
            ? monthLabel
            : monthLabelShort;

        return Semantics(
          button: true,
          // Always the full month for a screen reader — it has no width limit.
          label: '$monthLabel $yearLabel, ${context.l10n.calendar_selectDate}',
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.r8),
            child: ConstrainedBox(
              // 40 is the painted row; the header's own padding carries it past
              // the 48px tap floor.
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monthStyle,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sp8),
                  Text(yearLabel, style: yearStyle),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: theme.palette.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
