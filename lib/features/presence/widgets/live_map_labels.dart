import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/l10n/l10n.dart';

/// "5 min ago", or "Offline — last seen 5 min ago" once the fix is stale.
String freshnessLabel(
  AppLocalizations l10n,
  DateTime? updatedAt,
  DateTime now,
) {
  final ago = switch (LiveMapAggregator.freshnessOf(updatedAt, now)) {
    FreshnessJustNow() => l10n.liveMap_lastUpdatedJustNow,
    FreshnessMinutesAgo(:final minutes) => l10n.liveMap_lastUpdatedMinutesAgo(
      minutes,
    ),
    FreshnessHoursAgo(:final hours) => l10n.liveMap_lastUpdatedHoursAgo(hours),
  };
  return LiveMapAggregator.isStale(updatedAt, now)
      ? l10n.liveMap_offlineLastSeen(ago)
      : ago;
}

/// Metres to the nearest ten under a kilometre, one decimal of km above it.
String distanceLabel(BuildContext context, double meters) {
  final l10n = context.l10n;
  if (meters < 1000) {
    return l10n.liveMap_distanceMeters(((meters / 10).round() * 10).toString());
  }
  final km = NumberFormat.decimalPatternDigits(
    locale: Localizations.localeOf(context).toString(),
    decimalDigits: 1,
  ).format(meters / 1000);
  return l10n.liveMap_distanceKm(km);
}
