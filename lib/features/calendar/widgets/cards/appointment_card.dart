import 'package:flutter/material.dart';

import 'package:scheduling/core/animations/tap_scale.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/day_off_reason.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/cards/non_working_time_row.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// Shared cap for crew bar bands and avatar stack.
const int _kMaxCrewShown = 4;

/// Day-off strip dashed rail geometry. The WIDTH is shared with the holiday
/// row through `kNonWorkingRailWidth`; the inset and gap are this strip's own,
/// since only it positions its rail in a `Stack`.
const double _kRailInset = 9;
const double _kRailGap = 10;

/// Vertical padding inside the day-off strip.
const double _kStripPaddingY = 9;

/// Leading crew bar decoration.
BoxDecoration _crewBarDecoration(ThemeData theme, List<Color> colors) {
  if (colors.isEmpty) return BoxDecoration(color: theme.palette.textFaint);
  if (colors.length == 1) return BoxDecoration(color: colors.first);
  final step = 1 / colors.length;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      // Duplicate colors make hard band edges.
      colors: [
        for (final color in colors) ...[color, color],
      ],
      stops: [
        for (var i = 0; i < colors.length; i++) ...[i * step, (i + 1) * step],
      ],
    ),
  );
}

/// One appointment card reused across appointment surfaces.
class AppointmentCard extends StatelessWidget {
  const AppointmentCard({
    required this.appointment,
    required this.crew,
    super.key,
    this.clientName,
    this.onTap,
    this.selected = false,
    this.footer,
    this.dimWhenCancelled = false,
    this.emphasizeToday = false,
    this.collapseWhenClosed = false,
    this.slice,
    this.showStatusChip = true,
    this.showDate = false,
  });

  /// Minimum collapsed tap target height.
  static const double _kClosedMinHeight = 48;

  final AppointmentRecord appointment;

  /// Assignees in display order.
  final List<AppointmentCrew> crew;

  /// Overrides the record's denormalized client name.
  final String? clientName;

  final VoidCallback? onTap;
  final bool selected;

  /// Rendered below the meta rows.
  final Widget? footer;

  /// Applies cancelled-row styling.
  final bool dimWhenCancelled;

  /// Today's cards use a 3px bar rather than 4px, per the design.
  final bool emphasizeToday;

  /// Applies the agenda's collapsed closed-job treatment.
  final bool collapseWhenClosed;

  /// This card's day within a multi-day run.
  final AppointmentDaySlice? slice;

  /// Hides the status chip where every card shares one status.
  final bool showStatusChip;

  /// Leads the time line with the date, for a list that spans days.
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Time off renders as a strip instead of a job card.
    if (appointment.isTimeOff) {
      return _DayOffStrip(appointment: appointment, crew: crew, onTap: onTap);
    }

    final model = _CardModel.from(context, this);

