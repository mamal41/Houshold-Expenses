// The phone/Windows sync: the three-way merge, and that this device's data
// survives a read -> write round trip unchanged (receipt photos stay local).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:personal_finance/main.dart';
import 'package:personal_finance/sync.dart';

import 'scenario.dart';

Map<String, dynamic> r(String id, num amount) => {'id': id, 'amount': amount};
SyncSnapshot snap(List<Map<String, dynamic>> tx) => {
      'transactions': {for (final t in tx) '${t['id']}': t},
    };

void main() {
  group('merge', () {
    test('first sync keeps both sides and prefers the shared data on a clash', () {
      final m = mergeSnapshots(null, snap([r('a', 1), r('same', 5)]), snap([r('b', 2), r('same', 9)]));
      expect(m['transactions']!.keys.toSet(), {'a', 'b', 'same'});
      expect(m['transactions']!['same']!['amount'], 9);
    });

    test('a new install takes the shared data instead of adding its defaults', () {
      final fresh = {
        'accounts': {'default': {'id': 'default', 'name': 'Main'}},
        'transactions': <String, Map<String, dynamic>>{},
      };
      final shared = {
        'accounts': {'giro': {'id': 'giro', 'name': 'Giro'}},
        'transactions': {'a': r('a', 1)},
      };
      final m = mergeSnapshots(null, fresh, shared);
      expect(m['accounts']!.keys, ['giro']);
      expect(m['transactions']!.keys, ['a']);
    });

    test('a change on one side is taken', () {
      final base = snap([r('a', 1), r('b', 2)]);
      final m = mergeSnapshots(base, snap([r('a', 10), r('b', 2)]), snap([r('a', 1), r('b', 20)]));
      expect(m['transactions']!['a']!['amount'], 10);
      expect(m['transactions']!['b']!['amount'], 20);
    });

    test('a delete on one side is taken, unless the other side changed it', () {
      final base = snap([r('a', 1), r('b', 2)]);
      final m = mergeSnapshots(base, snap([r('b', 2)]), snap([r('a', 1), r('b', 22)]));
      expect(m['transactions']!.containsKey('a'), isFalse); // deleted here
      final m2 = mergeSnapshots(base, snap([r('b', 2)]), snap([r('a', 11), r('b', 2)]));
      expect(m2['transactions']!['a']!['amount'], 11); // changed there beats deleted here
    });

    test('both changed the same record: this device wins', () {
      final base = snap([r('a', 1)]);
      final m = mergeSnapshots(base, snap([r('a', 2)]), snap([r('a', 3)]));
      expect(m['transactions']!['a']!['amount'], 2);
    });

    test('two devices converge', () {
      // Phone and PC each add one, then sync phone, PC, phone.
      var cloud = <String, SyncRecords>{};
      SyncSnapshot? basePhone, basePc;
      var phone = snap([r('p1', 1)]);
      var pc = snap([r('c1', 2)]);
      SyncSnapshot syncOnce(SyncSnapshot? base, SyncSnapshot local) {
        final merged = mergeSnapshots(base, local, cloud);
        cloud = merged;
        return merged;
      }

      phone = basePhone = syncOnce(basePhone, phone);
      pc = basePc = syncOnce(basePc, pc);
      phone = basePhone = syncOnce(basePhone, phone);
      expect(phone['transactions']!.keys.toSet(), {'p1', 'c1'});
      expect(snapshotsEqual(phone, pc), isTrue);
      // A delete on the PC reaches the phone.
      pc = snap([r('p1', 1)]);
      pc = basePc = syncOnce(basePc, pc);
      phone = basePhone = syncOnce(basePhone, phone);
      expect(phone['transactions']!.keys.toSet(), {'p1'});
    });
  });

  test('local data round trip keeps every record and the receipt photo', () async {
    SharedPreferences.setMockInitialValues({});
    final s = buildScenario('EUR');
    final withPhoto = s.tx.first.copyWith(imagePath: '/data/receipt.jpg');
    await Store.saveAccounts(s.accounts);
    await Store.saveTransactions([withPhoto, ...s.tx.skip(1)]);
    await Store.saveBudgetGoals(s.budgetGoals);
    await Store.saveSavingsGoals(s.savingsGoals);
    await Store.saveSavingsContributions(s.contributions);
    final before = await LocalSyncData.read();
    expect(before['transactions']!.length, s.tx.length);
    expect(before['transactions']![withPhoto.id]!.containsKey('imagePath'), isFalse);
    // Write it back as if it came from the other device, with one change.
    final changed = mergeSnapshots(null, before, before);
    changed['transactions']![withPhoto.id] = {...changed['transactions']![withPhoto.id]!, 'note': 'from pc'};
    await LocalSyncData.write(changed, before);
    final after = await LocalSyncData.read();
    expect(snapshotsEqual(after, changed), isTrue);
    final saved = (await Store.loadTransactions()).firstWhere((t) => t.id == withPhoto.id);
    expect(saved.imagePath, '/data/receipt.jpg');
    expect(saved.note, 'from pc');
  });

  test('an edit from the other device is still there after a restart', () async {
    SharedPreferences.setMockInitialValues({});
    Store.forgetLoadedTransactions();
    final s = buildScenario('EUR');
    await Store.saveTransactions(s.tx);
    final before = await LocalSyncData.read();
    final changed = mergeSnapshots(null, before, before);
    final id = s.tx.first.id;
    changed['transactions']![id] = {...changed['transactions']![id]!, 'note': 'edited on the phone'};
    await LocalSyncData.write(changed, before);
    Store.forgetLoadedTransactions(); // as after closing and opening the app
    expect((await Store.loadTransactions()).firstWhere((t) => t.id == id).note, 'edited on the phone');
  });

  test('a changed transaction saved with the whole list is stored', () async {
    SharedPreferences.setMockInitialValues({});
    Store.forgetLoadedTransactions();
    Transaction tx(String note) =>
        Transaction(id: 'a', type: TxType.expense, amount: 1, categoryId: 'c', accountId: 'x', date: DateTime(2026, 1, 1), note: note);
    await Store.saveTransactions([tx('')]);
    await Store.saveTransactions([tx('changed')]);
    Store.forgetLoadedTransactions();
    expect((await Store.loadTransactions()).single.note, 'changed');
  });

  group('receipt photos', () {
    final now = DateTime.utc(2026, 1, 2);
    DriveReceipt f(String name, {int minutesAgo = 120}) =>
        (id: 'id-$name', name: name, txId: receiptTxId(name)!, modified: now.subtract(Duration(minutes: minutesAgo)));
    List<ReceiptAction> plan(Map<String, String?> local, List<DriveReceipt> drive, [Map<String, ReceiptState> state = const {}]) =>
        planReceiptSync(local: local, drive: drive, state: state, now: now);

    test('file names', () {
      expect(receiptFileName('0123456789', 'a-b-c', 'jpg'), 'receipt-0123456789-a-b-c.jpg');
      expect(receiptTxId('receipt-0123456789-a-b-c.jpg'), 'a-b-c');
      expect(receiptTxId('household-finance-sync.json'), isNull);
      expect(receiptContentHash([1, 2, 3]), receiptContentHash([1, 2, 3]));
      expect(receiptContentHash([1, 2, 3]), isNot(receiptContentHash([1, 2, 4])));
    });

    test('a photo here is shared, one only on Drive is downloaded', () {
      final a = plan({'t1': 'k1', 't2': null}, [f('receipt-bbbbbbbbbb-t2.jpg')]);
      expect(a, hasLength(2));
      expect(a[0], isA<ReceiptUpload>().having((u) => u.txId, 'tx', 't1'));
      expect((a[1] as ReceiptDownload).file.name, 'receipt-bbbbbbbbbb-t2.jpg');
    });

    test('nothing moves when both sides match', () {
      expect(plan({'t1': 'k1'}, [f('receipt-cccccccccc-t1.jpg')], {'t1': (key: 'k1', drive: 'receipt-cccccccccc-t1.jpg')}), isEmpty);
    });

    test('a newer photo from the other device is downloaded', () {
      final a = plan(
        {'t1': 'k1'},
        [f('receipt-cccccccccc-t1.jpg', minutesAgo: 60), f('receipt-dddddddddd-t1.jpg', minutesAgo: 5)],
        {'t1': (key: 'k1', drive: 'receipt-cccccccccc-t1.jpg')},
      );
      expect((a.single as ReceiptDownload).file.name, 'receipt-dddddddddd-t1.jpg');
    });

    test('a photo changed here is shared again', () {
      final a = plan({'t1': 'k2'}, [f('receipt-cccccccccc-t1.jpg')], {'t1': (key: 'k1', drive: 'receipt-cccccccccc-t1.jpg')});
      expect(a.single, isA<ReceiptUpload>());
    });

    test('removed here: deleted from Drive; deleted transactions: once an hour old', () {
      final a = plan(
        {'t1': null},
        [f('receipt-cccccccccc-t1.jpg'), f('receipt-cccccccccc-gone.jpg'), f('receipt-dddddddddd-new.jpg', minutesAgo: 2)],
        {'t1': (key: 'k1', drive: 'receipt-cccccccccc-t1.jpg')},
      );
      expect(a.whereType<ReceiptDelete>().map((d) => d.txId).toSet(), {'t1', 'gone'});
    });

    test('a photo the other device removed from Drive stays here', () {
      expect(plan({'t1': 'k1'}, const [], {'t1': (key: 'k1', drive: 'receipt-cccccccccc-t1.jpg')}), isEmpty);
    });
  });

  group('receipt photos between two devices', () {
    late Directory docs;
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => docs.path,
      );
    });

    test('a photo reaches the other device, survives restarts, follows changes', () async {
      final drive = _FakeDrive();
      final phone = _Device();
      final pc = _Device();
      Transaction tx(String id) => Transaction(id: id, type: TxType.expense, amount: 1, categoryId: 'c', accountId: 'x', date: DateTime(2026, 1, 1));
      Future<T> on<T>(_Device d, Future<T> Function() body) async {
        SharedPreferences.setMockInitialValues(d.prefs);
        Store.forgetLoadedTransactions();
        docs = d.docs;
        try {
          return await body();
        } finally {
          final sp = await SharedPreferences.getInstance();
          d.prefs = {for (final k in sp.getKeys()) k: sp.get(k)!};
        }
      }

      Future<({ReceiptSyncStatus status, bool more, bool changed})> sync() =>
          http.runWithClient(() => syncReceiptPhotos('token'), () => MockClient(drive.handle));
      Future<Transaction> t1() async => (await Store.loadTransactions()).firstWhere((t) => t.id == 't1');

      // The phone has a photo for t1.
      late String phonePhoto;
      await on(phone, () async {
        phonePhoto = '${phone.docs.path}/draft_receipts/t1.jpg';
        File(phonePhoto)
          ..createSync(recursive: true)
          ..writeAsBytesSync([1, 2, 3]);
        await Store.saveTransactions([tx('t1').copyWith(imagePath: phonePhoto), tx('t2')]);
        final r = await sync();
        expect(r.status.photos, 1);
        expect(r.status.shared, 1);
      });
      expect(drive.files.values.single.bytes, [1, 2, 3]);

      // The PC has the same transactions without it: it downloads it.
      await on(pc, () async {
        await Store.saveTransactions([tx('t1'), tx('t2')]);
        expect((await sync()).changed, isTrue);
      });
      // After a restart the PC still has it, and nothing moves again.
      await on(pc, () async {
        expect(File((await t1()).imagePath!).readAsBytesSync(), [1, 2, 3]);
        final r = await sync();
        expect(r.changed, isFalse);
        expect(r.status.pending, 0);
      });
      expect(drive.files, hasLength(1));
      // Nothing to do on the phone either.
      await on(phone, () async => expect((await sync()).status.pending, 0));
      expect(drive.uploads, 1);

      // Cropped again on the phone: the PC gets the new one.
      await on(phone, () async {
        File(phonePhoto).writeAsBytesSync([4, 5]);
        await sync();
      });
      expect(drive.files.values.single.bytes, [4, 5]);
      await on(pc, () async {
        await sync();
        expect(File((await t1()).imagePath!).readAsBytesSync(), [4, 5]);
      });

      // Removed on the PC: gone from Drive, still on the phone.
      await on(pc, () async {
        final list = await Store.loadTransactions();
        await Store.saveTransactions([for (final t in list) t.id == 't1' ? t.copyWith(clearImagePath: true) : t]);
        await sync();
      });
      expect(drive.files, isEmpty);
      await on(phone, () async {
        await sync();
        expect((await t1()).imagePath, phonePhoto);
        expect(File(phonePhoto).existsSync(), isTrue);
      });
      expect(drive.files, isEmpty);
    });
  });
}

