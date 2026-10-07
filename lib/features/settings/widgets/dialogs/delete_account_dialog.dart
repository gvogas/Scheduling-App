import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/security/credential_input.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Body content for the delete-account confirm dialog.
class DeleteAccountWarningContent extends StatelessWidget {
  const DeleteAccountWarningContent({required this.isAdmin, super.key});

  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.settings_deleteAccountConfirmBody),
        if (isAdmin) ...[
          const SizedBox(height: AppSpacing.sp12),
          Text(
            context.l10n.settings_deleteAccountAdminWarning,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

/// Password re-entry before a sensitive action; resolves to the typed password.
///
/// Defaults to the account-deletion copy. The admin password reset reuses it
/// with its own [title], [message] and non-destructive [confirmLabel].
class DeleteAccountReauthDialog extends StatefulWidget {
  const DeleteAccountReauthDialog({
    super.key,
    this.title,
    this.message,
    this.confirmLabel,
    this.destructive = true,
  });

  final String? title;
  final String? message;
  final String? confirmLabel;
  final bool destructive;

  @override
  State<DeleteAccountReauthDialog> createState() =>
      _DeleteAccountReauthDialogState();
}

class _DeleteAccountReauthDialogState extends State<DeleteAccountReauthDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool get _hasPassword => _controller.text.trim().isNotEmpty;

  void _submit() {
    if (!_hasPassword) return;
    Navigator.of(context).pop(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-auth prompt must match the prior delete-confirm dialog's platform look.
    if (context.isCupertino) return _buildCupertino(context);
    return _buildMaterial(context);
  }

  String _title(BuildContext context) =>
      widget.title ?? context.l10n.settings_confirmYourPassword;

  String _message(BuildContext context) =>
      widget.message ?? context.l10n.settings_confirmYourPasswordToDelete;

  String _confirmLabel(BuildContext context) =>
      widget.confirmLabel ?? context.l10n.settings_deletePermanently;

  Widget _buildCupertino(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(_title(context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_message(context)),
          const SizedBox(height: AppSpacing.sp12),
          CupertinoTextField(
            controller: _controller,
            obscureText: _obscure,
            enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning,
            autofocus: true,
            placeholder: context.l10n.common_password,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            suffix: Semantics(
              button: true,
              label: _obscure
                  ? context.l10n.auth_showPassword
                  : context.l10n.auth_hidePassword,
              child: GestureDetector(
                onTap: () => setState(() => _obscure = !_obscure),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sp8,
                  ),
                  child: Icon(
                    _obscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                    size: 20,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.common_cancel),
        ),
        CupertinoDialogAction(
          isDestructiveAction: widget.destructive,
          onPressed: _hasPassword ? _submit : null,
          child: Text(_confirmLabel(context)),
        ),
      ],
    );
  }

  Widget _buildMaterial(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_title(context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_message(context)),
          const SizedBox(height: AppSpacing.sp12),
          TextField(
            controller: _controller,
            obscureText: _obscure,
            enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.l10n.common_password,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure
                    ? context.l10n.auth_showPassword
                    : context.l10n.auth_hidePassword,
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          // dangerFill, never scheme.error: that slot is the lifted foreground red.
          style: widget.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: theme.palette.dangerFill,
                  foregroundColor: theme.palette.onDangerFill,
                )
              : null,
          onPressed: _hasPassword ? _submit : null,
          child: Text(_confirmLabel(context)),
        ),
      ],
    );
  }
}