    final card = TapScale(
      child: DecoratedBox(
        decoration: appCardDecoration(
          theme,
          radius: AppRadius.rCard,
          color: _cardColor(theme, model),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.rCard),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              child: Semantics(
                label: model.semanticsLabel,
                excludeSemantics: true,
                // IntrinsicHeight forbids LayoutBuilder/FittedBox descendants.
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: emphasizeToday ? 3 : 4,
                        decoration: _crewBarDecoration(
                          theme,
                          _barColors(theme),
                        ),
                      ),
                      Expanded(child: _body(theme, model)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return model.isCancelled ? Opacity(opacity: 0.6, child: card) : card;
  }

  /// Crew colors for the leading bar.
  List<Color> _barColors(ThemeData theme) => [
    for (final member in crew.take(_kMaxCrewShown))
      if (member.color case final stored?)
        crewColorOf(theme, stored.toARGB32()),
  ];

  /// The card's fill color.
  Color _cardColor(ThemeData theme, _CardModel model) {
    if (selected) return theme.colorScheme.secondaryContainer;
    if (model.collapsed && model.status.isDone) {
      return theme.statusColors.successContainer;
    }
    return theme.colorScheme.surface;
  }

  /// The card body for full or collapsed layout.
  Widget _body(ThemeData theme, _CardModel model) {
    final titleRow = _TitleRow(
      title: appointment.title,
      status: model.status,
      isTimeOff: model.isTimeOff,
      compact: model.compact,
      isCancelled: model.isCancelled,
      hasPhotos: model.hasPhotos,
      showChip: showStatusChip,
    );

    if (model.collapsed) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kClosedMinHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleRow,
              const SizedBox(height: 5),
              // Its own line: sharing a Row with the client name split the
              // width evenly, so "· Day 3 of 5" was ellipsised on exactly the
              // multi-day rows that need the counter to be distinguishable.
              Text(
                model.timeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.monoType.data.copyWith(
                  color: theme.palette.textTertiary,
                ),
              ),
              if (crew.isNotEmpty || model.metaLine.isNotEmpty) ...[
                const SizedBox(height: 5),
                _CrewRow(
                  crew: crew,
                  label: model.metaLine,
                  compact: model.compact,
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: AppSpacing.cardPaddingY,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleRow,
          const SizedBox(height: 7),
          Text(model.timeLabel, style: theme.monoType.data),
          if (model.metaLine.isNotEmpty) ...[
            const SizedBox(height: 7),
            _CrewRow(crew: crew, label: model.metaLine, compact: model.compact),
          ],
          if (footer != null) ...[
            const SizedBox(height: AppSpacing.sp8),
            footer!,
          ],
        ],
      ),
    );
  }

  /// Mono time line for this card's represented day.
  String _timeLabel(BuildContext context) {
    final l10n = context.l10n;
    final window = slice;
    final base = appointment.isAllDay
        ? l10n.calendar_allDay
        : '${DateUtilsHelper.formatTime(window?.windowStart ?? appointment.startTime)} – '
              '${DateUtilsHelper.formatTime(window?.windowEnd ?? appointment.endTime)}';
    final dated = showDate
        ? '${DateUtilsHelper.formatMonthDay(window?.windowStart ?? appointment.startTime)} · $base'
        : base;
    if (window == null || !window.isMultiDay) return dated;
    final counter = window.isOvernight
        ? l10n.calendar_nightOfCount(window.dayIndex, window.dayCount)
        : l10n.calendar_dayOfCount(window.dayIndex, window.dayCount);
    return '$dated · $counter';
  }

  /// `Theo` for one assignee, `Theo +1` for more, null for none.
  String? _crewLabel(BuildContext context) {
    if (crew.isEmpty) return null;
    final first = _firstName(crew.first.name);
    if (crew.length == 1) return first;
    return context.l10n.calendar_crewPlusOthers(first, crew.length - 1);
  }

  static String _firstName(String name) {
    final trimmed = name.trim();
    final space = trimmed.indexOf(' ');
    return space == -1 ? trimmed : trimmed.substring(0, space);
  }
}

/// A day off rendered in place of a job card.
class _DayOffStrip extends StatelessWidget {
  const _DayOffStrip({
    required this.appointment,
    required this.crew,
    required this.onTap,
  });

