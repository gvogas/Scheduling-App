import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_pill.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

class ClientTile extends StatelessWidget {
  const ClientTile({
    required this.client,
    super.key,
    this.onOpen,
    this.selected = false,
  });

  final ClientRecord client;
  final Future<void> Function()? onOpen;
  final bool selected;

  /// Optical nudge between sp12 and sp16, from the approved row mockup.
  static const double _gutter = 14;

  Future<void> _open(BuildContext context) async {
    if (onOpen != null) {
      await onOpen!();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ClientDetailSheet(client: client),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Resolved once: `displayName` is an uncached getter that runs `stripPhone`
    // (two regex passes), and this rebuilds per row on the paginated list.
    final displayName = client.displayName;
    final address = client.fullAddress.trim();
    final phone = client.phone.trim();
    final count = client.jobCount;

    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _gutter,
            vertical: AppSpacing.sp12,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(name: displayName),
              const SizedBox(width: AppSpacing.sp12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (client.type != ClientType.unset) ...[
                          const SizedBox(width: AppSpacing.sp8),
                          _TypePill(type: client.type),
                        ],
                      ],
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sp4),
                      Text(
                        address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (phone.isNotEmpty || count != null) ...[
                      const SizedBox(height: AppSpacing.sp4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              phone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.monoType.data,
                            ),
                          ),
                          // Null until the recount trigger has run for this
                          // client — unknown renders nothing, never a zero.
                          if (count != null) _JobCount(count: count),
                        ],
                      ),
                    ],
                    if (client.archived) ...[
                      const SizedBox(height: AppSpacing.sp8),
                      const _ArchivedPill(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The client's type, as a glyph + label pill in the row's top-right corner.
class _TypePill extends StatelessWidget {
  const _TypePill({required this.type});

  final ClientType type;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color background, Color foreground) = switch (type) {
      ClientType.residential || ClientType.unset => (
        Icons.home_outlined,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      ClientType.commercial || ClientType.building => (
        Icons.apartment_outlined,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
    };
    return StatusPill(
      label: clientTypeLabel(context.l10n, type),
      icon: icon,
      background: background,
      foreground: foreground,
      radius: AppRadius.r8,
    );
  }
}

/// "Archived", as a neutral pill under the row's own lines.
class _ArchivedPill extends StatelessWidget {
  const _ArchivedPill();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StatusPill(
      label: context.l10n.clients_filterArchived,
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
      radius: AppRadius.r8,
    );
  }
}

/// Right-aligned mono tally on the phone line.
class _JobCount extends StatelessWidget {
  const _JobCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$count', style: theme.monoType.micro),
        const SizedBox(width: AppSpacing.sp4),
        Text(
          context.l10n.clients_jobsCountLabel,
          style: theme.monoType.micro.copyWith(color: theme.palette.textMuted),
        ),
      ],
    );
  }
}
