import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spliteasy/data/repo.dart';

Future<String> _dbPath() async => join(await getDatabasesPath(), 'spliteasy.db');

Future<void> _wipe() async {
  await Repo.closeForTest();
  final f = File(await _dbPath());
  if (f.existsSync()) f.deleteSync();
}

/// A database exactly as the released Stage 2a app (schema v3) would have created it.
Future<void> _makeV3() async {
  final d = await openDatabase(await _dbPath(), version: 3, onCreate: (d, v) async {
    await d.execute('CREATE TABLE grp(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kitty INTEGER NOT NULL DEFAULT 0, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
    await d.execute('CREATE TABLE member(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, name TEXT NOT NULL, upi_id TEXT, active INTEGER NOT NULL DEFAULT 1, phone TEXT, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
    await d.execute('CREATE TABLE expense(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, title TEXT NOT NULL, amount INTEGER NOT NULL, category TEXT, note TEXT, split_type TEXT, proof_path TEXT, date INTEGER NOT NULL, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
    await d.execute('CREATE TABLE payer(expense_id INTEGER NOT NULL REFERENCES expense(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY(expense_id, member_id))');
    await d.execute('CREATE TABLE share(expense_id INTEGER NOT NULL REFERENCES expense(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY(expense_id, member_id))');
    await d.execute('CREATE TABLE settlement(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, amount INTEGER NOT NULL, ref TEXT UNIQUE, proof_hash TEXT UNIQUE, method TEXT, status TEXT NOT NULL, proof_path TEXT, note TEXT, date INTEGER NOT NULL, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
    await d.execute('CREATE TABLE topup(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, date INTEGER NOT NULL, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
    await d.insert('grp', {'name': 'Travel', 'kitty': 0, 'uid': 'g-1', 'updated_at': 1});
    for (final n in ['priya', 'Roshan', 'Nethra']) {
      await d.insert('member', {'group_id': 1, 'name': n, 'uid': 'm-$n', 'updated_at': 1});
    }
    await d.insert('expense', {'group_id': 1, 'title': 'petrol', 'amount': 350000, 'split_type': 'equal', 'date': 5, 'uid': 'e-1', 'updated_at': 1});
    await d.insert('payer', {'expense_id': 1, 'member_id': 1, 'amount': 350000});
    for (final e in {1: 116667, 2: 116667, 3: 116666}.entries) {
      await d.insert('share', {'expense_id': 1, 'member_id': e.key, 'amount': e.value});
    }
    await d.insert('settlement', {'group_id': 1, 'from_id': 2, 'to_id': 1, 'amount': 50000, 'ref': '123456789012', 'method': 'upi', 'status': 'manual', 'date': 6, 'uid': 's-1', 'updated_at': 1});
  });
  await d.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(_wipe);
  tearDownAll(_wipe);

  test('upgrade from v3 keeps all data and balances, and adds the new tables', () async {
    await _makeV3();
    final d = await Repo.db; // opening runs the v3 -> v4 upgrade
    expect(await d.getVersion(), 4);
    expect((await Repo.groups()).single['name'], 'Travel');
    expect((await Repo.members(1)).length, 3);
    expect((await Repo.expenses(1)).single['title'], 'petrol');
    final l = await Repo.ledger(1, kitty: false);
    expect(l.net[1], 350000 - 116667 - 50000); // priya paid 3500, own share 1166.67, Roshan paid her 500
    expect(l.net[2], 50000 - 116667);
    expect(l.net[3], -116666);
    expect((await d.query('outbox')), isEmpty);
    expect((await d.query('expense', columns: ['deleted_at'])).single['deleted_at'], isNull);
  });

  test('deleting an expense keeps the row, changes balances, and queues a delete', () async {
    await _makeV3();
    await Repo.deleteExpense(1);
    final d = await Repo.db;
    expect(await Repo.expenses(1), isEmpty);
    expect((await d.query('expense')).single['deleted_at'], isNotNull);
    final l = await Repo.ledger(1, kitty: false);
    expect(l.net[1], -50000); // only Roshan's payment to priya remains
    final q = await Repo.outbox();
    expect(q.single['action'], 'delete');
    expect(q.single['rec_uid'], 'e-1');
  });

  test('deleting a payment frees its UTR so it can be recorded again', () async {
    await _makeV3();
    await expectLater(Repo.addSettlement(gid: 1, from: 3, to: 1, amount: 100, ref: '123456789012'),
        throwsA(isA<DuplicateException>()));
    await Repo.deleteSettlement(1);
    expect(await Repo.settlements(1), isEmpty);
    await Repo.addSettlement(gid: 1, from: 3, to: 1, amount: 100, ref: '123456789012');
    expect((await Repo.settlements(1)).length, 1);
  });

  test('every write queues one change in order, with uids instead of local ids', () async {
    final gid = await Repo.addGroup('Trip', false);
    final a = await Repo.addMember(gid, 'A', null);
    final b = await Repo.addMember(gid, 'B', null, phone: '+919876543210');
    await Repo.addExpense(
        {'group_id': gid, 'title': 'tea', 'amount': 1000, 'split_type': 'equal', 'date': 1}, {a: 1000}, {a: 500, b: 500});
    await Repo.addSettlement(gid: gid, from: b, to: a, amount: 500, ref: '999999999999');
    await Repo.renameGroup(gid, 'Trip 2');
    await Repo.archiveMember(b);
    final q = await Repo.outbox();
    expect(q.map((r) => '${r['tbl']}:${r['action']}').toList(),
        ['grp:upsert', 'member:upsert', 'member:upsert', 'expense:upsert', 'settlement:upsert', 'grp:upsert', 'member:upsert']);
    final exp = jsonDecode(q[3]['payload'] as String) as Map<String, dynamic>;
    final gUid = (await Repo.groups()).single['uid'];
    final ms = await Repo.members(gid, all: true);
    expect(exp['group_uid'] ?? exp['group_id'], gUid); // group reference is the uid, not the local id
    expect((exp['payers'] as Map).keys.single, ms.first['uid']);
    expect((exp['shares'] as Map).keys.toSet(), ms.map((m) => m['uid']).toSet());
    expect(exp.containsKey('id'), isFalse);
  });

  test('deleting a group hides it and frees its payment references', () async {
    await _makeV3();
    await Repo.deleteGroup(1);
    expect(await Repo.groups(), isEmpty);
    final gid = await Repo.addGroup('Other', false);
    final m = await Repo.addMember(gid, 'X', null);
    final n = await Repo.addMember(gid, 'Y', null);
    await Repo.addSettlement(gid: gid, from: m, to: n, amount: 1, ref: '123456789012');
    expect((await Repo.outbox()).where((r) => r['action'] == 'delete' && r['tbl'] == 'grp').length, 1);
  });
}
