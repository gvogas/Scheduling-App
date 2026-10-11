import 'dart:io';

typedef RuleViolation = ({String rule, String path, int line, String text});

const _firestoreInstanceAllowed = {
  'lib/core/providers/firebase_providers.dart',
  'lib/main.dart',
  'lib/features/auth/services/auth_service.dart',
};

bool _isGenerated(String path) =>
    path.startsWith('lib/l10n/.gen/') ||
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart');

List<RuleViolation> scanRules(Map<String, String> files) {
  final out = <RuleViolation>[];
  final paths = files.keys.toList()..sort();
  for (final path in paths) {
    if (_isGenerated(path)) continue;
    final lines = files[path]!.split('\n');
    final inUi = path.contains('/widgets/') || path.contains('/screens/');
    var catchDepth = 0;
    var catchOpened = false;
    var inCatch = false;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i];
      void hit(String rule) =>
          out.add((rule: rule, path: path, line: i + 1, text: text.trim()));
      if (text.contains('package:firebase_analytics/') &&
          path != 'lib/core/analytics/analytics_service.dart') {
        hit('analytics-import');
      }
      if (text.contains('FirebaseFirestore.instance') &&
          !_firestoreInstanceAllowed.contains(path)) {
        hit('firestore-instance');
      }
      if (text.contains('as Map<String, dynamic>?')) hit('strict-map-cast');
      if (inUi && RegExp(r'\bTimer(\.periodic)?\(').hasMatch(text)) {
        hit('widget-timer');
      }
      var scanFrom = 0;
      final catchMatch = RegExp(
        r'\bcatch\s*\(|\.catchError\(',
      ).firstMatch(text);
      if (!inCatch && catchMatch != null) {
        inCatch = true;
        catchDepth = 0;
        catchOpened = false;
        scanFrom = catchMatch.start;
      }
      if (inCatch) {
        final rest = text.substring(scanFrom);
        final bodyStart = catchOpened ? 0 : rest.indexOf('{');
        if (bodyStart >= 0 && rest.substring(bodyStart).contains('ref.read(')) {
          hit('ref-read-in-catch');
        }
        for (final ch in rest.split('')) {
          if (ch == '{') {
            catchDepth++;
            catchOpened = true;
          } else if (ch == '}') {
            catchDepth--;
          }
        }
        if (catchOpened && catchDepth <= 0) inCatch = false;
      }
    }
  }
  return out;
}

void main() {
  final files = <String, String>{
    for (final f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart'))
        f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
  };
  final violations = scanRules(files);
  for (final v in violations) {
    stdout.writeln('${v.path}:${v.line}: [${v.rule}] ${v.text}');
  }
  stdout.writeln('${violations.length} rule violation(s).');
  if (violations.isNotEmpty) exitCode = 1;
}
