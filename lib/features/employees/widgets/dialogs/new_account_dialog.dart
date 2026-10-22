import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/widgets/fields/credential_line.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

/// Shows the credentials the server just issued by a create or a reset.
Future<void> showNewAccountDialog(
  BuildContext context, {
  required String name,
  required NewAccountCredentials credentials,
  String? title,
  String? caption,
}) {
  final dialog = _NewAccountDialog(
    name: name,
    credentials: credentials,
    title: title ?? context.l10n.employees_accountCreatedTitle,
    caption: caption,
  );
  Widget builder(BuildContext _) => dialog;
  if (context.isCupertino) {
    // showCupertinoDialog is non-dismissible by default, like the Material one.
    return showCupertinoDialog<void>(context: context, builder: builder);
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: builder,
  );
}

class _NewAccountDialog extends StatefulWidget {
  const _NewAccountDialog({
    required this.name,
    required this.credentials,
    required this.title,
    this.caption,
  });

  final String name;
  final NewAccountCredentials credentials;
  final String title;
  final String? caption;

  @override
  State<_NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<_NewAccountDialog> {
  bool _copied = false;

  void _copy() {
    copyCredentialsToClipboard(
      email: widget.credentials.email,
      password: widget.credentials.password,
    );
    setState(() => _copied = true);
  }

  /// The password is never persisted, so an uncopied close is confirmed.
  Future<void> _close() async {
    if (!_copied) {
      final l10n = context.l10n;
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.employees_closeWithoutCopyTitle,
        message: l10n.employees_closeWithoutCopyBody,
        confirmLabel: l10n.employees_closeAnyway,
      );
      if (!confirmed || !mounted) return;
    }
    Navigator.pop(context);
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.employees_shareTheseWith(widget.name)),
        const SizedBox(height: AppSpacing.sp16),
        _CredentialRow(
          label: l10n.common_email,
          value: widget.credentials.email,
        ),
        const SizedBox(height: AppSpacing.sp8),
        _CredentialRow(
          label: l10n.employees_temporaryPassword,
          value: widget.credentials.password,
        ),
        const SizedBox(height: AppSpacing.sp12),
        // A reset's caption replaces the untrue first-sign-in line.
        Text(
          widget.caption ?? l10n.employees_theyWillChooseTheirOwnPassword,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    if (context.isCupertino) {
      return CupertinoAlertDialog(
        title: Text(widget.title),
        // Wrap in a transparent Material widget so the selectable text still
        // gets its Material toolbar inside the Cupertino dialog.
        content: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp8),
            child: _buildBody(context),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: _copied ? null : _copy,
            child: Text(
              copyCredentialsLabel(
                context,
                copied: _copied,
                password: widget.credentials.password,
              ),
            ),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: _close,
            child: Text(l10n.common_close),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text(widget.title),
      content: _buildBody(context),
      actions: [
        CopyCredentialsButton(
          copied: _copied,
          password: widget.credentials.password,
          onCopy: _copy,
        ),
        TextButton(onPressed: _close, child: Text(l10n.common_close)),
      ],
    );
  }
}

/// A [CredentialLine] on its own tinted panel — the dialog tints each line,
/// where the roster row tints the pair.
class _CredentialRow extends StatelessWidget {
  const _CredentialRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.sp8,
        horizontal: AppSpacing.sp12,
      ),
      decoration: credentialPanelDecoration(Theme.of(context)),
      child: CredentialLine(label: label, value: value),
    );
  }
}
