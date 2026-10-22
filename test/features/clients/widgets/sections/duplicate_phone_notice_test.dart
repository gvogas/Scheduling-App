import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/clients/application/duplicate_phone_check.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/sections/duplicate_phone_notice.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockRepo extends Mock implements ClientsRepository {}

class _MockLogger extends Mock implements AppLogger {}

const _jane = ClientRecord(id: 'x1', name: 'Jane Doe', phone: '5145550000');

void main() {
  late DuplicatePhoneCheck check;
  late ClientRecord? opened;

  setUp(() {
    opened = null;
    check = DuplicatePhoneCheck(
      repository: _MockRepo(),
      logger: _MockLogger(),
      phone: TextEditingController(),
    );
  });

  tearDown(() => check.dispose());

  Future<void> pump(
    WidgetTester tester, {
    double width = 400,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DuplicatePhoneNotice(
              check: check,
              onOpen: (c) => opened = c,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders nothing without a match', (tester) async {
    await pump(tester);
    expect(find.byType(TextButton), findsNothing);
    expect(find.textContaining('Already on file'), findsNothing);
  });

  testWidgets('a match shows the name; Open hands it to onOpen', (
    tester,
  ) async {
    check.match = _jane;
    await pump(tester);

    expect(find.text('Already on file: Jane Doe'), findsOneWidget);
    await tester.tap(find.text('Open'));
    expect(opened, _jane);
  });

  testWidgets('Use anyway hides the row', (tester) async {
    check.match = _jane;
    await pump(tester);

    await tester.tap(find.text('Use anyway'));
    await tester.pump();

    expect(check.acknowledged, isTrue);
    expect(find.textContaining('Already on file'), findsNothing);
  });

  testWidgets('no overflow at 260 px with 2x text', (tester) async {
    check.match = _jane;
    await pump(
      tester,
      width: 260,
      textScaler: const TextScaler.linear(2),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Use anyway'), findsOneWidget);
  });
}
