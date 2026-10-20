import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/domain/policies/client_contacts_policy.dart';
import 'package:scheduling/features/clients/widgets/sections/additional_contacts_section.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets(
    'additional contacts section does not overflow at 2x text on phone width',
    (tester) async {
      final fields = ContactFields();
      addTearDown(fields.dispose);
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _wrap(
            AdditionalContactsSection(
              contacts: [fields],
              errors: const {},
              onAddContact: () {},
              onRemoveContact: (_) {},
              onClearError: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disables add controls at the backend contact limit', (
    tester,
  ) async {
    final fields = [
      for (var i = 0; i < kMaxAdditionalContacts; i++) ContactFields(),
    ];
    addTearDown(() {
      for (final field in fields) {
        field.dispose();
      }
    });
    var adds = 0;

    await tester.pumpWidget(
      _wrap(
        AdditionalContactsSection(
          contacts: fields,
          errors: const {},
          onAddContact: () => adds++,
          onRemoveContact: (_) {},
          onClearError: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Maximum 50 contacts'), findsOneWidget);
    final add = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Add'),
    );
    expect(add.onPressed, isNull);
    expect(adds, 0);
  });
}
