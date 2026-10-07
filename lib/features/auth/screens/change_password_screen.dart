import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/auth/widgets/auth_scaffold.dart';
import 'package:scheduling/features/auth/widgets/password_requirements_checklist.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Forced password change for an active account an admin has reset.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({this.authService, super.key});

  final AuthService? authService;

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  late final AuthService _authService =
      widget.authService ?? ref.read(authServiceProvider);

  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final FocusNode _confirmFocus = FocusNode();

  bool _isObscured = true;
  bool _isConfirmObscured = true;
  bool _isLoading = false;
  bool _isSigningOut = false;
  bool _submitted = false;

  String? _passwordError;
  String? _confirmError;
  String? _bannerError;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool get _isBusy => _isLoading || _isSigningOut;

  bool _validate() {
    final l10n = context.l10n;
    final password = _passwordController.text.trim();
    final passwordErr = AuthValidators.newPassword(context, password);
    final confirm = _confirmController.text.trim();
    final confirmErr = confirm.isEmpty
        ? l10n.validation_pleaseConfirmYourPassword
        : confirm != password
        ? l10n.validation_passwordsDoNotMatch
        : null;
    if (passwordErr != _passwordError || confirmErr != _confirmError) {
      setState(() {
        _passwordError = passwordErr;
        _confirmError = confirmErr;
      });
    }
    return passwordErr == null && confirmErr == null;
  }

  void _onFieldChanged() {
    if (_submitted) _validate();
    if (_bannerError != null) setState(() => _bannerError = null);
  }

  Future<void> _submit() async {
    if (_isBusy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitted = true;
      _bannerError = null;
    });
    if (!_validate()) return;
    if (ref.read(isOfflineProvider)) {
      setState(() {
        _bannerError = const AuthFailureNetwork().toLocalizedMessageInContext(
          context,
          AuthErrorContext.register,
        );
      });
      return;
    }

    final logger = ref.read(loggerProvider);
    setState(() => _isLoading = true);
    try {
      await _authService.completePasswordReset(_passwordController.text);
      TextInput.finishAutofillContext();
      if (!mounted) return;
      await _routeIntoApp();
    } catch (error, stackTrace) {
      final failure = AuthErrorMapper.map(error);
      logger.authFailure(
        'AUTH-CHANGEPW completePasswordReset failed',
        failure,
        error,
        stackTrace,
      );
      if (!mounted) return;
      // Flag already cleared server-side: walk them in.
      if (failure is AuthFailureSetupAlreadyComplete) {
        await _routeIntoApp();
        return;
      }
      if (failure is AuthFailureStartingPasswordReused) {
        setState(() {
          _isLoading = false;
          _passwordError = failure.toLocalizedMessageInContext(
            context,
            AuthErrorContext.register,
          );
        });
        return;
      }
      setState(() {
        _isLoading = false;
        _bannerError = failure.toLocalizedMessageInContext(
          context,
          AuthErrorContext.register,
        );
      });
    }
  }

  Future<void> _routeIntoApp() async {
    final outcome = await ref
        .read(signInControllerProvider.notifier)
        .resumeAfterSignUp();
    if (!mounted) return;
    switch (outcome) {
      case SignInSuccess(:final employee):
        await Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.mainCalendar,
          (_) => false,
          arguments: MainCalendarArgs(
            isAdmin: employee.isAdmin,
            employeeId: employee.id,
          ),
        );
      case SignInNoSession() || SignInProfilePending():
        await _signOutToLogin();
      case SignInInvalidCredentials() ||
          SignInNoProfile() ||
          SignInAccountDisabled() ||
          SignInNeedsAccountSetup() ||
          SignInNeedsPasswordChange() ||
          SignInError():
        setState(() {
          _isLoading = false;
          _bannerError = context.l10n.error_somethingWentWrongPleaseTryAgain;
        });
    }
  }

  Future<void> _signOut() async {
    if (_isBusy) return;
    setState(() {
      _isSigningOut = true;
      _bannerError = null;
    });
    await _signOutToLogin();
  }

  Future<void> _signOutToLogin() async {
    final logger = ref.read(loggerProvider);
    final analytics = ref.read(analyticsServiceProvider);
    DeviceDeregistrationDeps? deregistered;
    try {
      // An active account holds push, presence and Live Activity registrations.
      final devices = DeviceDeregistrationDeps.from(ref.read);
      await deregisterThisDevice(devices);
      deregistered = devices;
      await _authService.signOut();
      analytics
        ..logSignOut()
        ..setUserRole(null);
      if (!mounted) return;
      await Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    } catch (error, stackTrace) {
      logger.warn('AUTH-CHANGEPW signOut failed', error, stackTrace);
      if (deregistered != null) await restoreThisDevice(deregistered);
      if (!mounted) return;
      setState(() {
        _isSigningOut = false;
        _isLoading = false;
        _bannerError = context.l10n.error_somethingWentWrongPleaseTryAgain;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AuthScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.auth_changePasswordTitle,
            style: theme.textTheme.headlineLarge,
          ),
          const SizedBox(height: AppSpacing.sp8),
          Text(l10n.auth_changePasswordBody, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.sp24),
          ..._passwordFields(l10n),
          AuthBanner(message: _bannerError),
          const SizedBox(height: AppSpacing.sp24),
          AnimatedLoadingButton(
            label: l10n.auth_saveNewPassword,
            isLoading: _isBusy,
            onPressed: _submit,
          ),
          const SizedBox(height: AppSpacing.sp8),
          Center(
            child: TextButton(
              onPressed: _isBusy ? null : _signOut,
              child: Text(l10n.settings_logOut),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _passwordFields(AppLocalizations l10n) => [
    AuthPasswordField(
      label: l10n.auth_newPassword,
      showLabel: true,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.newPassword],
      maxLength: TextLimits.password,
      controller: _passwordController,
      enabled: !_isBusy,
      errorText: _passwordError,
      isObscured: _isObscured,
      onSubmitted: _confirmFocus.requestFocus,
      onChanged: _onFieldChanged,
      onToggleObscured: () => setState(() => _isObscured = !_isObscured),
    ),
    ValueListenableBuilder<TextEditingValue>(
      valueListenable: _passwordController,
      builder: (context, value, _) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sp8),
        child: PasswordRequirementsChecklist(password: value.text.trim()),
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    AuthPasswordField(
      label: l10n.auth_confirmPassword,
      showLabel: true,
      prefixIcon: Icons.lock_reset_outlined,
      autofillHints: const [AutofillHints.newPassword],
      maxLength: TextLimits.password,
      controller: _confirmController,
      focusNode: _confirmFocus,
      enabled: !_isBusy,
      errorText: _confirmError,
      isObscured: _isConfirmObscured,
      onSubmitted: _submit,
      onChanged: _onFieldChanged,
      onToggleObscured: () =>
          setState(() => _isConfirmObscured = !_isConfirmObscured),
    ),
  ];
}
