import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/auth/widgets/auth_scaffold.dart';
import 'package:scheduling/features/auth/widgets/auth_text.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail, this.authService});

  final String? initialEmail;

  final AuthService? authService;

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordState();
}

class _ForgotPasswordState extends ConsumerState<ForgotPasswordScreen> {
  late final AuthService _authService;
  late final AppLogger _logger;
  late final TextEditingController _emailController;

  bool _isLoading = false;
  bool _emailSent = false;
  bool _resentOnce = false;
  String? _emailError;
  String _errorMessage = '';
  int _restartTick = 0;

  String? get _feedbackMessage => _errorMessage.isEmpty ? null : _errorMessage;
  bool get _canSubmit => !_isLoading;
  bool get _canResend => _emailSent && !_resentOnce && !_isLoading;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? ref.read(authServiceProvider);
    _logger = ref.read(loggerProvider);
    _emailController = TextEditingController(text: widget.initialEmail ?? '');
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  void _submitResetEmail() {
    _sendResetEmail();
  }

  Future<bool> _sendResetEmail() async {
    if (!_canSubmit) return false;
    FocusScope.of(context).unfocus();
    final email = normalizeEmail(_emailController.text);
    final emailError = AuthValidators.email(context, email);

    if (emailError != null) {
      setState(() {
        _emailError = emailError;
        _errorMessage = '';
      });
      return false;
    }

    setState(() {
      _isLoading = true;
      _emailError = null;
      _errorMessage = '';
      if (_emailController.text != email) {
        _emailController.text = email;
      }
    });

    String? resetError;
    try {
      await _authService.sendPasswordResetEmail(email);
    } catch (error, st) {
      final failure = AuthErrorMapper.map(error);
      _logger.authFailure('AUTH-RESET reset failed', failure, error, st);
      if (!mounted) return false;
      resetError = failure.toForgotPasswordMessage(context);
    }

    final wasSent = resetError == null;
    if (!mounted) return wasSent;
    setState(() {
      _isLoading = false;
      if (resetError != null) {
        _errorMessage = resetError;
      } else {
        if (!_emailSent) {
          _restartTick++;
        }
        _emailSent = true;
      }
    });
    return wasSent;
  }

  void _clearFeedback() {
    if (_emailError == null && _errorMessage.isEmpty) return;
    setState(() {
      _emailError = null;
      _errorMessage = '';
    });
  }

  Future<void> _resendEmail() async {
    if (!_canResend) return;
    if (await _sendResetEmail()) {
      if (!mounted) return;
      setState(() => _resentOnce = true);
    }
  }

  void _backToSignIn() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      // The sent state stands on its own without a hero.
      hero: _emailSent
          ? null
          : AuthHero(
              title: context.l10n.auth_forgotYourPassword,
              subtitle: context
                  .l10n
                  .auth_enterYourAccountEmailAndWeLlSendYouALinkToResetYourPassword,
              thin: true,
            ),
      child: AuthFormSwitcher(
        child: _emailSent
            ? _buildSuccess(key: ValueKey('success_$_restartTick'))
            : _buildForm(key: ValueKey('form_$_restartTick')),
      ),
    );
  }

  Widget _buildForm({required Key key}) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final scheme = theme.colorScheme;

    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AuthEmailField(
          label: context.l10n.common_email,
          controller: _emailController,
          enabled: !_isLoading,
          errorText: _emailError,
          hint: context.l10n.auth_youExampleCom,
          textInputAction: TextInputAction.done,
          onSubmitted: _submitResetEmail,
          onChanged: _clearFeedback,
        ),
        AuthBanner(message: _feedbackMessage),
        const SizedBox(height: AppSpacing.sp16),
        WarningNote(
          message: context.l10n.auth_noEmailOnAccountNote,
          icon: Icons.info_outline,
          radius: AppRadius.r8,
        ),
        const SizedBox(height: AppSpacing.sp24),
        AnimatedLoadingButton(
          label: context.l10n.auth_sendResetEmail,
          isLoading: _isLoading,
          onPressed: _submitResetEmail,
        ),
        const SizedBox(height: AppSpacing.sp8),
        Center(
          child: TextButton(
            onPressed: _isLoading ? null : _backToSignIn,
            child: Text(
              context.l10n.auth_backToSignIn,
              style: textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess({required Key key}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      key: key,
      padding: const EdgeInsets.all(AppSpacing.sp24),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.r20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: AuthIconBadge(
              icon: Icons.mark_email_read_rounded,
              background: theme.statusColors.successContainer,
              foreground: theme.statusColors.success,
            ),
          ),
          const SizedBox(height: AppSpacing.sp24),
          AuthHeaderText(
            title: context.l10n.auth_checkYourInbox,
            subtitle: context
                .l10n
                .auth_ifAnAccountExistsForThisEmailAPasswordResetLinkHasBeenSent,
          ),
          const SizedBox(height: AppSpacing.sp24),
          _FactPanel(
            facts: [
              (
                icon: Icons.schedule_rounded,
                text: context.l10n.auth_resetExpiryFact,
              ),
              (
                icon: Icons.devices_rounded,
                text: context.l10n.auth_resetSignsOutFact,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sp12),
          WarningNote(
            message: context.l10n.auth_noEmailOnAccountNote,
            filled: false,
          ),
          AuthBanner(message: _feedbackMessage),
          const SizedBox(height: AppSpacing.sp16),
          _SentPanel(
            resent: _resentOnce,
            busy: _isLoading,
            onResend: _resendEmail,
          ),
          const SizedBox(height: AppSpacing.sp24),
          AnimatedLoadingButton(
            label: context.l10n.auth_backToSignIn,
            isLoading: _isLoading,
            onPressed: _isLoading ? () {} : _backToSignIn,
          ),
        ],
      ),
    );
  }
}

/// The two reset-link facts shown in the success state.
class _FactPanel extends StatelessWidget {
  const _FactPanel({required this.facts});

  final List<({IconData icon, String text})> facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.palette.textBody,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.r12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var i = 0; i < facts.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sp12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    facts[i].icon,
                    size: 16,
                    color: theme.palette.textTertiary,
                  ),
                  const SizedBox(width: AppSpacing.sp8),
                  Expanded(child: Text(facts[i].text, style: textStyle)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The one in-place resend action shown after the first reset email.
class _SentPanel extends StatelessWidget {
  const _SentPanel({
    required this.resent,
    required this.busy,
    required this.onResend,
  });

  final bool resent;
  final bool busy;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = theme.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sp16),
      decoration: BoxDecoration(
        color: resent ? palette.lockedPanel : null,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        border: Border.all(
          color: resent ? palette.lockedPanelBorder : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.auth_resetSentPanelTitle,
            style: theme.monoType.label,
          ),
          const SizedBox(height: AppSpacing.sp8),
          if (resent)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_rounded, size: 16, color: palette.textMuted),
                const SizedBox(width: AppSpacing.sp8),
                Expanded(
                  child: Text(
                    context.l10n.auth_sentAgainJustNow,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                    ),
                  ),
                ),
              ],
            )
          else
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: busy ? null : onResend,
                child: Text(context.l10n.auth_sendItAgain),
              ),
            ),
        ],
      ),
    );
  }
}
