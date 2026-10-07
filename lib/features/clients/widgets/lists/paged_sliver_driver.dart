import 'package:flutter/material.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// What a list re-owns when it builds its own slivers instead of handing them
/// to `PagedListView` — the first-page request and the prefetch trigger.
///
/// Both History and the grouped Clients list do that (a sticky month bar and a
/// per-group card are both slivers a `PagedListView` cannot host), and they had
/// the same two methods each.
mixin PagedSliverPrefetch<W extends StatefulWidget> on State<W> {
  /// Remaining-row threshold before fetching the next page.
  static const int prefetchThreshold = 3;

  /// Requests the first page after a paging reset. `PagingController.refresh()`
  /// only RESETS the state — without this, pull-to-refresh and the first-page
  /// Retry leave the skeleton shimmering with no request in flight.
  void requestFirstPage<K, I>(
    PagingState<K, I> state,
    void Function() fetchNextPage,
  ) {
    if (state.isLoading) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) fetchNextPage();
    });
  }

  /// Requests the next page near the end of the loaded rows. Post-frame: the
  /// controller assigns its own value synchronously, so calling it mid-build
  /// mutates a listenable during layout.
  void maybeFetchNext<K, I>(
    PagingState<K, I> state,
    void Function() fetchNextPage,
    int index,
    int total,
  ) {
    if (index < total - prefetchThreshold) return;
    if (!state.hasNextPage || state.isLoading || state.error != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) fetchNextPage();
    });
  }
}

/// Spinner, retry row, or nothing for a self-built paged list's tail.
class PagedListFooter<K, I> extends StatelessWidget {
  const PagedListFooter({
    required this.state,
    required this.onRetry,
    super.key,
  });

  final PagingState<K, I> state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp16),
        child: Center(
          child: TextButton(
            onPressed: onRetry,
            child: Text(context.l10n.common_retry),
          ),
        ),
      );
    }
    if (!state.isLoading) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.sp16),
      // Use the app's adaptive seam for testable platform styling.
      child: Center(child: AdaptiveProgressIndicator(size: 36, strokeWidth: 4)),
    );
  }
}