class _Device {
  Map<String, Object> prefs = {};
  final Directory docs = Directory.systemTemp.createTempSync('device');
}

/// Google Drive's hidden app folder, as far as the photo sync uses it.
class _FakeDrive {
  final files = <String, ({String name, List<int> bytes, DateTime modified})>{};
  final _sessions = <String, String>{};
  var _n = 0;
  var uploads = 0;

  Future<http.Response> handle(http.Request r) async {
    final path = r.url.path;
    if (r.method == 'GET' && path == '/drive/v3/files') {
      expect(r.url.queryParameters['spaces'], 'appDataFolder');
      return http.Response(
          jsonEncode({
            'files': [
              for (final e in files.entries) {'id': e.key, 'name': e.value.name, 'modifiedTime': e.value.modified.toUtc().toIso8601String()}
            ]
          }),
          200);
    }
    if (r.method == 'POST' && path == '/upload/drive/v3/files' && r.url.queryParameters['uploadType'] == 'resumable') {
      final meta = jsonDecode(r.body) as Map<String, dynamic>;
      expect(meta['parents'], ['appDataFolder']);
      final id = 's${_n++}';
      _sessions[id] = '${meta['name']}';
      return http.Response('', 200, headers: {'location': 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=$id'});
    }
    final session = r.url.queryParameters['upload_id'];
    if (r.method == 'PUT' && session != null) {
      uploads++;
      files['f${_n++}'] = (name: _sessions.remove(session)!, bytes: r.bodyBytes, modified: DateTime.now());
      return http.Response('{}', 200);
    }
    final m = RegExp(r'^/drive/v3/files/([^/]+)$').firstMatch(path);
    if (m != null && r.method == 'GET') {
      final f = files[m[1]];
      return f == null ? http.Response('', 404) : http.Response.bytes(f.bytes, 200);
    }
    if (m != null && r.method == 'DELETE') return http.Response('', files.remove(m[1]) == null ? 404 : 204);
    fail('unexpected ${r.method} ${r.url}');
  }
}
