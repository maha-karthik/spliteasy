import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../logic/ids.dart';
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

  static const _synced = ['grp', 'member', 'expense', 'settlement', 'topup'];
  static int _now() => DateTime.now().millisecondsSinceEpoch;
  static const _deletable = ['grp', 'expense', 'settlement'];

  /// outbox: every change made on this phone, waiting to be sent (sent_at stays NULL until then).
  /// applied_ops: ids of changes already applied here, so a replayed change is never applied twice.
  /// sync_meta: small key/value store (the pull cursor).
  static Future<void> _syncTables(Database d) async {
    await d.execute('CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE, tbl TEXT NOT NULL, rec_uid TEXT NOT NULL, action TEXT NOT NULL, payload TEXT NOT NULL, updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL, sent_at INTEGER)');
    await d.execute('CREATE TABLE IF NOT EXISTS applied_ops(op_id TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)');
    await d.execute('CREATE TABLE IF NOT EXISTS sync_meta(k TEXT PRIMARY KEY, v TEXT)');
  }

  static Future<void> _uidIndexes(Database d) async {
    for (final t in _synced) {
      await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_${t}_uid ON $t(uid)');
    }
  }

  static Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'spliteasy.db');
    return openDatabase(path, version: 4, onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: (d, oldV, newV) async {
          // v1 -> v2: members can carry a mobile number (normalised E.164, optional).
          if (oldV < 2) await d.execute('ALTER TABLE member ADD COLUMN phone TEXT');
          if (oldV < 3) {
            // v2 -> v3: every synced record gets a globally unique id and a last-changed time.
            final now = _now();
            for (final t in _synced) {
              await d.execute('ALTER TABLE $t ADD COLUMN uid TEXT');
              await d.execute('ALTER TABLE $t ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
              for (final r in await d.query(t, columns: ['id'])) {
                await d.update(t, {'uid': newUid(), 'updated_at': now}, where: 'id=?', whereArgs: [r['id']]);
              }
            }
            await _uidIndexes(d);
          }
          if (oldV < 4) {
            // v3 -> v4: delete markers on records that can be deleted, plus the sync tables.
            for (final t in _deletable) {
              await d.execute('ALTER TABLE $t ADD COLUMN deleted_at INTEGER');
            }
            await _syncTables(d);
          }
        },
        onCreate: (d, v) async {
      await d.execute('CREATE TABLE grp(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kitty INTEGER NOT NULL DEFAULT 0, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER)');
      // active=0 means "removed": hidden from pickers but kept so old expenses still show the name.
      await d.execute('CREATE TABLE member(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, name TEXT NOT NULL, upi_id TEXT, active INTEGER NOT NULL DEFAULT 1, phone TEXT, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
      await d.execute('CREATE TABLE expense(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, title TEXT NOT NULL, amount INTEGER NOT NULL, category TEXT, note TEXT, split_type TEXT, proof_path TEXT, date INTEGER NOT NULL, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER)');
      await d.execute('CREATE TABLE payer(expense_id INTEGER NOT NULL REFERENCES expense(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY(expense_id, member_id))');
      await d.execute('CREATE TABLE share(expense_id INTEGER NOT NULL REFERENCES expense(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY(expense_id, member_id))');
      // ref = 12-digit UTR (or PhonePe txn id); proof_hash = fingerprint of the screenshot file.
      // Both UNIQUE: duplicates are blocked at the database layer even if app logic is bypassed.
      await d.execute('CREATE TABLE settlement(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, amount INTEGER NOT NULL, ref TEXT UNIQUE, proof_hash TEXT UNIQUE, method TEXT, status TEXT NOT NULL, proof_path TEXT, note TEXT, date INTEGER NOT NULL, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER)');
      await d.execute('CREATE TABLE topup(id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES grp(id) ON DELETE CASCADE, member_id INTEGER NOT NULL, amount INTEGER NOT NULL, date INTEGER NOT NULL, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0)');
      await _uidIndexes(d);
      await _syncTables(d);
    });
  }


  // ---- outbox (every write below also queues a change, in the same database transaction) ----
  static Future<String> _memberUid(DatabaseExecutor x, int id) async {
    if (id == kittyId) return 'kitty';
    final r = await x.query('member', columns: ['uid'], where: 'id=?', whereArgs: [id], limit: 1);
    return r.isEmpty ? '' : r.first['uid'] as String;
  }

  static Future<String> _groupUid(DatabaseExecutor x, int id) async {
    final r = await x.query('grp', columns: ['uid'], where: 'id=?', whereArgs: [id], limit: 1);
    return r.isEmpty ? '' : r.first['uid'] as String;
  }

  /// The record as plain data for other phones: local integer ids are replaced by uids.
  static Future<Map<String, Object?>> _wire(DatabaseExecutor x, String table, DbRow r) async {
    final w = <String, Object?>{...r}..remove('id');
    if (w.containsKey('group_id')) w['group_id'] = await _groupUid(x, r['group_id'] as int);
    for (final k in const ['member_id', 'from_id', 'to_id']) {
      if (w.containsKey(k)) w[k] = await _memberUid(x, r[k] as int);
    }
    if (table == 'expense') {
      final id = r['id'] as int;
      Future<Map<String, int>> parts(String t) async {
        final rows = await x.query(t, where: 'expense_id=?', whereArgs: [id]);
        return {for (final p in rows) await _memberUid(x, p['member_id'] as int): p['amount'] as int};
      }

      w['payers'] = await parts('payer');
      w['shares'] = await parts('share');
    }
    w.remove('deleted_at');
    return w;
  }

  static Future<void> _enqueue(DatabaseExecutor x, String table, int id, {bool delete = false}) async {
    final r = (await x.query(table, where: 'id=?', whereArgs: [id], limit: 1)).first;
    await x.insert('outbox', {
      'op_id': newUid(),
      'tbl': table,
      'rec_uid': r['uid'],
      'action': delete ? 'delete' : 'upsert',
      'payload': jsonEncode(delete ? <String, Object?>{} : await _wire(x, table, r)),
      'updated_at': r['updated_at'],
      'created_at': _now(),
    });
  }

  /// Queued changes, oldest first. [unsentOnly] hides those already sent.
  static Future<List<DbRow>> outbox({bool unsentOnly = true}) async =>
      (await db).query('outbox', where: unsentOnly ? 'sent_at IS NULL' : null, orderBy: 'seq');

  // ---- groups ----
  static Future<List<DbRow>> groups() async => (await db).query('grp', where: 'deleted_at IS NULL', orderBy: 'id DESC');
  static Future<int> addGroup(String name, bool kitty) async {
    final d = await db;
    final id = await d.transaction((tx) async {
      final id = await tx.insert('grp', {'name': name, 'kitty': kitty ? 1 : 0, 'uid': newUid(), 'updated_at': _now()});
      await _enqueue(tx, 'grp', id);
      return id;
    });
    _bump();
    return id;
  }

  static Future<void> renameGroup(int id, String name) async {
    final d = await db;
    await d.transaction((tx) async {
      await tx.update('grp', {'name': name, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
      await _enqueue(tx, 'grp', id);
    });
    _bump();
  }

  /// Marks the group deleted (it can still be told to other phones). Its payments give up their
  /// transaction ids and screenshot fingerprints so those can be recorded again elsewhere.
  static Future<void> deleteGroup(int id) async {
    final d = await db;
    await d.transaction((tx) async {
      final n = _now();
      await tx.update('grp', {'deleted_at': n, 'updated_at': n}, where: 'id=?', whereArgs: [id]);
      await tx.update('settlement', {'ref': null, 'proof_hash': null}, where: 'group_id=?', whereArgs: [id]);
      await _enqueue(tx, 'grp', id, delete: true);
    });
    _bump();
  }

  // ---- members ----
  static Future<List<DbRow>> members(int gid, {bool all = false}) async => (await db).query('member',
      where: all ? 'group_id=?' : 'group_id=? AND active=1', whereArgs: [gid], orderBy: 'id');

  static Future<int> addMember(int gid, String name, String? upi, {String? phone}) async {
    final d = await db;
    final id = await d.transaction((tx) async {
      final id = await tx.insert('member', {
        'group_id': gid,
        'name': name,
        'upi_id': (upi == null || upi.trim().isEmpty) ? null : upi.trim(),
        'phone': (phone == null || phone.isEmpty) ? null : phone,
        'uid': newUid(),
        'updated_at': _now(),
      });
      await _enqueue(tx, 'member', id);
      return id;
    });
    _bump();
    return id;
  }

  static Future<void> updateMember(int id, String name, String? upi, {String? phone}) async {
    final d = await db;
    await d.transaction((tx) async {
      await tx.update(
          'member',
          {
            'name': name,
            'upi_id': (upi == null || upi.trim().isEmpty) ? null : upi.trim(),
            'phone': (phone == null || phone.isEmpty) ? null : phone,
            'updated_at': _now(),
          },
          where: 'id=?',
          whereArgs: [id]);
      await _enqueue(tx, 'member', id);
    });
    _bump();
  }

  /// Soft-remove. Caller must make sure the member's balance is zero first.
  static Future<void> archiveMember(int id) async {
    final d = await db;
    await d.transaction((tx) async {
      await tx.update('member', {'active': 0, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
      await _enqueue(tx, 'member', id);
    });
    _bump();
  }

  // ---- expenses ----
  static Future<List<DbRow>> expenses(int gid) async => (await db)
      .query('expense', where: 'group_id=? AND deleted_at IS NULL', whereArgs: [gid], orderBy: 'date DESC, id DESC');

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
      final id = await tx.insert('expense', {...e, 'uid': newUid(), 'updated_at': _now()});
      await _writeParts(tx, id, payers, shares);
      await _enqueue(tx, 'expense', id);
      return id;
    });
    _bump();
    return id;
  }

  static Future<void> updateExpense(int id, DbRow e, Map<int, int> payers, Map<int, int> shares) async {
    final d = await db;
    await d.transaction((tx) async {
      await tx.update('expense', {...e, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
      await tx.delete('payer', where: 'expense_id=?', whereArgs: [id]);
      await tx.delete('share', where: 'expense_id=?', whereArgs: [id]);
      await _writeParts(tx, id, payers, shares);
      await _enqueue(tx, 'expense', id);
    });
    _bump();
  }

  /// Marks the expense deleted; the row and its payer/share rows stay so the delete can sync.
  static Future<void> deleteExpense(int id) async {
    final d = await db;
    await d.transaction((tx) async {
      final n = _now();
      await tx.update('expense', {'deleted_at': n, 'updated_at': n}, where: 'id=?', whereArgs: [id]);
      await _enqueue(tx, 'expense', id, delete: true);
    });
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
  static Future<List<DbRow>> settlements(int gid) async => (await db).query('settlement',
      where: 'group_id=? AND deleted_at IS NULL', whereArgs: [gid], orderBy: 'date DESC, id DESC');

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
      final id = await d.transaction((tx) async {
        final id = await tx.insert('settlement', {
          'group_id': gid, 'from_id': from, 'to_id': to, 'amount': amount,
          'ref': r, 'proof_hash': proofHash, 'method': method, 'status': status,
          'proof_path': proofPath, 'note': note, 'uid': newUid(), 'updated_at': _now(),
          'date': (when ?? DateTime.now()).millisecondsSinceEpoch,
        });
        await _enqueue(tx, 'settlement', id);
        return id;
      });
      _bump();
      return id;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) throw DuplicateException('This payment was already recorded');
      rethrow;
    }
  }

  /// Marks the payment deleted and frees its transaction id and screenshot fingerprint,
  /// so the same payment can be recorded again.
  static Future<void> deleteSettlement(int id) async {
    final d = await db;
    await d.transaction((tx) async {
      final n = _now();
      await tx.update('settlement', {'deleted_at': n, 'updated_at': n, 'ref': null, 'proof_hash': null},
          where: 'id=?', whereArgs: [id]);
      await _enqueue(tx, 'settlement', id, delete: true);
    });
    _bump();
  }

  // ---- kitty ----
  static Future<void> addTopup(int gid, int memberId, int amount) async {
    final d = await db;
    await d.transaction((tx) async {
      final id = await tx.insert(
          'topup', {'group_id': gid, 'member_id': memberId, 'amount': amount, 'date': _now(), 'uid': newUid(), 'updated_at': _now()});
      await _enqueue(tx, 'topup', id);
    });
    _bump();
  }

  // ---- ledger ----
  /// Always recomputed from raw rows, so edits/deletes can never leave stale balances.
  static Future<Ledger> ledger(int gid, {required bool kitty}) async {
    final d = await db;
    final ms = await members(gid, all: true);
    final ex = await expenses(gid);
    final sh = await d.rawQuery(
        'SELECT s.* FROM share s JOIN expense e ON e.id=s.expense_id WHERE e.group_id=? AND e.deleted_at IS NULL', [gid]);
    final py = await d.rawQuery(
        'SELECT p.* FROM payer p JOIN expense e ON e.id=p.expense_id WHERE e.group_id=? AND e.deleted_at IS NULL', [gid]);
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

  /// Test hook: closes the database so a test can reopen it (and run migrations).
  @visibleForTesting
  static Future<void> closeForTest() async {
    await _db?.close();
    _db = null;
  }
}
