import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/storage/secure_storage_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/auth/widgets/auth_scaffold.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

class Login extends ConsumerStatefulWidget {
  const Login({super.key});

  @override
  ConsumerState<Login> createState() => _LoginState();
}

class _LoginState extends ConsumerState<Login> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _isObscured = true;
  bool _submitted = false;

  String? _emailError;
  String? _passwordError;
  String? _bannerError;

  @override
  void initState() {
    super.initState();
    _prefillRememberedEmail();
  }

  Future<void> _prefillRememberedEmail() async {
    // Resolved before the await: `ref` throws once this consumer is disposed,
    // and the log has to survive that — a failed read here is the
    // pre-first-unlock keychain case, which must not go unrecorded.
    final logger = ref.read(loggerProvider);
    try {
      final email = await ref
          .read(secureStorageServiceProvider)
          .read(SecureStorageKeys.rememberedEmail);
      if (!mounted || email == null || email.isEmpty) return;
      if (_emailController.text.isNotEmpty) return;
      _emailController.text = email;
    } catch (e, st) {
      logger.warn('AUTH-PREFILL remembered email read failed', e, st);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  bool _validate() {
    final emailErr = AuthValidators.email(context, _emailController.text);
    final passwordErr = AuthValidators.password(
      context,
      _passwordController.text,
    );

    if (emailErr != _emailError || passwordErr != _passwordError) {
      setState(() {
        _emailError = emailErr;
        _passwordError = passwordErr;
      });
    }

    return emailErr == null && passwordErr == null;
  }

  void _onFieldChanged() {
    if (_submitted) _validate();
    if (_bannerError != null) {
      setState(() => _bannerError = null);
    }
  }

  Future<void> _signIn() async {
    if (ref.read(signInControllerProvider).inProgress) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitted = true;
      _bannerError = null;
    });

    if (!_validate()) return;

    final outcome = await ref
        .read(signInControllerProvider.notifier)
        .signIn(
          email: _emailController.text,
          password: _passwordController.text,
        );
    if (!mounted) return;

    switch (outcome) {
      case SignInSuccess(:final employee):
        // The ROLE, never the uid or the email. `login` is Firebase's own
        // recommended event name, so it feeds the built-in engagement reports.
        ref.read(analyticsServiceProvider).logLogin(role: employee.role);
        TextInput.finishAutofillContext(); // Offer to save these credentials in the OS password manager.
        await _routeToCalendar(employee);
      case SignInInvalidCredentials():
        setState(() {
          _bannerError = context.l10n.error_invalidEmailOrPassword;
        });
      case SignInNoProfile():
        setState(() {
          _bannerError = context.l10n.error_noUserProfileFoundForThisAccount;
        });
      case SignInAccountDisabled():
        setState(() {
          _bannerError = context.l10n.error_thisAccountHasBeenDisabled;
        });
      case SignInError(:final failure):
        setState(() {
          _bannerError = failure.toLocalizedMessageInContext(
            context,
            AuthErrorContext.login,
          );
        });
      // First sign-in on an admin-created account. The session is deliberately
      // still live — the setup screen needs exactly that credential.
      case SignInNeedsAccountSetup(:final firstName, :final lastName):
        await _routeToAccountSetup(firstName: firstName, lastName: lastName);
      // A reset account; the session is kept for the Change password screen.
      case SignInNeedsPasswordChange():
        await Navigator.pushReplacementNamed(context, AppRoutes.changePassword);
      // These only come from resumeAfterSignUp() — signIn() never produces them.
      case SignInNoSession() || SignInProfilePending():
        break;
    }
  }

  Future<void> _routeToAccountSetup({
    required String firstName,
    required String lastName,
  }) async {
    // pushReplacement, not push: there is nothing useful behind this. Setup
    // owns its own way out (finish, or sign out back to here).
    await Navigator.pushReplacementNamed(
      context,
      AppRoutes.accountSetup,
      arguments: AccountSetupArgs(firstName: firstName, lastName: lastName),
    );
  }

  Future<void> _routeToCalendar(EmployeeRecord employee) async {
    await Navigator.pushReplacementNamed(
      context,
      AppRoutes.mainCalendar,
      arguments: MainCalendarArgs(
        isAdmin: employee.isAdmin,
        employeeId: employee.id,
      ),
    );
  }

  Future<void> _openForgotPassword() async {
    final prefill = _emailController.text.trim();
    await Navigator.pushNamed(
      context,
      AppRoutes.forgotPassword,
      arguments: ForgotPasswordArgs(
        initialEmail: prefill.isEmpty ? null : prefill,
      ),
    );
    if (!mounted) return;
    setState(() {
      _submitted = false;
      _emailError = null;
      _passwordError = null;
      _bannerError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(signInControllerProvider).inProgress;
    return AuthScaffold(
      hero: AuthHero(
        title: context.l10n.auth_welcomeBack,
        subtitle: context.l10n.auth_signInToYourAccount,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Error-only: this screen navigates away on success.
          AuthBanner(message: _bannerError),
          const SizedBox(height: AppSpacing.sp16),
          AuthEmailField(
            label: context.l10n.common_email,
            controller: _emailController,
            focusNode: _emailFocus,
            enabled: !isLoading,
            hasError: _emailError != null,
            errorText: _submitted ? _emailError : null,
            onSubmitted: _passwordFocus.requestFocus,
            onChanged: _onFieldChanged,
          ),
          const SizedBox(height: AppSpacing.sp16),
          AuthPasswordField(
            label: context.l10n.common_password,
            showLabel: true,
            controller: _passwordController,
            focusNode: _passwordFocus,
            enabled: !isLoading,
            hasError: _passwordError != null,
            errorText: _submitted ? _passwordError : null,
            isObscured: _isObscured,
            onSubmitted: _signIn,
            onChanged: _onFieldChanged,
            onToggleObscured: () => setState(() => _isObscured = !_isObscured),
          ),
          const SizedBox(height: AppSpacing.sp8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: isLoading ? null : _openForgotPassword,
              child: Text(context.l10n.auth_forgotPassword),
            ),
          ),
          const SizedBox(height: AppSpacing.sp8),
          AnimatedLoadingButton(
            label: context.l10n.auth_signIn,
            isLoading: isLoading,
            onPressed: _signIn,
          ),
        ],
      ),
    );
  }
}
