import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/auth/screens/account_setup_screen.dart';
import 'package:scheduling/features/auth/screens/forgot_password_screen.dart';
import 'package:scheduling/features/auth/screens/login_screen.dart';
import 'package:scheduling/features/dashboard/screens/dashboard_screen.dart';
import 'package:scheduling/features/notifications/screens/notification_ask_screen.dart';
import 'package:scheduling/routes/app_routes.dart';

void main() {
  Widget build(String name, [Object? arguments]) {
    final route = AppRoutes.onGenerateRoute(
      RouteSettings(name: name, arguments: arguments),
    );
    expect(route, isA<MaterialPageRoute<dynamic>>(), reason: name);
    return (route! as MaterialPageRoute<dynamic>).builder(_FakeContext());
  }

  test('argument-required routes recover instead of throwing', () {
    for (final routeName in const [
      AppRoutes.dayRoute,
      AppRoutes.mainCalendar,
      AppRoutes.employees,
      AppRoutes.clients,
      AppRoutes.history,
      AppRoutes.liveMap,
      AppRoutes.settings,
      AppRoutes.textSize,
      AppRoutes.locationSharing,
    ]) {
      expect(build(routeName), isA<InvalidRouteScreen>(), reason: routeName);
    }
  });

  test('settings detail routes degrade on a wrong argument type', () {
    for (final routeName in const [
      AppRoutes.textSize,
      AppRoutes.locationSharing,
    ]) {
      expect(
        build(routeName, 'not-args'),
        isA<InvalidRouteScreen>(),
        reason: routeName,
      );
    }
  });

  test('login takes optional args: null and a wrong type both build Login', () {
    expect(build(AppRoutes.login), isA<Login>());
    expect((build(AppRoutes.login) as Login).notice, isNull);
    expect((build(AppRoutes.login, 42) as Login).notice, isNull);
    final withNotice =
        build(
              AppRoutes.login,
              const LoginArgs(notice: LoginNotice.accountReady),
            )
            as Login;
    expect(withNotice.notice, LoginNotice.accountReady);
  });

  test(
    'forgot password: null opens with no prefill, wrong type is invalid',
    () {
      final bare = build(AppRoutes.forgotPassword);
      expect(bare, isA<ForgotPasswordScreen>());
      expect((bare as ForgotPasswordScreen).initialEmail, isNull);

      final prefilled =
          build(
                AppRoutes.forgotPassword,
                const ForgotPasswordArgs(initialEmail: 'a@b.co'),
              )
              as ForgotPasswordScreen;
      expect(prefilled.initialEmail, 'a@b.co');

      expect(
        build(AppRoutes.forgotPassword, 'a@b.co'),
        isA<InvalidRouteScreen>(),
      );
    },
  );

  test('account setup degrades a wrong argument type to blank names', () {
    final screen = build(AppRoutes.accountSetup, 42) as AccountSetupScreen;
    expect(screen.firstName, isEmpty);
  });

  test('dashboard degrades a wrong argument type to least privilege', () {
    final screen = build(AppRoutes.dashboard, 'admin') as DashboardScreen;
    expect(screen.isAdmin, isFalse);
  });

  test('notification ask builds without arguments', () {
    expect(build(AppRoutes.notificationAsk), isA<NotificationAskScreen>());
  });
}

class _FakeContext extends Fake implements BuildContext {}
