import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/attached_dropdown.dart';
import 'package:scheduling/shared/widgets/fields/form_helpers.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// The add-job client step: a mode switch, one field, and whatever the current
/// search has to say about it.
///
/// Never attaches on its own — every row needs a tap — and never dismisses the
/// keyboard except from that tap.
class ClientPicker extends StatelessWidget {
  const ClientPicker({
    required this.controller,
    required this.results,
    required this.status,
    required this.isSearching,
    required this.onChanged,
    required this.onSelect,
    required this.onRetry,
    super.key,
    this.errorText,
    this.onAddNew,
  });

  final TextEditingController controller;
  final List<ClientRecord> results;
  final ClientSearchStatus status;
  final bool isSearching;
  final ValueChanged<String> onChanged;
  final ValueChanged<ClientRecord> onSelect;
  final VoidCallback onRetry;
  final String? errorText;

  /// When non-null the list ends with a create-from-this-number row.
  final VoidCallback? onAddNew;

  /// A finished North-American number, for the "n of 10" tally.
  static const int _nanpLength = 10;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: controller,
          // A phone formatter here would discard the letters of a name.
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.search,
          decoration:
              formInputDecoration(
                context,
                l10n.clients_searchNameOrPhone,
              ).copyWith(
                errorText: errorText,
                // The spinner rides the FIELD, not the list: replacing the
                // results with a centred indicator made the list jump on
                // every keystroke.
                suffixIcon: isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.sp12),
                        child: AdaptiveProgressIndicator(size: 16),
                      )
                    : null,
              ),
          onChanged: onChanged,
        ),
        if (status.isHolding) ...[
          const SizedBox(height: AppSpacing.sp8),
          _Tally(typed: status.digitsTyped, total: _nanpLength),
        ],
        const SizedBox(height: AppSpacing.sp8),
        _body(context, l10n),
      ],
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    // A failure that renders as "no clients found" is how a duplicate gets
    // created for a client who is already on file.
    if (status.failed) return _failure(context, l10n);
    if (controller.text.trim().isEmpty || status.isHolding) {
      return const SizedBox.shrink();
    }
    return _results(context, l10n);
  }

  Widget _failure(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.clients_searchFailed,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        TextButton(onPressed: onRetry, child: Text(l10n.clients_retrySearch)),
      ],
    );
  }

  Widget _results(BuildContext context, AppLocalizations l10n) {
    if (results.isEmpty && onAddNew == null) {
      return Text(
        l10n.clients_noClientsFound,
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    final isPhone = status.mode == ClientQueryMode.phone;
    final theme = Theme.of(context);
    return AttachedDropdown(
      // Option A drops the panel header, so the fallback rung keeps its
      // warning as a caption: those rows answer a query nobody typed and must
      // never read as matches.
      caption: status.isFallback ? l10n.clients_noExactMatchClosest : null,
      children: [
        for (final client in results)
          AttachedDropdownRow(
            // The same avatar the Clients list uses, so a result reads as the
            // client it is rather than as a line of text.
            leading: AppAvatar(name: client.displayName, size: AvatarSize.sm),
            headline: isPhone && client.phone.trim().isNotEmpty
                ? formatPhoneNumber(client.phone)
                : client.displayName,
            headlineStyle: isPhone ? theme.monoType.metric : null,
            detail: isPhone
                ? client.displayName
                : (client.phone.trim().isEmpty
                      ? null
                      : formatPhoneNumber(client.phone)),
            onTap: () => _attach(context, client),
          ),
        if (onAddNew != null)
          AttachedDropdownRow(
            leading: Icon(
              Icons.person_add_alt_1,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            headline: l10n.clients_noneOfTheseNewClient,
            headlineStyle: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
            onTap: () {
              FocusScope.of(context).unfocus();
              onAddNew!();
            },
          ),
      ],
    );
  }

  /// The ONE place allowed to drop the keyboard.
  void _attach(BuildContext context, ClientRecord client) {
    FocusScope.of(context).unfocus();
    onSelect(client);
  }
}

/// "4 of 10 · Keep going" — the number is still too short to be selective.
class _Tally extends StatelessWidget {
  const _Tally({required this.typed, required this.total});

  final int typed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Wrap(
      spacing: AppSpacing.sp8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          l10n.clients_digitsTyped(typed, total),
          style: theme.monoType.data,
        ),
        Text(
          l10n.clients_keepGoing,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
