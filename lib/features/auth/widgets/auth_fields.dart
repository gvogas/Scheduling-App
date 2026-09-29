import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scheduling/core/animations/animated_form_field_wrapper.dart';
import 'package:scheduling/core/animations/app_animation_constants.dart';
import 'package:scheduling/core/security/credential_input.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/clear_text_button.dart';
import 'package:scheduling/shared/widgets/fields/form_helpers.dart';

/// The auth screens' input fields and their error row.
///
/// [AuthPasswordField] is a CREDENTIAL surface: it passes
/// `kCredentialImePersonalizedLearning` so a third-party keyboard cannot
/// retain and cloud-sync what was typed. `obscureText` is not a proxy for
/// that — every password field here has a Show/Hide toggle, so it is plain
/// text the instant the toggle is tapped. Keep the flag beside `obscureText`
/// on any field added here.

/// The error row beneath a bordered auth field — a red dot plus the message.
/// Lives in the decoration's error slot, so it also turns the border red.
class AuthFieldError extends StatelessWidget {
  const AuthFieldError({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(
            color: scheme.error,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppSpacing.sp8),
        Flexible(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ),
      ],
    );
  }
}

/// Wraps [field] under an optional label, keeping labelled and unlabelled auth
/// fields on one layout.
Widget _labelledField(BuildContext context, String? label, Widget field) {
  if (label == null) return field;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [formLabel(context, label), field],
  );
}

/// Email input with shake-on-error and clear button, used by all auth forms.
class AuthEmailField extends StatelessWidget {
  const AuthEmailField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
    required this.onChanged,
    this.focusNode,
    this.errorText,
    this.hasError,
    this.hint,
    this.label,
    this.textInputAction = TextInputAction.next,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool enabled;
  final String? errorText;

  /// Drives shake animation; defaults to `errorText != null`.
  final bool? hasError;
  final String? hint;

  /// Rendered above the field; null keeps the bare hint-only layout.
  final String? label;
  final TextInputAction textInputAction;
  final VoidCallback onSubmitted;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final errorText = this.errorText;
    return _labelledField(
      context,
      label,
      AnimatedFormFieldWrapper(
        hasError: hasError ?? errorText != null,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.emailAddress,
          textInputAction: textInputAction,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.email],
          enabled: enabled,
          onSubmitted: (_) => onSubmitted(),
          onChanged: (_) => onChanged(),
          decoration:
              formInputDecoration(
                context,
                // A visible label already names the field, so the hint only
                // fills in when there is nothing above the box.
                hint ?? (label == null ? context.l10n.common_email : ''),
              ).copyWith(
                error: errorText == null
                    ? null
                    : AuthFieldError(message: errorText),
                prefixIcon: const Icon(Icons.email_outlined, size: 20),
                suffixIcon: ClearTextButton(
                  controller: controller,
                  onCleared: onChanged,
                ),
              ),
        ),
      ),
    );
  }
}

/// Password input with animated show/hide toggle for sign-in and account creation.
class AuthPasswordField extends StatelessWidget {
  const AuthPasswordField({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.isObscured,
    required this.onSubmitted,
    required this.onChanged,
    required this.onToggleObscured,
    this.focusNode,
    this.errorText,
    this.hasError,
    this.prefixIcon = Icons.lock_outlined,
    this.textInputAction = TextInputAction.done,
    this.autofillHints = const [AutofillHints.password],
    this.showLabel = false,
    this.maxLength,
    super.key,
  });

  final String label;

  /// Caps the field without a counter; null leaves it uncapped.
  final int? maxLength;

  /// Renders [label] above the field instead of only as the hint.
  final bool showLabel;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool enabled;
  final String? errorText;
  final bool? hasError;
  final IconData prefixIcon;
  final TextInputAction textInputAction;
  final List<String> autofillHints;
  final bool isObscured;
  final VoidCallback onSubmitted;
  final VoidCallback onChanged;
  final VoidCallback onToggleObscured;

  @override
  Widget build(BuildContext context) {
    final errorText = this.errorText;
    return _labelledField(
      context,
      showLabel ? label : null,
      AnimatedFormFieldWrapper(
        hasError: hasError ?? errorText != null,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: isObscured,
          enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning,
          textInputAction: textInputAction,
          autofillHints: autofillHints,
          inputFormatters: [
            if (maxLength case final cap?)
              LengthLimitingTextInputFormatter(cap),
          ],
          enabled: enabled,
          onSubmitted: (_) => onSubmitted(),
          onChanged: (_) => onChanged(),
          decoration: formInputDecoration(context, showLabel ? '' : label)
              .copyWith(
                error: errorText == null
                    ? null
                    : AuthFieldError(message: errorText),
                prefixIcon: Icon(prefixIcon, size: 20),
                // The Show/Hide link is small type — pin the 48px tap target
                // rather than inheriting whatever the platform density gives.
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                suffixIcon: AnimatedSwitcher(
                  duration: AppAnimationDurations.quick,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: child,
                  ),
                  child: _ObscureToggleLink(
                    key: ValueKey(isObscured),
                    isObscured: isObscured,
                    onPressed: onToggleObscured,
                  ),
                ),
              ),
        ),
      ),
    );
  }
}

/// Show/Hide inside the password field: a mono uppercase text link, not an
/// icon button. The visible type is small, so the tap target is padded out to
/// the 48px minimum.
class _ObscureToggleLink extends StatelessWidget {
  const _ObscureToggleLink({
    required this.isObscured,
    required this.onPressed,
    super.key,
  });

  final bool isObscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final action = isObscured ? l10n.auth_showPassword : l10n.auth_hidePassword;
    return Tooltip(
      message: action,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.r8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp12,
            vertical: AppSpacing.sp16,
          ),
          child: Semantics(
            label: action,
            excludeSemantics: true,
            child: Text(
              (isObscured ? l10n.auth_show : l10n.auth_hide).toUpperCase(),
              style: theme.monoType.label.copyWith(
                color: theme.palette.primaryAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
