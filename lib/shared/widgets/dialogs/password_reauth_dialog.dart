import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/security/credential_input.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Shows a [PasswordReauthDialog] in platform style; null when cancelled.
Future<String?> showPasswordReauthDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required bool destructive,
}) {
  final dialog = PasswordReauthDialog(
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    destructive: destructive,
  );
  return context.isCupertino
      ? showCupertinoDialog<String>(context: context, builder: (_) => dialog)
      : showDialog<String>(context: context, builder: (_) => dialog);
}

/// Password re-entry before a sensitive action; resolves to the typed password.
class PasswordReauthDialog extends StatefulWidget {
  const PasswordReauthDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.destructive,
    super.key,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;

  @override
  State<PasswordReauthDialog> createState() => _PasswordReauthDialogState();
}

class _PasswordReauthDialogState extends State<PasswordReauthDialog> {
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
    // Must match the platform look of the confirm dialog shown before it.
    if (context.isCupertino) return _buildCupertino(context);
    return _buildMaterial(context);
  }

  Widget _buildCupertino(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message),
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
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  Widget _buildMaterial(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
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
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
