import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spliteasy/data/repo.dart';
import 'package:spliteasy/sync/sqlite_store.dart';
import 'package:spliteasy/sync/sync_engine.dart';
import 'helpers/sync_fakes.dart';

Future<void> _wipe() async {
  await Repo.closeForTest();
  final f = File(join(await getDatabasesPath(), 'spliteasy.db'));
  if (f.existsSync()) f.deleteSync();
}

/// Phone A: a group with 3 people, one expense, one payment.
Future<({String gUid, Map<String, int> netByName})> _buildOnPhoneA() async {
  final gid = await Repo.addGroup('Travel', false);
  final p = await Repo.addMember(gid, 'priya', null);
  final r = await Repo.addMember(gid, 'Roshan', null, phone: '+919500346257');
  final n = await Repo.addMember(gid, 'Nethra', null);
  await Repo.addExpense({'group_id': gid, 'title': 'petrol', 'amount': 350000, 'split_type': 'equal', 'date': 5},
      {p: 350000}, {p: 116667, r: 116667, n: 116666});
  await Repo.addSettlement(gid: gid, from: r, to: p, amount: 50000, ref: '123456789012', method: 'upi');
  final gUid = await Repo.shareGroupLocally(gid, 'authA');
  final l = await Repo.ledger(gid, kitty: false);
  return (gUid: gUid, netByName: {for (final m in l.members) m['name'] as String: l.net[m['id']] ?? 0});
}

Future<Map<String, int>> _netsOfFirstGroup() async {
  final g = (await Repo.groups()).single;
  final l = await Repo.ledger(g['id'] as int, kitty: false);
  return {for (final m in l.members) m['name'] as String: l.net[m['id']] ?? 0};
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(_wipe);
  tearDownAll(_wipe);

  test('a shared group built on phone A appears identically on a fresh phone B', () async {
    final relay = MemoryBackend();
    final a = await _buildOnPhoneA();
    final res = await SyncEngine.run(SqliteSyncStore(a.gUid, 'authA'), relay);
    expect(res.offline, isFalse);
    expect(res.pushed, greaterThan(5));
    expect(await Repo.unsentFor(a.gUid), isEmpty);

    await _wipe(); // phone B starts empty
    final rb = await SyncEngine.run(SqliteSyncStore(a.gUid, 'authB'), relay);
    expect(rb.applied, res.pushed);
    expect(await _netsOfFirstGroup(), a.netByName);
    expect((await Repo.groups()).single['shared'], 1);
    expect((await Repo.members((await Repo.groups()).single['id'] as int)).map((m) => m['name']).toSet(), {'priya', 'Roshan', 'Nethra'});
  });

  test('same result when the changes arrive in reverse order (children before parents)', () async {
    final relay = MemoryBackend();
    final a = await _buildOnPhoneA();
    await SyncEngine.run(SqliteSyncStore(a.gUid, 'authA'), relay);
    final reversed = MemoryBackend()..log.addAll(relay.log.reversed);
    await _wipe();
    await SyncEngine.run(SqliteSyncStore(a.gUid, 'authB'), reversed);
    expect(await _netsOfFirstGroup(), a.netByName);
    final g = (await Repo.groups()).single;
    expect(g['name'], 'Travel'); // the placeholder name was replaced by the real one
    expect((await Repo.members(g['id'] as int)).any((m) => m['name'] == '?'), isFalse);
  });

  test('a replayed or repeated sync changes nothing', () async {
    final relay = MemoryBackend();
    final a = await _buildOnPhoneA();
    await SyncEngine.run(SqliteSyncStore(a.gUid, 'authA'), relay);
    await _wipe();
    final b = SqliteSyncStore(a.gUid, 'authB');
    await SyncEngine.run(b, relay);
    relay.log.addAll(List.of(relay.log)); // everything delivered twice
    final again = await SyncEngine.run(b, relay);
    expect(again.applied, 0);
    expect(await _netsOfFirstGroup(), a.netByName);
  });

  test('a delete made on one phone reaches the other and balances follow', () async {
    final relay = MemoryBackend();
    final a = await _buildOnPhoneA();
    final sa = SqliteSyncStore(a.gUid, 'authA');
    await SyncEngine.run(sa, relay);
    final gid = (await Repo.groups()).single['id'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await Repo.deleteExpense((await Repo.expenses(gid)).single['id'] as int);
    await SyncEngine.run(sa, relay);
    final deletedNets = await _netsOfFirstGroup();

    await _wipe();
    await SyncEngine.run(SqliteSyncStore(a.gUid, 'authB'), relay);
    expect(await _netsOfFirstGroup(), deletedNets);
    expect(deletedNets['priya'], -50000); // only Roshan's payment to priya remains
  });

  test('the same payment recorded on two phones is counted once on both', () async {
    final relay = MemoryBackend();
    final a = await _buildOnPhoneA(); // A recorded UTR 123456789012 (Roshan -> priya)
    await SyncEngine.run(SqliteSyncStore(a.gUid, 'authA'), relay);
    final groupId = (await Repo.groups()).single['id'] as int;
    final ms = await Repo.members(groupId);
    final idOf = {for (final m in ms) m['name'] as String: m['id'] as int};

    // phone B (separate record, same UTR) is simulated by a hand-made change from another phone
    final dup = SyncOp(
        opId: 'dup-1',
        table: 'settlement',
        recUid: 'ffffffff-ffff-4fff-8fff-ffffffffffff', // sorts after phone A's uid, so it loses
        action: 'upsert',
        payload: {
          'group_id': a.gUid, 'from_id': (await Repo.memberUid(idOf['Roshan']!)), 'to_id': (await Repo.memberUid(idOf['priya']!)),
          'amount': 50000, 'ref': '123456789012', 'proof_hash': null, 'method': 'upi', 'status': 'manual', 'note': null,
          'date': 7, 'uid': 'ffffffff-ffff-4fff-8fff-ffffffffffff', 'updated_at': 99999999999999,
        },
        updatedAt: 99999999999999,
        origin: 'authB');
    await Repo.applyRemote(dup);
    expect((await Repo.settlements(groupId)).length, 1, reason: 'the duplicate must not count');
    expect(await _netsOfFirstGroup(), a.netByName);
  });

  test('changes of private groups are never part of a shared group\'s queue', () async {
    final shared = await Repo.addGroup('Shared', false);
    final priv = await Repo.addGroup('Private', false);
    await Repo.addMember(priv, 'secret', null);
    final sUid = await Repo.shareGroupLocally(shared, 'authA');
    final q = await Repo.unsentFor(sUid);
    expect(q.every((r) => r['grp_uid'] == sUid), isTrue);
    expect(q.length, 1); // only the group itself
  });
}
