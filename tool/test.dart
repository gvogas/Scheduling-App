import 'dart:io';

// `flutter test` compiles every test file separately through one compiler, so
// the suite was ~1.4 s per file of serial compilation. Bundling the files into
// a few shards compiles each shard once and still runs the shards in parallel.
const _shardCount = 6;
const _shardDir = 'build/test_shards';

Future<void> main(List<String> args) async {
  final files =
      Directory('test')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll(r'\', '/'))
          .where((p) => p.endsWith('_test.dart'))
          .toList()
        ..sort();

  final weighted = [for (final f in files) (path: f, weight: _weight(f))]
    ..sort((a, b) => b.weight.compareTo(a.weight));
  final shards = List.generate(_shardCount, (_) => <String>[]);
  final loads = List.filled(_shardCount, 0);
  for (final f in weighted) {
    final i = loads.indexOf(loads.reduce((a, b) => a < b ? a : b));
    shards[i].add(f.path);
    loads[i] += f.weight;
  }

  final dir = Directory(_shardDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  for (var i = 0; i < _shardCount; i++) {
    final paths = shards[i]..sort();
    final out = StringBuffer();
    for (var j = 0; j < paths.length; j++) {
      out.writeln("import '../../${paths[j]}' as t$j;");
    }
    out
      ..writeln(
        "import 'package:flutter_secure_storage/flutter_secure_storage.dart';",
      )
      ..writeln("import 'package:flutter_test/flutter_test.dart';")
      ..writeln("import 'package:shared_preferences/shared_preferences.dart';")
      ..writeln()
      ..writeln('void main() {');
    // Files share an isolate now, so reset the plugin mocks each file reads to
    // the same empty store before it starts, wherever it lands in a shard.
    for (var j = 0; j < paths.length; j++) {
      out
        ..writeln("  group('${paths[j].substring(5)}', () {")
        ..writeln('    setUpAll(() {')
        ..writeln('      SharedPreferences.setMockInitialValues({});')
        ..writeln('      FlutterSecureStorage.setMockInitialValues({});')
        ..writeln('    });')
        ..writeln('    t$j.main();')
        ..writeln('  });');
    }
    out.writeln('}');
    File('$_shardDir/shard_${i}_test.dart').writeAsStringSync(out.toString());
  }

  final process = await Process.start(
    'flutter',
    ['test', ...args, _shardDir],
    mode: ProcessStartMode.inheritStdio,
    runInShell: true,
  );
  exit(await process.exitCode);
}

/// Widget tests cost far more than unit tests, so they dominate shard balance.
int _weight(String path) {
  final source = File(path).readAsStringSync();
  return 1 +
      10 * 'testWidgets('.allMatches(source).length +
      'test('.allMatches(source).length;
}
