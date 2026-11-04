import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../logic/settle.dart';

typedef DbRow = Map<String, Object?>;

/// Raised when a UTR or the exact same screenshot was already recorded.
class DuplicateException implements Exception {
  final String message;
  DuplicateException(this.message);
  @override
  String toString() => message;
}

class Ledger {
  final List<DbRow> members; // includes archived members (history keeps their names)
  final Map<int, int> net;
  final List<Transfer> transfers;
  final int kittyBalance; // paise left in kitty
  Ledger(this.members, this.net, this.transfers, this.kittyBalance);

  /// Active members, plus archived ones that still have a non-zero balance.
  List<DbRow> get visible => members.where((m) => m['active'] == 1 || (net[m['id']] ?? 0) != 0).toList();
  List<DbRow> get active => members.where((m) => m['active'] == 1).toList();

  String nameOf(int id) => id == kittyId
      ? 'Kitty'
      : (members.firstWhere((m) => m['id'] == id, orElse: () => {'name': '?'})['name'] as String);
}

class Repo {
  static Database? _db;
  static Future<Database> get db async => _db ??= await _open();

  /// Bumped after every write. Screens listen to it, so balances refresh everywhere
  /// (including after a proof arrives through the Android Share Sheet).
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static void _bump() => changes.value++;

