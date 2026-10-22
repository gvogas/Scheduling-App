import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/launchers/phone_call_launcher.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/email_compose_launcher.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/info_card.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// The additional-contacts section, shared by the client and appointment detail views.
/// When collapsible, the cards stay hidden behind a header until tapped.
class ClientContactsCards extends StatelessWidget {
  const ClientContactsCards({
    required this.contacts,
    this.collapsible = false,
    super.key,
  });

  final List<ClientContact> contacts;
  final bool collapsible;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) return const SizedBox.shrink();
    if (collapsible) return _CollapsibleContacts(contacts: contacts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp24),
        SectionLabel(context.l10n.common_contacts),
        const SizedBox(height: AppSpacing.sp8),
        for (final contact in contacts) _ContactCard(contact: contact),
      ],
    );
  }
}

/// Tappable header that reveals the [contacts] cards in place.
class _CollapsibleContacts extends StatefulWidget {
  const _CollapsibleContacts({required this.contacts});

  final List<ClientContact> contacts;

  @override
  State<_CollapsibleContacts> createState() => _CollapsibleContactsState();
}

class _CollapsibleContactsState extends State<_CollapsibleContacts> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppDuration.fast;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp24),
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppRadius.r8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp4),
              child: Row(
                children: [
                  Expanded(
                    child: SectionLabel(
                      context.l10n.common_contactsCount(widget.contacts.length),
                    ),
                  ),
                  AnimatedRotation(
                    duration: duration,
                    turns: _expanded ? 0.5 : 0,
                    child: Icon(
                      Icons.expand_more,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sp8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final contact in widget.contacts)
                        _ContactCard(contact: contact),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A single additional contact rendered as a tappable [InfoCard].
class _ContactCard extends ConsumerWidget {
  const _ContactCard({required this.contact});

  final ClientContact contact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sp8),
      child: InfoCard(
        rows: [
          if (contact.name.isNotEmpty)
            InfoCardRow(
              icon: Icons.person_outline,
              text: contact.name,
              iconColor: scheme.secondary,
              emphasize: true,
            ),
          if (contact.phone.isNotEmpty)
            InfoCardRow(
              icon: Icons.phone_outlined,
              text: contact.phone,
              onTap: () => launchPhoneCall(context, ref, contact.phone),
              trailingIcon: Icons.chevron_right,
            ),
          if (contact.email.isNotEmpty)
            InfoCardRow(
              icon: Icons.email_outlined,
              text: contact.email,
              onTap: () => EmailComposeLauncher.showEmailChoices(
                context,
                ref,
                email: contact.email,
              ),
              trailingIcon: Icons.chevron_right,
            ),
        ],
      ),
    );
  }
}
