// Automatic backups: daily means once a calendar day, and only the newest
// kAutoBackupsKept files are kept.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  setUp(() {
    docs = Directory.systemTemp.createTempSync('backups');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => docs.path,
    );
    SharedPreferences.setMockInitialValues({});
    Store.forgetLoadedTransactions();
  });

  test('off: nothing unless asked; daily: once a day', () async {
    expect(await maybeRunAutoBackup(), isFalse);
    expect(await maybeRunAutoBackup(force: true), isTrue);
    await Store.saveAutoBackupFrequency(AutoBackupFrequency.daily);
    // Made today already: not again today.
    expect(await maybeRunAutoBackup(), isFalse);
    // Last one yesterday: due.
    await Store.saveLastAutoBackupAt(DateTime.now().subtract(const Duration(days: 1)));
    expect(await maybeRunAutoBackup(), isTrue);
    expect(await listAutoBackups(), hasLength(2));
  });

  test('only the newest $kAutoBackupsKept are kept', () async {
    final dir = Directory('${docs.path}${Platform.pathSeparator}auto_backups')..createSync(recursive: true);
    final base = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    for (var i = 0; i < kAutoBackupsKept + 5; i++) {
      File('${dir.path}${Platform.pathSeparator}backup_${base + i * 1000}.json').writeAsStringSync('{}');
    }
    expect(await maybeRunAutoBackup(force: true), isTrue);
    final kept = await listAutoBackups();
    expect(kept, hasLength(kAutoBackupsKept));
    // The new one first, the oldest ones gone.
    expect(autoBackupTime(kept.first)!.isAfter(DateTime(2026, 1, 2)), isTrue);
    expect(kept.any((f) => f.path.endsWith('backup_$base.json')), isFalse);
  });
}
