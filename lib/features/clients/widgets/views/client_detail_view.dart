import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/clients/application/client_form_controller.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/policies/client_delete_policy.dart';
import 'package:scheduling/features/clients/widgets/sheets/edit_client_sheet.dart';
import 'package:scheduling/features/clients/widgets/views/client_actions_host.dart';
import 'package:scheduling/features/clients/widgets/views/client_view_body.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

/// Read-only client detail. Editing happens in a sheet above this view, so the
/// view never swaps into a form.
class ClientDetailView extends ConsumerStatefulWidget {
  const ClientDetailView({
    required this.client,
    super.key,
    this.scrollController,
    this.showHandle = false,
    this.bottomPadding = 24,
    this.onDeleted,
  });

  final ClientRecord client;
  final ScrollController? scrollController;
  final bool showHandle;
  final double bottomPadding;

  /// How the host dismisses this view once its record is gone — the sheet pops
  /// itself, the two-pane detail clears its selection.
  final VoidCallback? onDeleted;

  @override
  ConsumerState<ClientDetailView> createState() => _ClientDetailViewState();
}

class _ClientDetailViewState extends ConsumerState<ClientDetailView>
    with ClientActionsHost<ClientDetailView> {
  /// Seed record, and the fallback whenever the live doc read has nothing to
  /// give.
  late ClientRecord _client;

  /// The record this view renders: the live doc when the listener has one, else
  /// [_client].
  ClientRecord get _resolved =>
      ref.read(clientStreamProvider(_client.id)).value ?? _client;

  @override
  void initState() {
    super.initState();
    _client = widget.client;
    // Reported HERE, not from the list tile: the tile's `onOpen` override is
    // what the two-pane layout uses to select into this pane instead of pushing
    // a sheet, so a tile-side event would miss every tablet open.
    ref.read(analyticsServiceProvider)
      ..logScreenView(AnalyticsScreens.clientDetail)
      ..logClientViewed(source: AnalyticsSources.clientsTab);
  }

  Future<void> _openEdit() async {
    final updated = await showEditClientSheet(context, _resolved);
    // Null means cancelled. Editing never removes the record, so this view
    // always has one to keep showing.
    if (!mounted || updated == null) return;
    setState(() => _client = updated);
  }

  // Archiving keeps this view open: the record still exists, and the footer
  // button flips to Unarchive so the action is reversible from where it was
  // taken.
  @override
  void onClientArchived(ClientRecord client, {required bool archived}) {
    if (!mounted) return;
    setState(() => _client = _client.copyWith(archived: archived));
  }

  @override
  void onClientDeleted(ClientRecord client) => widget.onDeleted?.call();

  Future<void> _bookJob() async {
    await showAddEventPopup(
      context,
      prefill: AppointmentPrefill(client: _resolved),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(clientFormControllerProvider);
    // Watched, not read: the whole point is that the server keeps changing this
    // doc after the user's save (the Wave sync state, and `jobCount`), so the
    // view has to rebuild on those.
    final client = ref.watch(clientStreamProvider(_client.id)).value ?? _client;
    return DetailSheetListView(
      scrollController: widget.scrollController,
      showHandle: widget.showHandle,
      bottomPadding: widget.bottomPadding,
      children: [
        _ProfileCard(client: client, onEdit: _openEdit),
        const SizedBox(height: AppSpacing.sp16),
        ClientDetailViewBody(client: client, onBookJob: _bookJob),
        const SizedBox(height: AppSpacing.sp24),
        OutlinedButton.icon(
          onPressed: busy ? null : () => archiveClient(client),
          icon: Icon(
            client.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            size: 18,
          ),
          label: Text(
            client.archived
                ? context.l10n.clients_unarchive
                : context.l10n.clients_archive,
          ),
        ),
        // Advisory only — the callable re-checks with a live count().
        if (canDeleteClient(client)) ...[
          const SizedBox(height: AppSpacing.sp8),
          OutlinedButton.icon(
            style: destructiveOutlinedButtonStyle(context),
            onPressed: busy ? null : () => confirmDeleteClient(client),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(context.l10n.common_delete),
          ),
        ],
      ],
    );
  }
}

/// Avatar, name, a `<type> · since <Mon YYYY>` line, and the Edit pill — one
/// card, as the approved design draws it.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.client, required this.onEdit});

  final ClientRecord client;
  final VoidCallback onEdit;

  /// "Building · since Apr 2023" — either half is dropped when absent, so a
  /// typeless client with no createdAt renders no line at all.
  String _subtitle(BuildContext context) {
    final l10n = context.l10n;
    final parts = <String>[
      if (client.type != ClientType.unset) clientTypeLabel(l10n, client.type),
      if (client.createdAt != null)
        l10n.clients_sinceDate(
          // Locale-aware month+year: "Apr 2023" / "avr. 2023".
          DateFormat.yMMM(
            Localizations.localeOf(context).toString(),
          ).format(client.createdAt!),
        ),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = _subtitle(context);
    // Shown only when it says something the name doesn't already — a business
    // with a named individual on file.
    final displayName = client.displayName;
    final fullName = [
      client.firstName,
      client.lastName,
    ].where((part) => part.trim().isNotEmpty).join(' ').trim();
    // Compared against what the title actually RENDERS, not the stored `name` —
    // that one carries the phone number, so it never equals `fullName` and this
    // line used to repeat the title verbatim on every person client.
    final showPersonName = fullName.isNotEmpty && fullName != displayName;

    final identity = _buildIdentity(
      theme,
      displayName,
      subtitle,
      fullName,
      showPersonName,
    );

    final pill = _EditPill(onEdit: onEdit);

    return DecoratedBox(
      decoration: appCardDecoration(
        theme,
        radius: AppRadius.r16,
        color: theme.colorScheme.surfaceContainerLowest,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sp16),
        // The row holds an avatar, two-to-three text lines and a pill, so it
        // folds rather than overflow once text is scaled up.
        child: context.isCompact
            ? _buildStacked(displayName, identity, pill)
            : _buildInline(displayName, identity, pill),
      ),
    );
  }

  Widget _buildIdentity(
    ThemeData theme,
    String displayName,
    String subtitle,
    String fullName,
    bool showPersonName,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          displayName,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ],
        if (showPersonName) ...[
          const SizedBox(height: 3),
          Text(
            fullName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStacked(String displayName, Widget identity, Widget pill) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AppAvatar(name: displayName, size: AvatarSize.lg),
            const SizedBox(width: AppSpacing.sp12),
            Expanded(child: identity),
          ],
        ),
        const SizedBox(height: AppSpacing.sp12),
        Align(alignment: AlignmentDirectional.centerEnd, child: pill),
      ],
    );
  }

  Widget _buildInline(String displayName, Widget identity, Widget pill) {
    return Row(
      children: [
        AppAvatar(name: displayName, size: AvatarSize.lg),
        const SizedBox(width: AppSpacing.sp12),
        Expanded(child: identity),
        const SizedBox(width: AppSpacing.sp8),
        pill,
      ],
    );
  }
}

/// Tinted Edit pill. Archive and delete live in the scroll footer instead, per
/// the form-sheet convention that destructive actions never sit in the header.
class _EditPill extends StatelessWidget {
  const _EditPill({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: accentPillButtonStyle(context),
      onPressed: onEdit,
      child: Text(context.l10n.common_edit),
    );
  }
}
