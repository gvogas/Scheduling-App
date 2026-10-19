import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/debouncer.dart';

/// The debounced-search half of a paged list — the ONE owner of the block
/// `ClientsListView` and `AppointmentHistoryView` used to carry as five
/// byte-identical members each.
mixin DebouncedPagedSearch<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  late final Debouncer searchDebounce;

  /// The query the server search is running for.
  String committedQuery = '';

  /// The host widget's live search text.
  String searchQueryOf(W widget);

  /// Fires once the first page has replaced the skeleton, for a tour host.
  VoidCallback? get onFirstPageSettled;

  /// The Crashlytics warn tag for a search that throws inside the timer.
  String get searchDebounceTag;

  /// Which list this is, for `search_used` (see `AnalyticsSurfaces`).
  String get analyticsSurface;

  @override
  void initState() {
    super.initState();
    searchDebounce = Debouncer.tagged(
      kSearchDebounce,
      logger: ref.read(loggerProvider),
      tag: searchDebounceTag,
    );
    if (searchQueryOf(widget).trim().isNotEmpty) scheduleSearch();
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (searchQueryOf(widget).trim() == searchQueryOf(oldWidget).trim()) {
      return;
    }
    scheduleSearch();
  }

  /// Restarts the debounce for the current query; clearing commits at once.
  void scheduleSearch() {
    final next = searchQueryOf(widget).trim();
    if (next.isEmpty) {
      searchDebounce.cancel();
      if (committedQuery.isNotEmpty) setState(() => committedQuery = '');
      return;
    }
    searchDebounce.run(() {
      if (mounted && next != committedQuery) {
        // Reported at the DEBOUNCE COMMIT, which is the one moment a search
        // actually runs — instrumenting the text field would file an event per
        // keystroke and report typing as searching. The query itself is never
        // sent: a search here is a surname or a phone number by definition.
        ref
            .read(analyticsServiceProvider)
            .logSearchUsed(surface: analyticsSurface, queryLength: next.length);
        setState(() => committedQuery = next);
      }
    });
  }

  /// Post-frame, so the row a tour targets has actually been laid out by the
  /// time the host asks showcase whether it is rendered.
  void notifyFirstPageSettled() {
    final notify = onFirstPageSettled;
    if (notify == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) notify();
    });
  }

  @override
  void dispose() {
    searchDebounce.dispose();
    super.dispose();
  }
}
