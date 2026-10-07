import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';

/// Kept warm on the same grace as the appointment range streams.
///
/// Its other consumer is the nav drawer's Live Map badge, and a closed
/// `DrawerController` doesn't build its child — so without the grace this
/// `collectionGroup('presence')` listener was established fresh on every
/// drawer open and torn down on close, purely to render one number.
final allPresenceStreamProvider = StreamProvider.autoDispose<List<PresenceFix>>(
  (ref) {
    keepWarmWithGrace(ref);
    return ref.watch(presenceRepositoryProvider).watchAllPresence();
  },
);

final liveMapClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final liveMapTickProvider = StreamProvider.autoDispose<int>(
  (ref) => Stream<int>.periodic(const Duration(seconds: 30), (i) => i),
);

/// Watches the tick so the team sheet's freshness labels age live.
final liveMapTeamProvider = Provider.autoDispose<AsyncValue<LiveMapTeam>>((
  ref,
) {
  final fixes = ref.watch(allPresenceStreamProvider);
  final users = ref.watch(allUsersStreamProvider);
  ref.watch(liveMapTickProvider);

  final sources = <AsyncValue<Object?>>[fixes, users];
  for (final source in sources) {
    if (source.hasError) {
      return AsyncValue.error(
        source.error!,
        source.stackTrace ?? StackTrace.current,
      );
    }
  }
  if (sources.any((source) => source.isLoading)) {
    return const AsyncValue.loading();
  }
  return AsyncValue.data(
    LiveMapAggregator.groupTeam(
      fixes: fixes.requireValue,
      users: users.requireValue,
    ),
  );
});

final liveMapPointsProvider =
    Provider.autoDispose<AsyncValue<List<StaffMapPoint>>>(
      (ref) => ref.watch(liveMapTeamProvider).whenData((team) => team.onMap),
    );
