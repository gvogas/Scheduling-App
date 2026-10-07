import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/auth/screens/change_password_screen.dart';
import 'package:scheduling/routes/app_routes.dart';

void main() {
  test('the change-password route needs no arguments', () {
    final route = AppRoutes.onGenerateRoute(
      const RouteSettings(name: AppRoutes.changePassword),
    );

    expect(route, isA<MaterialPageRoute<dynamic>>());
    final page = (route! as MaterialPageRoute<dynamic>).builder(_FakeContext());
    expect(page, isA<ChangePasswordScreen>());
  });
}

class _FakeContext extends Fake implements BuildContext {}