  final AppointmentRecord appointment;
  final List<AppointmentCrew> crew;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final displayStatus = AppointmentStatus.fromRaw(appointment.displayStatus);
    final isOver = displayStatus.isTerminal;
    // Name the crew the day off belongs to.
    final crewLabel = _crewLabel(context);
    final name = crewLabel ?? appointment.title.trim();
    final sentence = isOver
        ? l10n.calendar_dayOffWasOff(name)
        : l10n.calendar_dayOffIsOff(name);
    final reason = dayOffReason(
      title: appointment.title,
      hasSubject: crewLabel != null,
      placeholders: personalTitlePlaceholders,
    );
    final lead = crew.isEmpty ? null : crew.first;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        child: Semantics(
          label: [?reason, sentence, l10n.calendar_dayOff].join(', '),
          excludeSemantics: true,
          // Position the rail without forcing intrinsic layout.
          child: Stack(
            children: [
              Container(
                constraints: const BoxConstraints(
                  minHeight: kNonWorkingRowMinHeight,
                ),
                padding: EdgeInsets.only(
                  left: lead == null
                      ? AppSpacing.sp12
                      : _kRailInset + kNonWorkingRailWidth + _kRailGap,
                  right: AppSpacing.sp12,
                  top: _kStripPaddingY,
                  bottom: _kStripPaddingY,
                ),
                decoration: nonWorkingTimeDecoration(theme),
                child: Row(
                  children: [
                    if (lead != null) ...[
                      Opacity(
                        opacity: isOver ? 0.55 : 1,
                        child: AppAvatar(
                          name: lead.name,
                          color: lead.color,
                          size: AvatarSize.xs,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sp8),
                    ],
                    Expanded(
                      child: NonWorkingTimeText(
                        // The reason LEADS when there is one, and the sentence
                        // drops to the caption beneath it.
                        headline: reason ?? sentence,
                        caption: reason == null ? null : sentence,
                        isMuted: isOver,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sp8),
                    // Finished days off reuse the done chip.
                    if (isOver)
                      StatusChip(status: displayStatus)
                    else
                      Text(
                        l10n.calendar_dayOff.toUpperCase(),
                        style: theme.monoType.groupLabel,
                      ),
                  ],
                ),
              ),
              if (lead != null)
                Positioned(
                  left: _kRailInset,
                  top: AppSpacing.sp8,
                  bottom: AppSpacing.sp8,
                  width: kNonWorkingRailWidth,
                  child: _DayOffRail(lead: lead, isOver: isOver),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// `Marc Tremblay` for one assignee, `Marc Tremblay +1` for more.
  String? _crewLabel(BuildContext context) {
    if (crew.isEmpty) return null;
    final first = crew.first.name.trim();
    if (crew.length == 1) return first;
    return context.l10n.calendar_crewPlusOthers(first, crew.length - 1);
  }
}

/// The strip's dashed leading rail — the negative of a job card's solid bar.
///
/// Its `Positioned` stays at the call site: this is painted inside a `Stack`
/// deliberately, so the rail can span the strip's height without forcing
/// intrinsic layout on it.
class _DayOffRail extends StatelessWidget {
  const _DayOffRail({required this.lead, required this.isOver});

  final AppointmentCrew lead;
  final bool isOver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: isOver ? 0.5 : 1,
      child: CustomPaint(
        // Null stored color falls back to the neutral rail.
        painter: _DashedRailPainter(
          lead.color == null
              ? theme.palette.textFaint
              : crewColorOf(theme, lead.color!.toARGB32()),
        ),
      ),
    );
  }
}

/// Dashed leading rail for day-off strips.
class _DashedRailPainter extends CustomPainter {
  const _DashedRailPainter(this.color);

  final Color color;

  static const double _dash = 4;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final radius = Radius.circular(size.width / 2);
    for (var top = 0.0; top < size.height; top += _dash + _gap) {
      final bottom = (top + _dash).clamp(0.0, size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, top, size.width, bottom),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRailPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Derived card presentation model.
class _CardModel {
  const _CardModel({
    required this.status,
    required this.isTimeOff,
    required this.compact,
    required this.collapsed,
    required this.isCancelled,
    required this.hasPhotos,
    required this.timeLabel,
    required this.metaLine,
    required this.semanticsLabel,
  });

  factory _CardModel.from(BuildContext context, AppointmentCard card) {
    final appointment = card.appointment;
    final status = AppointmentStatus.fromRaw(appointment.displayStatus);
    final timeLabel = card._timeLabel(context);
    // Denormalized photo count is indicator-only.
    final hasPhotos = appointment.hasPictures;

    // Personal jobs name themselves in the client slot.
    final client = appointment.isPersonal
        ? context.l10n.calendar_personal
        : (card.clientName ?? appointment.clientName).trim();

    return _CardModel(
      status: status,
      isTimeOff: appointment.isTimeOff,
      compact: context.isCompact,
      collapsed: card.collapseWhenClosed && appointment.isClosed,
      isCancelled: card.dimWhenCancelled && status.isCancelled,
      hasPhotos: hasPhotos,
      timeLabel: timeLabel,
      // Legacy no-client jobs fall back to crew names.
      metaLine: client.isNotEmpty ? client : (card._crewLabel(context) ?? ''),
      semanticsLabel: [
        appointment.title,
        statusLabel(context.l10n, status),
        timeLabel,
        for (final member in card.crew) member.name,
        if (client.isNotEmpty) client,
        // Include the photo cue in the composed semantics label.
        if (hasPhotos) context.l10n.calendar_hasPhotos,
      ].join(', '),
    );
  }

  final AppointmentStatus status;

  /// True when the status chip should read as day off.
  final bool isTimeOff;
  final bool compact;
  final bool collapsed;
  final bool isCancelled;
  final bool hasPhotos;
  final String timeLabel;
  final String metaLine;
  final String semanticsLabel;
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.title,
    required this.status,
    required this.isTimeOff,
    required this.compact,
    required this.isCancelled,
    required this.hasPhotos,
    this.showChip = true,
  });

  final String title;
  final AppointmentStatus status;
  final bool isTimeOff;
  final bool compact;
  final bool isCancelled;
  final bool hasPhotos;
  final bool showChip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep plain Text under IntrinsicHeight.
    final titleText = Text(
      title,
      maxLines: compact ? 3 : 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        decoration: isCancelled ? TextDecoration.lineThrough : null,
        color: isCancelled ? theme.palette.textTertiary : null,
      ),
    );

    // The crew bar encodes identity, not status, so overdue needs its own glyph.
    final warning = status == AppointmentStatus.overdue
        ? Padding(
            padding: const EdgeInsets.only(top: 2, right: AppSpacing.sp4),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 15,
              color: theme.statusColors.warning,
            ),
          )
        : null;

    // Keep the photo cue visible in collapsed rows.
    final photos = hasPhotos
        ? const Padding(
            padding: EdgeInsets.only(top: 2, left: AppSpacing.sp8),
            child: _PhotoGlyph(),
          )
        : null;

    Widget titleContent = titleText;
    if (warning != null || photos != null) {
      titleContent = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ?warning,
          Expanded(child: titleText),
          ?photos,
        ],
      );
    }

