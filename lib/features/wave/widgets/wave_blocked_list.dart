import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';
import 'package:scheduling/features/wave/application/wave_providers.dart';
import 'package:scheduling/features/wave/widgets/wave_problem_list.dart';

/// The clients the Wave customer contract refused, listed by name.
///
/// This is the surface the outbox counter could not be: a refused client never
/// becomes a queued job, so it is absent from both counters, and its reason
/// lived only on the client doc where nobody looked. Tapping a row opens the
/// client so the offending field can be edited.
///
/// Renders nothing at all when the list is empty — the same rule the outbox
/// rows follow, since "0 blocked" is not information an admin acts on.
class WaveBlockedList extends ConsumerWidget {
  const WaveBlockedList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked =
        ref.watch(waveBlockedClientsProvider).value ?? const <ClientRecord>[];
    if (blocked.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final client in blocked)
          _BlockedRow(
            client: client,
            onTap: () => showClientDetailSheet(context, client),
          ),
      ],
    );
  }
}

class _BlockedRow extends StatelessWidget {
  const _BlockedRow({required this.client, required this.onTap});

  final ClientRecord client;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sp4,
          vertical: AppSpacing.sp8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.block_rounded, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: AppSpacing.sp12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    client.displayName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  WaveProblemList(problems: client.waveProblems),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}
