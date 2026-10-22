import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
import 'package:scheduling/features/auth/screens/account_setup_screen.dart';
import 'package:scheduling/features/auth/screens/change_password_screen.dart';
import 'package:scheduling/features/auth/screens/forgot_password_screen.dart';
import 'package:scheduling/features/auth/screens/login_screen.dart';
import 'package:scheduling/features/calendar/screens/day_route_screen.dart';
import 'package:scheduling/features/calendar/screens/overdue_review_screen.dart';
import 'package:scheduling/features/clients/screens/history_screen.dart';
import 'package:scheduling/features/dashboard/screens/dashboard_screen.dart';
import 'package:scheduling/features/notifications/screens/notification_ask_screen.dart';
import 'package:scheduling/features/presence/screens/share_location_ask_screen.dart';
import 'package:scheduling/features/settings/screens/location_sharing_screen.dart';
import 'package:scheduling/features/settings/screens/my_details_screen.dart';
import 'package:scheduling/features/settings/screens/settings_screen.dart';
import 'package:scheduling/features/settings/screens/text_size_screen.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/hub_shell.dart';

class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String forgotPassword = '/forgot-password';
  static const String accountSetup = '/account-setup';
  static const String changePassword = '/change-password';
  static const String mainCalendar = '/calendar';
  static const String employees = '/employees';
  static const String clients = '/clients';
  static const String history = '/history';
  static const String liveMap = '/live-map';
  static const String settings = '/settings';
  static const String myDetails = '/settings/my-details';
  static const String textSize = '/settings/text-size';
  static const String locationSharing = '/settings/location-sharing';
  static const String dashboard = '/dashboard';
  static const String dayRoute = '/day-route';
  static const String notificationAsk = '/notification-ask';
  static const String shareLocationAsk = '/share-location';
  static const String overdueReview = '/overdue-review';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case login:
        // Optional: a mistyped argument drops the notice, never the screen.
        final args = _args<LoginArgs>(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => Login(notice: args?.notice),
        );

      case forgotPassword:
        // Null is a legal open (no prefill); a wrong type is not.
        final raw = settings.arguments;
        if (raw != null && raw is! ForgotPasswordArgs) {
          return _invalidRoute(settings);
        }
        final args = raw as ForgotPasswordArgs?;
        return AppPageRoute(
          settings: settings,
          builder: (_) =>
              ForgotPasswordScreen(initialEmail: args?.initialEmail),
        );

      case accountSetup:
        // Args are optional: sign-in and splash both route here for an
        // `invited` account, seeding whatever name halves the admin typed.
        final args = _args<AccountSetupArgs>(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => AccountSetupScreen(
            firstName: args?.firstName ?? '',
            lastName: args?.lastName ?? '',
          ),
        );

      case changePassword:
        return AppPageRoute(
          settings: settings,
          builder: (_) => const ChangePasswordScreen(),
        );

      case dashboard:
        final args = _args<DashboardArgs>(settings);
        return AppPageRoute(
          settings: settings,
          // Defaults CLOSED; this is HOME, so least privilege rather than an invalid-link screen (ADR-0017).
          builder: (_) => DashboardScreen(
            isAdmin: args?.isAdmin ?? false,
            employeeId: args?.employeeId ?? '',
            userName: args?.userName,
            email: args?.email,
          ),
        );

      case dayRoute:
        final args = _args<DayRouteArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => DayRouteScreen(
            isAdmin: args.isAdmin,
            employeeId: args.employeeId,
            initialDay: args.initialDay,
          ),
        );

      case mainCalendar:
        // This is the post-login entry point — always builds a fresh shell
        // via pushReplacement.
        final args = _args<MainCalendarArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) =>
              HubShell(isAdmin: args.isAdmin, employeeId: args.employeeId),
        );

      case employees:
        final args = _args<MainCalendarArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return _hubRoute(
          settings,
          HubTab.employees,
          isAdmin: args.isAdmin,
          employeeId: args.employeeId,
        );

      case clients:
        final args = _args<ClientsListArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return _hubRoute(
          settings,
          HubTab.clients,
          isAdmin: args.isAdmin,
          employeeId: args.employeeId,
        );

      case history:
        final args = _args<HistoryArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          // The archive is admin-only (2026-09-06). The drawer no longer
          // offers it to an employee; this is the half a forged argument or a
          // stale back stack cannot get past.
          builder: (_) => AdminOnly(
            child: HistoryScreen(
              isAdmin: args.isAdmin,
              employeeId: args.employeeId,
            ),
          ),
        );

      case overdueReview:
        final args = _args<OverdueReviewArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => AdminOnly(
            child: OverdueReviewScreen(
              isAdmin: args.isAdmin,
              employeeId: args.employeeId,
            ),
          ),
        );

      case liveMap:
        final args = _args<MainCalendarArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return _hubRoute(
          settings,
          HubTab.liveMap,
          isAdmin: args.isAdmin,
          employeeId: args.employeeId,
        );

      case notificationAsk:
        return AppPageRoute(
          settings: settings,
          builder: (_) => const NotificationAskScreen(),
        );

      case shareLocationAsk:
        return AppPageRoute(
          settings: settings,
          builder: (_) => const ShareLocationAskScreen(),
        );

      case AppRoutes.myDetails:
        return AppPageRoute(
          settings: settings,
          builder: (_) => const MyDetailsScreen(),
        );

      case AppRoutes.textSize:
        final args = _args<SettingsDetailArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => TextSizeScreen(
            isAdmin: args.isAdmin,
            employeeId: args.employeeId,
          ),
        );

      case AppRoutes.locationSharing:
        final args = _args<SettingsDetailArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => LocationSharingScreen(
            isAdmin: args.isAdmin,
            employeeId: args.employeeId,
          ),
        );

      case AppRoutes.settings:
        // Settings is only reachable post-login, so args are always present.
        final args = _args<SettingsArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          builder: (_) => SettingsScreen(
            name: args.name,
            email: args.email,
            role: args.role,
            employeeId: args.employeeId,
          ),
        );

      default:
        return null;
    }
  }

  static T? _args<T>(RouteSettings settings) {
    final args = settings.arguments;
    return args is T ? args : null;
  }

  static Route<dynamic> _invalidRoute(RouteSettings settings) {
    return AppPageRoute<void>(
      settings: settings,
      builder: (_) => const InvalidRouteScreen(),
    );
  }

  /// Route for any non-calendar hub tab — redirects into a tab switch if a
  /// shell is already live, otherwise opens a fresh one.
  static Route<dynamic> _hubRoute(
    RouteSettings routeSettings,
    HubTab destination, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {
    if (HubShell.liveState != null) {
      return HubTabRedirectRoute(
        settings: routeSettings,
        destination: destination,
        isAdmin: isAdmin,
        employeeId: employeeId,
        userName: userName,
        userEmail: userEmail,
      );
    }
    return AppPageRoute(
      settings: routeSettings,
      builder: (_) => HubShell(
        initialTab: destination,
        isAdmin: isAdmin,
        employeeId: employeeId,
        userName: userName,
        userEmail: userEmail,
      ),
    );
  }
}

