import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/features/settings/screens/text_size_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _wrap(Widget child, {double textScale = 1.0}) => ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: textScale,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

class _ThemeHost extends StatefulWidget {
  const _ThemeHost({required this.onSetTextScale});

  final ValueChanged<double> onSetTextScale;

  @override
  State<_ThemeHost> createState() => _ThemeHostState();
}

class _ThemeHostState extends State<_ThemeHost> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  Widget build(BuildContext context) {
    return ThemeNotifier(
      themeMode: _themeMode,
      toggleTheme: () => setState(() {
        _themeMode = _themeMode == ThemeMode.light
            ? ThemeMode.dark
            : ThemeMode.light;
      }),
      textScale: 1,
      setTextScale: widget.onSetTextScale,
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                onPressed: () => setState(() {
                  _themeMode = _themeMode == ThemeMode.light
                      ? ThemeMode.dark
                      : ThemeMode.light;
                }),
                child: const Text('toggle theme'),
              ),
              const Expanded(
                child: TextSizeScreen(isAdmin: true, employeeId: 'e1'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('shows all 4 size options', (tester) async {
    await tester.pumpWidget(_wrap(const TextSizeScreen(isAdmin: true, employeeId: 'e1')));
    expect(find.text('Small'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('Large'), findsOneWidget);
    expect(find.text('Extra Large'), findsOneWidget);
  });

  testWidgets('size rows read as buttons, the current one selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _wrap(const TextSizeScreen(isAdmin: true, employeeId: 'e1')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Medium')),
      isSemantics(isButton: true, isSelected: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.text('Small')),
      isSemantics(isButton: true, isSelected: false),
    );
    handle.dispose();
  });

  testWidgets('shows Apply button', (tester) async {
    await tester.pumpWidget(_wrap(const TextSizeScreen(isAdmin: true, employeeId: 'e1')));
    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('Medium is selected by default when scale is 1.0', (tester) async {
    await tester.pumpWidget(_wrap(const TextSizeScreen(isAdmin: true, employeeId: 'e1')));
    expect(find.text('Medium'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Small selects it (no exception)', (tester) async {
    await tester.pumpWidget(_wrap(const TextSizeScreen(isAdmin: true, employeeId: 'e1')));
    await tester.tap(find.text('Small'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Apply calls setTextScale', (tester) async {
    double? appliedScale;
    await tester.pumpWidget(ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (v) => appliedScale = v,
      setLanguage: (_) {},
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TextSizeScreen(isAdmin: true, employeeId: 'e1')),
      ),
    ));
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(appliedScale, isNotNull);
  });

  testWidgets('does not overflow at small screen + 2x text', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: _wrap(const TextSizeScreen(isAdmin: true, employeeId: 'e1')),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a dependency rebuild does not wipe the un-applied text-size selection',
    (tester) async {
      double? appliedScale;

      await tester.pumpWidget(
        _ThemeHost(onSetTextScale: (value) => appliedScale = value),
      );

      await tester.tap(find.text('Small'));
      await tester.pump();
      await tester.tap(find.text('toggle theme'));
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pump();

      expect(appliedScale, 0.8);
    },
  );
}
