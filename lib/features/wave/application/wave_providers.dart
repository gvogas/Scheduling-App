import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/wave/data/wave_service.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';

final waveServiceProvider = Provider<WaveService>(
  (ref) => WaveService(logger: ref.read(loggerProvider)),
);

/// Cached Wave connection; invalidate after Connect.
final waveConnectionProvider = FutureProvider<WaveConnection?>(
  (ref) => ref.read(waveServiceProvider).getConnection(),
);

/// The clients the Wave customer contract refused, newest query per rebuild.
///
/// `autoDispose` because it is only alive while the admin has Settings open —
/// a permanent listener on a query nobody is looking at is exactly the second
/// live listener the clients rules warn about.
final waveBlockedClientsProvider =
    StreamProvider.autoDispose<List<ClientRecord>>(
      (ref) => ref.watch(clientsRepositoryProvider).watchBlockedClients(),
    );
