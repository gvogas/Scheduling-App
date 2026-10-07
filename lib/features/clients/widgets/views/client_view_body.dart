import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/launchers/phone_call_launcher.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/contact_export_launcher.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/email_compose_launcher.dart';
import 'package:scheduling/features/clients/widgets/cards/client_contacts_cards.dart';
import 'package:scheduling/features/clients/widgets/sections/client_job_history_section.dart';
import 'package:scheduling/features/maps/address_map_launcher.dart';
import 'package:scheduling/features/wave/widgets/wave_sync_badge.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/key_value_panel.dart';
import 'package:scheduling/shared/widgets/primitives/quick_action_button.dart';

/// Read-only display of a ClientRecord — three action tiles, a keyed info panel
/// and an additional-contacts section.
class ClientDetailViewBody extends ConsumerWidget {
  const ClientDetailViewBody({
    required this.client,
    required this.onBookJob,
    super.key,
  });

  final ClientRecord client;

  /// Opens the new-appointment sheet seeded with this client. Supplied by the
  /// host, which owns the navigator context.
  final VoidCallback onBookJob;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayAddress = client.fullAddress;
    final actions = _handlers(context, ref, displayAddress);

    final billingLine = [
      client.billingTerms,
      if (client.autoInvoice) context.l10n.clients_autoInvoice,
    ].where((v) => v.trim().isNotEmpty).join(' · ');

    final infoRows = _infoRows(
      context,
      displayAddress: displayAddress,
      billingLine: billingLine,
      onCall: actions.onCall,
      onEmail: actions.onEmail,
      onDirections: actions.onDirections,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _quickActions(context, actions),
        if (infoRows.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sp24),
          KeyValuePanel(rows: infoRows),
        ],
        const SizedBox(height: AppSpacing.sp16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: actions.onSaveToContacts,
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            label: Text(context.l10n.clients_saveToContacts),
          ),
        ),
        // `contacts` holds only the EXTRA contacts — the customer's own
        // details already live in the header and the info panel.
        ClientContactsCards(contacts: client.contacts),
        const SizedBox(height: AppSpacing.sp24),
        ClientJobHistorySection(clientId: client.id),
        if (client.waveSyncState.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sp16),
          Align(
            alignment: Alignment.centerLeft,
            child: WaveSyncBadge(
              syncState: client.waveSyncState,
              syncError: client.waveSyncError,
              problems: client.waveProblems,
            ),
          ),
        ],
      ],
    );
  }

  /// The `ref`-dependent actions, built where `ref` lives so every widget
  /// below stays presentational. A null entry means there is nothing to act
  /// on, which is what omits both the tile and the info row.
  ({
    VoidCallback? onCall,
    VoidCallback? onDirections,
    VoidCallback? onEmail,
    VoidCallback onSaveToContacts,
  })
  _handlers(BuildContext context, WidgetRef ref, String displayAddress) => (
    onCall: client.phone.isEmpty
        ? null
        : () => launchPhoneCall(context, ref, client.phone),
    onDirections: client.address.isEmpty
        ? null
        : () => AddressMapLauncher.showMapChoices(
            context,
            ref,
            // The composed address, never the stored one: a street-only doc
            // would send the maps app a street with no city.
            address: displayAddress,
          ),
    onEmail: client.email.isEmpty
        ? null
        : () => EmailComposeLauncher.showEmailChoices(
            context,
            ref,
            email: client.email,
          ),
    // Always offered — even a name-only client is worth saving to the phone.
    onSaveToContacts: () => saveClientToPhoneContacts(context, ref, client),
  );

  /// Exactly three tiles by design. Save-to-contacts sits below the panel
  /// rather than competing for a tile slot.
  Widget _quickActions(
    BuildContext context,
    ({
      VoidCallback? onCall,
      VoidCallback? onDirections,
      VoidCallback? onEmail,
      VoidCallback onSaveToContacts,
    })
    actions,
  ) => QuickActionsRow(
    buttons: [
      if (actions.onCall case final onCall?)
        QuickActionButton(
          icon: Icons.phone_outlined,
          label: context.l10n.clients_call,
          onTap: onCall,
        ),
      if (actions.onDirections case final onDirections?)
        QuickActionButton(
          icon: Icons.directions_outlined,
          label: context.l10n.clients_directions,
          onTap: onDirections,
        ),
      QuickActionButton(
        icon: Icons.event_available_outlined,
        label: context.l10n.clients_bookJob,
        onTap: onBookJob,
      ),
    ],
  );

  /// Empty rows are omitted entirely — a read-only detail body never renders
  /// "None" placeholders.
  List<KeyValueRow> _infoRows(
    BuildContext context, {
    required String displayAddress,
    required String billingLine,
    VoidCallback? onCall,
    VoidCallback? onEmail,
    VoidCallback? onDirections,
  }) => [
    if (client.phone.isNotEmpty)
      KeyValueRow(
        label: context.l10n.clients_phoneKey,
        value: client.phone,
        onTap: onCall,
        emphasize: true,
      ),
    if (client.email.isNotEmpty)
      KeyValueRow(
        label: context.l10n.clients_emailKey,
        value: client.email,
        onTap: onEmail,
        emphasize: true,
      ),
    if (client.address.isNotEmpty)
      KeyValueRow(
        label: context.l10n.clients_addressKey,
        value: displayAddress,
        onTap: onDirections,
        emphasize: true,
        semanticLabel: '$displayAddress, ${context.l10n.maps_openAddressWith}',
      ),
    if (client.onSiteManager.trim().isNotEmpty)
      KeyValueRow(
        label: context.l10n.clients_manager,
        value: client.onSiteManager,
      ),
    if (billingLine.isNotEmpty)
      KeyValueRow(label: context.l10n.clients_billingKey, value: billingLine),
  ];
}
