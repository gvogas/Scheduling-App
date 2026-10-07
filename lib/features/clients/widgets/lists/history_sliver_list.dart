import 'package:flutter/material.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/month_sections.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/clients/domain/history_grouping.dart';
import 'package:scheduling/features/clients/widgets/lists/history_date_rail.dart';
import 'package:scheduling/features/clients/widgets/sections/history_month_bar.dart';

/// The History rows themselves — month-barred, or flat in search.
///
/// Split out of `AppointmentHistoryView`, whose State had grown to hold four
/// separate concerns once P7 phase D moved `PagedListView`'s job into it. This
/// is the rendering one; the pagination driving, the search indexing and the
/// error/empty states stay with the State. `AgendaSliverList` is the precedent.
///
/// Search spans every appointment rather than the month in view, so its hits
/// are not a contiguous run of days and month bars over scattered results would
/// be noise. In that mode the list renders flat and the rail picks up the month
/// instead — see [HistoryDateRail].
class HistorySliverList extends StatefulWidget {
  const HistorySliverList({
    required this.rows,
    required this.colorMap,
    required this.currentYear,
    required this.inSearch,
    super.key,
    this.isAdmin = false,
    this.footer,
    this.onRowBuilt,
    this.firstRowTourWrap,
  });

  final List<AppointmentRecord> rows;
  final Map<String, Color> colorMap;

  /// Read from `currentDayProvider` by the caller, never `DateTime.now()`: the
  /// rail speaks the year on an older search hit, so "this year" has to survive
  /// an app left open across New Year.
  final int currentYear;

  final bool inSearch;

  /// Passed straight to `showEventDetails` as `showActions`. Defaults CLOSED,
  /// like every other appointment surface.
  final bool isAdmin;

  /// The paged list's spinner or retry row. Null in the filtered/search modes,
  /// which are not paginated.
  final Widget? footer;

  /// Fired with the GLOBAL row index as each row builds — the pager's prefetch
  /// trigger. Null when the list is not driving pagination.
  final void Function(int index)? onRowBuilt;

  /// Wraps the FIRST row only, as that row's feature-tour step.
  final Widget Function(Widget child)? firstRowTourWrap;

  @override
  State<HistorySliverList> createState() => _HistorySliverListState();
}

class _HistorySliverListState extends State<HistorySliverList> {
  /// `monthSectionsOf` is O(N) and N grows with scroll depth (25 a page,
  /// unbounded pages), while `build` re-runs on a page load, a filter
  /// `setState`, and every `employeeColorMapProvider` / `currentDayProvider`
  /// emission. Memoized on the identity of the rows list — the same discipline
  /// `_filterOptionsPages` and the search index use in the host view.
  List<AppointmentRecord>? _sectionedRows;
  List<MonthSection> _sections = const [];

  List<MonthSection> _sectionsFor(List<AppointmentRecord> rows) {
    if (!identical(rows, _sectionedRows)) {
      _sectionedRows = rows;
      _sections = monthSectionsOf(rows);
    }
    return _sections;
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final inSearch = widget.inSearch;
    // Resolved once here rather than per row: `DateFormat` construction parses
    // a skeleton, and this used to sit one frame away from an item builder.
    final monthFormat = monthYearFormatFor(
      Localizations.localeOf(context).toString(),
    );
    final extent = HistoryMonthBar.extentFor(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp12),
      child: CustomScrollView(
        slivers: [
          if (inSearch)
            SliverList.builder(itemCount: rows.length, itemBuilder: _item)
          else
            for (final section in _sectionsFor(rows))
              // The group is what makes the bar STICKY rather than STACKING: a
              // pinned header is bounded by its group's scroll extent, so July's
              // bar pushes August's out on the way past instead of parking a
              // second bar under it. A year of history would otherwise pile
              // twelve bars across the top of the screen.
              SliverMainAxisGroup(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: HistoryMonthBar(
                      label: monthFormat.format(section.month),
                      extent: extent,
                    ),
                  ),
                  SliverList.builder(
                    itemCount: section.length,
                    itemBuilder: (context, index) =>
                        _item(context, section.start + index),
                  ),
                ],
              ),
          // The paged list's spinner or retry row, and — with or without one —
          // the gap that keeps the last card off the bottom edge.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sp12),
              child: widget.footer ?? const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  /// Every row goes through here, so the first-row tour wrap and the pager's
  /// prefetch both key off ONE global index rather than a per-section one.
  Widget _item(BuildContext context, int index) {
    widget.onRowBuilt?.call(index);
    final row = _row(context, index);
    final wrap = widget.firstRowTourWrap;
    return index == 0 && wrap != null ? wrap(row) : row;
  }

  Widget _row(BuildContext context, int index) {
    final rows = widget.rows;
    final app = rows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sp8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Drops the rail's first line onto the card's title line rather
            // than its top border.
            padding: const EdgeInsets.only(top: AppSpacing.sp16),
            child: HistoryDateRail(
              day: DateUtils.dateOnly(app.startTime),
              showDate: startsDay(rows, index),
              inSearch: widget.inSearch,
              currentYear: widget.currentYear,
            ),
          ),
          Expanded(
            child: AppointmentCard(
              appointment: app,
              // No live name map here — crewFor falls back to the record's
              // denormalized employeeNames.
              crew: crewFor(app, colorMap: widget.colorMap),
              // Dims a cancelled visit to 0.6 and strikes its title through.
              // History keeps the plain full-height card otherwise: the
              // agenda's collapsed green treatment exists to sink closed work
              // out of the way of what's left today, and here everything is
              // closed.
              dimWhenCancelled: true,
              // Carries the caller's role rather than a hardcoded false: an
              // admin needs to reach a finished job's Edit button from here,
              // which is where finished jobs actually live.
              onTap: () => showEventDetails(
                context,
                app,
                analyticsSource: AnalyticsSources.history,
                showActions: widget.isAdmin,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
