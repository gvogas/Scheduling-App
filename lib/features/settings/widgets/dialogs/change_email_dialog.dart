import 'package:flutter/material.dart';

import 'package:scheduling/core/security/credential_input.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/offline_form_notice.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/sheets/app_bottom_sheet.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';

/// A complete, submittable change-email request.
@immutable
class ChangeEmailDraft {
  const ChangeEmailDraft({required this.email, required this.password});

  /// Already trimmed and lowercased — the callable normalizes too, but the
  /// value that leaves this sheet should be the value that gets written.
  final String email;

  /// Deliberately NOT normalized: `reauthenticateWithPassword` trims it, and
  /// lowercasing a password would be a bug.
  final String password;
}

/// Opens the change-sign-in-email sheet.
///
/// Resolves to the draft once the person confirms, or null if they backed out.
/// The caller performs the change — this sheet only collects, so the busy state
/// and every failure notice stay with the screen that owns them.
Future<ChangeEmailDraft?> showChangeEmailSheet(
  BuildContext context, {
  required String currentEmail,
}) => showAppBottomSheet<ChangeEmailDraft>(
  context,
  builder: (_) => _ChangeEmailSheet(currentEmail: currentEmail),
);

/// Holds the draft so the frame's primary verb can gate on it. The frame owns
/// the Cancel · title · Save bar, so the body must not carry a second button.
class _ChangeEmailSheet extends StatefulWidget {
  const _ChangeEmailSheet({required this.currentEmail});

  final String currentEmail;

  @override
  State<_ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends State<_ChangeEmailSheet> {
  ChangeEmailDraft? _draft;
  bool _isDirty = false;

  @override
  Widget build(BuildContext context) {
    return FormSheetFrame(
      title: context.l10n.settings_changeEmail,
      primaryLabel: context.l10n.common_save,
      onPrimary: _draft == null
          ? null
          : () => Navigator.of(context).pop(_draft),
      isDirty: () => _isDirty,
      children: [
        const OfflineFormNotice(),
        ChangeEmailDialogBody(
          currentEmail: widget.currentEmail,
          onDraftChanged: (draft) => setState(() => _draft = draft),
          onDirtyChanged: (dirty) => _isDirty = dirty,
        ),
      ],
    );
  }
}

/// Confirm-twice + re-authenticate, before a sign-in identity moves.
///
/// Two guards, both load-bearing:
///
/// * **Twice.** `changeEmployeeEmail` sets the address through the Admin SDK
///   with no proof the person controls it, so a typo means they cannot sign in.
///   An admin can undo it with the same callable, which bounds the blast
///   radius — but the sheet must not lean on that. (Firebase's
///   `verifyBeforeUpdateEmail` is the alternative and is worse here: it flips
///   Auth OUTSIDE the callable and leaves `users.email` stale with no trigger
///   to reconcile it — the exact desync the callable exists to end.)
/// * **Re-auth.** An unattended unlocked phone changing the sign-in address is
///   the account-takeover primitive.
///
/// Reports a [ChangeEmailDraft] — non-null only when the request is complete
/// and self-consistent — rather than owning a submit button, so the enclosing
/// `FormSheetFrame` keeps the one primary verb.
class ChangeEmailDialogBody extends StatefulWidget {
  const ChangeEmailDialogBody({
    required this.currentEmail,
    required this.onDraftChanged,
    super.key,
    this.onDirtyChanged,
  });

  final String currentEmail;

  /// Null whenever the form is incomplete or the two addresses disagree.
  final ValueChanged<ChangeEmailDraft?> onDraftChanged;

  /// True while any field holds text — what the sheet's discard guard asks.
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<ChangeEmailDialogBody> createState() => _ChangeEmailDialogBodyState();
}

class _ChangeEmailDialogBodyState extends State<ChangeEmailDialogBody> {
  final _email = TextEditingController();
  final _confirm = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  List<TextEditingController> get _controllers => [_email, _confirm, _password];

  @override
  void initState() {
    super.initState();
    for (final controller in _controllers) {
      controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..removeListener(_onChanged)
        ..dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    widget.onDraftChanged(_draft);
    widget.onDirtyChanged?.call(_controllers.any((c) => c.text.isNotEmpty));
  }

  /// The callable lowercases anyway, so a case- or whitespace-only difference
  /// is not a typo and must not read as one.
  bool get _matches =>
      normalizeEmail(_email.text) == normalizeEmail(_confirm.text);

  ChangeEmailDraft? get _draft {
    final email = normalizeEmail(_email.text);
    if (email.isEmpty ||
        !AuthValidators.isValidEmailFormat(email) ||
        !_matches ||
        email == normalizeEmail(widget.currentEmail) ||
        _password.text.isEmpty) {
      return null;
    }
    return ChangeEmailDraft(email: email, password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // Only once the second field has something in it — nagging about a mismatch
    // while it is still empty just describes the starting state.
    final showMismatch = _confirm.text.isNotEmpty && !_matches;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.settings_changeEmailBlurb,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        LabeledTextField(
          key: const Key('newEmail'),
          label: l10n.common_email,
          controller: _email,
          keyboard: TextInputType.emailAddress,
          // Bound to the CALLABLE's cap, not the 320-char client one: a looser
          // field accepts a value the server rejects as invalid-argument,
          // which reaches the user as an unexplained failure they cannot fix.
          maxLength: TextLimits.authEmail,
        ),
        const SizedBox(height: AppSpacing.sp12),
        LabeledTextField(
          key: const Key('confirmEmail'),
          label: l10n.settings_confirmNewEmail,
          controller: _confirm,
          keyboard: TextInputType.emailAddress,
          maxLength: TextLimits.authEmail,
          errorText: showMismatch ? l10n.settings_emailsDoNotMatch : null,
        ),
        const SizedBox(height: AppSpacing.sp12),
        _PasswordField(
          controller: _password,
          obscure: _obscure,
          onToggle: () => setState(() => _obscure = !_obscure),
        ),
      ],
    );
  }
}

/// A raw [TextField] rather than `LabeledTextField`, which has no
/// `obscureText`.
class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.obscure,
    required this.onToggle,
  });

  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return TextField(
      key: const Key('reauthPassword'),
      controller: controller,
      obscureText: obscure,
      enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning,
      autofillHints: const [AutofillHints.password],
      decoration: InputDecoration(
        labelText: l10n.common_password,
        prefixIcon: const Icon(Icons.lock_outlined),
        suffixIcon: Semantics(
          button: true,
          label: obscure ? l10n.auth_showPassword : l10n.auth_hidePassword,
          child: IconButton(
            key: const Key('reauthPasswordToggle'),
            onPressed: onToggle,
            icon: Icon(
              obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            ),
          ),
        ),
      ),
    );
  }
}