/// Renders [child] only for a live active admin; anyone else gets a screen they
/// can leave rather than a surface the rules would reject anyway.
class AdminOnly extends ConsumerWidget {
  const AdminOnly({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(isActiveAdminProvider) ? child : const InvalidRouteScreen();
}

class InvalidRouteScreen extends StatelessWidget {
  const InvalidRouteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sp24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off_rounded, size: 40, color: scheme.error),
              const SizedBox(height: AppSpacing.sp12),
              Text(
                context.l10n.nav_invalidLink,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sp16),
              FilledButton(
                // `mainCalendar` and `settings` are reached by
                // pushReplacement, so this screen can BE the whole stack and a
                // pop is a no-op — which would leave the one affordance dead
                // on exactly the routes most likely to land here.
                onPressed: () => Navigator.canPop(context)
                    ? Navigator.pop(context)
                    : Navigator.pushNamedAndRemoveUntil(
                        context,
                        AppRoutes.login,
                        (_) => false,
                      ),
                child: Text(context.l10n.common_back),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standard page route with platform-default transitions and reduced-motion support.
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({required super.builder, super.settings});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

class ForgotPasswordArgs {
  const ForgotPasswordArgs({this.initialEmail});
  final String? initialEmail;
}

/// Typed, not a string, so the sign-in screen localizes it at render time.
enum LoginNotice { accountReady }

class LoginArgs {
  const LoginArgs({this.notice});
  final LoginNotice? notice;
}

class AccountSetupArgs {
  const AccountSetupArgs({this.firstName = '', this.lastName = ''});

  /// Whatever the admin already typed, so the person confirms rather than
  /// retypes. Both are optional — the fields are still required on the screen.
  final String firstName;
  final String lastName;
}

class MainCalendarArgs {
  const MainCalendarArgs({required this.isAdmin, required this.employeeId});
  final bool isAdmin;
  final String employeeId;
}

class ClientsListArgs {
  const ClientsListArgs({required this.isAdmin, required this.employeeId});
  final bool isAdmin;
  final String employeeId;
}

class HistoryArgs {
  const HistoryArgs({required this.isAdmin, required this.employeeId});
  final bool isAdmin;
  final String employeeId;
}

class OverdueReviewArgs {
  const OverdueReviewArgs({required this.isAdmin, required this.employeeId});
  final bool isAdmin;
  final String employeeId;
}

class DayRouteArgs {
  const DayRouteArgs({
    required this.isAdmin,
    required this.employeeId,
    this.initialDay,
  });
  final bool isAdmin;
  final String employeeId;

  /// The day the route opens on; null means today.
  final DateTime? initialDay;
}

class DashboardArgs {
  const DashboardArgs({
    required this.isAdmin,
    required this.employeeId,
    this.userName,
    this.email,
  });
  final bool isAdmin;
  final String employeeId;
  final String? userName;
  final String? email;
}

/// The two Settings sub-screens (text size, location sharing).
class SettingsDetailArgs {
  const SettingsDetailArgs({required this.isAdmin, required this.employeeId});
  final bool isAdmin;
  final String employeeId;
}

class SettingsArgs {
  const SettingsArgs({
    required this.name,
    required this.email,
    this.role,
    this.employeeId = '',
  });
  final String name;
  final String email;
  final String? role;
  final String employeeId;
}
