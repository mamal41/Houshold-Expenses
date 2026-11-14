// The phone/Windows sync: the three-way merge, and that this device's data
// survives a read -> write round trip unchanged (receipt photos stay local).
import 'package:flutter_test/flutter_test.dart';
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
}