  static Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'spliteasy.db');
    return openDatabase(path, version: 1, onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, v) async {
      await d.execute('CREATE TABLE grp(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kitty INTEGER NOT NULL DEFAULT 0)');
      // active=0 means "removed": hidden from pickers but kept so old expenses still show the name.
      await d.execute('CREATE TABLE member(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, name TEXT NOT NULL, upi_id TEXT, active INTEGER NOT NULL DEFAULT 1)');
      await d.execute('CREATE TABLE expense(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, title TEXT NOT NULL, amount INTEGER NOT NULL, category TEXT, note TEXT, split_type TEXT, proof_path TEXT, date INTEGER NOT NULL)');
      await d.execute('CREATE TABLE payer(expense_id INTEGER NOT NULL REFERENCES expense(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY(expense_id, member_id))');
      await d.execute('CREATE TABLE share(expense_id INTEGER NOT NULL REFERENCES expense(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY(expense_id, member_id))');
      // ref = 12-digit UTR (or PhonePe txn id); proof_hash = fingerprint of the screenshot file.
      // Both UNIQUE: duplicates are blocked at the database layer even if app logic is bypassed.
      await d.execute('CREATE TABLE settlement(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, amount INTEGER NOT NULL, ref TEXT UNIQUE, proof_hash TEXT UNIQUE, method TEXT, status TEXT NOT NULL, proof_path TEXT, note TEXT, date INTEGER NOT NULL)');
      await d.execute('CREATE TABLE topup(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, date INTEGER NOT NULL)');
    });
  }

  // ---- groups ----
  static Future<List<DbRow>> groups() async => (await db).query('grp', orderBy: 'id DESC');
  static Future<int> addGroup(String name, bool kitty) async {
    final id = await (await db).insert('grp', {'name': name, 'kitty': kitty ? 1 : 0});
    _bump();
    return id;
  }

  static Future<void> renameGroup(int id, String name) async {
    await (await db).update('grp', {'name': name}, where: 'id=?', whereArgs: [id]);
    _bump();
  }

  static Future<void> deleteGroup(int id) async {
    await (await db).delete('grp', where: 'id=?', whereArgs: [id]);
    _bump();
  }

  // ---- members ----
  static Future<List<DbRow>> members(int gid, {bool all = false}) async => (await db).query('member',
      where: all ? 'group_id=?' : 'group_id=? AND active=1', whereArgs: [gid], orderBy: 'id');

  static Future<int> addMember(int gid, String name, String? upi) async {
    final id = await (await db).insert('member',
        {'group_id': gid, 'name': name, 'upi_id': (upi == null || upi.trim().isEmpty) ? null : upi.trim()});
    _bump();
    return id;
  }

  static Future<void> updateMember(int id, String name, String? upi) async {
    await (await db).update('member', {'name': name, 'upi_id': (upi == null || upi.trim().isEmpty) ? null : upi.trim()},
        where: 'id=?', whereArgs: [id]);
    _bump();
  }

  /// Soft-remove. Caller must make sure the member's balance is zero first.
  static Future<void> archiveMember(int id) async {
    await (await db).update('member', {'active': 0}, where: 'id=?', whereArgs: [id]);
    _bump();
  }

  // ---- expenses ----
  static Future<List<DbRow>> expenses(int gid) async =>
      (await db).query('expense', where: 'group_id=?', whereArgs: [gid], orderBy: 'date DESC, id DESC');

  static Future<void> _writeParts(Transaction tx, int id, Map<int, int> payers, Map<int, int> shares) async {
    for (final p in payers.entries) {
      await tx.insert('payer', {'expense_id': id, 'member_id': p.key, 'amount': p.value});
    }
    for (final s in shares.entries) {
      await tx.insert('share', {'expense_id': id, 'member_id': s.key, 'amount': s.value});
    }
  }

  static Future<int> addExpense(DbRow e, Map<int, int> payers, Map<int, int> shares) async {
    final d = await db;
    final id = await d.transaction((tx) async {
      final id = await tx.insert('expense', e);
      await _writeParts(tx, id, payers, shares);
      return id;
    });
    _bump();
    return id;
  }

  static Future<void> updateExpense(int id, DbRow e, Map<int, int> payers, Map<int, int> shares) async {
    final d = await db;
    await d.transaction((tx) async {
      await tx.update('expense', e, where: 'id=?', whereArgs: [id]);
      await tx.delete('payer', where: 'expense_id=?', whereArgs: [id]);
      await tx.delete('share', where: 'expense_id=?', whereArgs: [id]);
      await _writeParts(tx, id, payers, shares);
    });
    _bump();
  }

  static Future<void> deleteExpense(int id) async {
    await (await db).delete('expense', where: 'id=?', whereArgs: [id]); // payer/share rows cascade
    _bump();
  }

  static Future<Map<int, int>> sharesOf(int expenseId) async {
    final r = await (await db).query('share', where: 'expense_id=?', whereArgs: [expenseId]);
    return {for (final s in r) s['member_id'] as int: s['amount'] as int};
  }

  static Future<Map<int, int>> payersOf(int expenseId) async {
    final r = await (await db).query('payer', where: 'expense_id=?', whereArgs: [expenseId]);
    return {for (final s in r) s['member_id'] as int: s['amount'] as int};
  }

  // ---- settlements ----
  static Future<List<DbRow>> settlements(int gid) async =>
      (await db).query('settlement', where: 'group_id=?', whereArgs: [gid], orderBy: 'date DESC, id DESC');

  static Future<bool> _exists(String col, String val) async =>
      (await (await db).query('settlement', columns: ['id'], where: '$col=?', whereArgs: [val], limit: 1)).isNotEmpty;

  static Future<bool> hashExists(String hash) => _exists('proof_hash', hash);

  /// Throws [DuplicateException] if the UTR or the same screenshot was already registered.
  static Future<int> addSettlement({
    required int gid,
    required int from,
    required int to,
    required int amount,
    String? ref,
    String? proofHash,
    String method = 'manual',
    String status = 'manual',
    String? proofPath,
    String? note,
    DateTime? when,
  }) async {
    final d = await db;
    final r = (ref == null || ref.isEmpty) ? null : ref;
    if (r != null && await _exists('ref', r)) throw DuplicateException('Transaction $r is already recorded');
    if (proofHash != null && await hashExists(proofHash)) {
      throw DuplicateException('This exact screenshot was already uploaded');
    }
    try {
      final id = await d.insert('settlement', {
        'group_id': gid, 'from_id': from, 'to_id': to, 'amount': amount,
        'ref': r, 'proof_hash': proofHash, 'method': method, 'status': status,
        'proof_path': proofPath, 'note': note,
        'date': (when ?? DateTime.now()).millisecondsSinceEpoch,
      });
      _bump();
      return id;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) throw DuplicateException('This payment was already recorded');
      rethrow;
    }
  }

  static Future<void> deleteSettlement(int id) async {
    await (await db).delete('settlement', where: 'id=?', whereArgs: [id]);
    _bump();
  }

  // ---- kitty ----
  static Future<void> addTopup(int gid, int memberId, int amount) async {
    await (await db).insert(
        'topup', {'group_id': gid, 'member_id': memberId, 'amount': amount, 'date': DateTime.now().millisecondsSinceEpoch});
    _bump();
  }

  // ---- ledger ----
  /// Always recomputed from raw rows, so edits/deletes can never leave stale balances.
  static Future<Ledger> ledger(int gid, {required bool kitty}) async {
    final d = await db;
    final ms = await members(gid, all: true);
    final ex = await expenses(gid);
    final sh = await d.rawQuery('SELECT s.* FROM share s JOIN expense e ON e.id=s.expense_id WHERE e.group_id=?', [gid]);
    final py = await d.rawQuery('SELECT p.* FROM payer p JOIN expense e ON e.id=p.expense_id WHERE e.group_id=?', [gid]);
    final shareMap = <int, Map<int, int>>{};
    for (final s in sh) {
      (shareMap[s['expense_id'] as int] ??= {})[s['member_id'] as int] = s['amount'] as int;
    }
    final payMap = <int, Map<int, int>>{};
    for (final p in py) {
      (payMap[p['expense_id'] as int] ??= {})[p['member_id'] as int] = p['amount'] as int;
    }
    final expData = ex
        .map((e) => ExpenseData(payMap[e['id']] ?? {}, e['amount'] as int, shareMap[e['id']] ?? {}))
        .toList();
    final st = (await settlements(gid))
        .map((s) => SettlementData(s['from_id'] as int, s['to_id'] as int, s['amount'] as int))
        .toList();
    final tp = (await d.query('topup', where: 'group_id=?', whereArgs: [gid]))
        .map((t) => TopupData(t['member_id'] as int, t['amount'] as int))
        .toList();
    final net = computeNet(ms.map((m) => m['id'] as int).toList(), expData, st, tp, kitty: kitty);
    final kb = kitty ? -(net[kittyId] ?? 0) : 0;
    return Ledger(ms, net, simplify(net), kb);
  }
}
