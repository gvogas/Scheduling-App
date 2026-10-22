import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/shared/widgets/sheets/form_error_focus.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

void main() {
  late List<String> haptics;

  setUp(() {
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget harness(FormErrorFocus focus, TextEditingController controller) =>
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              TextField(
                controller: controller,
                focusNode: focus.nodeFor('name'),
              ),
              SheetFocusScroll(
                focusNode: focus.nodeFor('date'),
                child: const SizedBox(height: 40, child: Text('schedule')),
              ),
            ],
          ),
        ),
      );

  testWidgets('focuses the first errored field in screen order and buzzes', (
    tester,
  ) async {
    final focus = FormErrorFocus(
      const ['name', 'date', 'endDate'],
      shared: const {'endDate': 'date'},
    );
    addTearDown(focus.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(focus, controller));

    // Validator order is irrelevant; the field higher on screen wins.
    focus.focusFirstError(['endDate', 'name']);
    await tester.pump();

    expect(focus.nodeFor('name').hasFocus, isTrue);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('a key sharing a node focuses that node', (tester) async {
    final focus = FormErrorFocus(
      const ['name', 'date', 'endDate'],
      shared: const {'endDate': 'date'},
    );
    addTearDown(focus.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(focus, controller));

    focus.focusFirstError(['endDate']);
    // The wrapper scrolls into view after a 280 ms delay that schedules no frame.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(identical(focus.nodeFor('endDate'), focus.nodeFor('date')), isTrue);
    expect(focus.nodeFor('date').hasFocus, isTrue);
  });

  test('an unknown key focuses nothing and stays silent', () {
    final focus = FormErrorFocus(const ['name']);
    addTearDown(focus.dispose);

    focus
      ..focusFirstError(['mobile'])
      ..focusFirstError(const []);
    expect(haptics, isEmpty);
  });
}