    if (!showChip) return titleContent;
    final chip = StatusChip(status: status);
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleContent,
          const SizedBox(height: AppSpacing.sp8),
          chip,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: titleContent),
        const SizedBox(width: AppSpacing.sp8),
        chip,
      ],
    );
  }
}

/// Photo-presence cue for the title line.
class _PhotoGlyph extends StatelessWidget {
  const _PhotoGlyph();

  @override
  Widget build(BuildContext context) => Icon(
    Icons.photo_outlined,
    size: 15,
    color: Theme.of(context).palette.textTertiary,
  );
}

/// Overlapped assignee avatar stack.
class _CrewAvatars extends StatelessWidget {
  const _CrewAvatars({required this.crew});

  final List<AppointmentCrew> crew;

  /// How much of each avatar the next one covers.
  static const double _overlap = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = crew.take(_kMaxCrewShown).toList();
    final diameter = AvatarSize.xs.diameter;
    final step = diameter - _overlap;

    return SizedBox(
      width: diameter + (shown.length - 1) * step,
      height: diameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Paint right-to-left for the overlap stack.
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: i * step,
              child: Container(
                // Separate adjacent crew colors with a hairline.
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
                // AppAvatar resolves the stored crew color.
                child: AppAvatar(
                  name: shown[i].name,
                  color: shown[i].color,
                  size: AvatarSize.xs,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CrewRow extends StatelessWidget {
  const _CrewRow({
    required this.crew,
    required this.label,
    required this.compact,
  });

  final List<AppointmentCrew> crew;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (crew.isNotEmpty) ...[
          _CrewAvatars(crew: crew),
          const SizedBox(width: AppSpacing.sp8),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: compact ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}
