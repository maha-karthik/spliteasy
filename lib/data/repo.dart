import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../logic/ids.dart';
import '../logic/settle.dart';
import '../sync/sync_engine.dart';

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

  static Future<void> _addColumn(Database d, String table, String col, String def) async {
    final cols = await d.rawQuery('PRAGMA table_info($table)');
    if (!cols.any((c) => c['name'] == col)) await d.execute('ALTER TABLE $table ADD COLUMN $col $def');
  }

  /// outbox: every change made on this phone, waiting to be sent (sent_at stays NULL until then).
  /// applied_ops: ids of changes already applied here, so a replayed change is never applied twice.
  /// sync_meta: small key/value store (the pull cursor).
  static Future<void> _syncTables(Database d) async {
    await d.execute('CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE, tbl TEXT NOT NULL, rec_uid TEXT NOT NULL, action TEXT NOT NULL, payload TEXT NOT NULL, updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL, sent_at INTEGER, grp_uid TEXT)');
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
    return openDatabase(path, version: 5, onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
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
          if (oldV < 5) {
            // v4 -> v5: shared groups. grp.shared / admin_uid, and which group each queued change belongs to.
            await _addColumn(d, 'grp', 'shared', 'INTEGER NOT NULL DEFAULT 0');
            await _addColumn(d, 'grp', 'admin_uid', 'TEXT');
            await _addColumn(d, 'outbox', 'grp_uid', 'TEXT');
          }
        },
        onCreate: (d, v) async {
      await d.execute('CREATE TABLE grp(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kitty INTEGER NOT NULL DEFAULT 0, uid TEXT, updated_at INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER, shared INTEGER NOT NULL DEFAULT 0, admin_uid TEXT)');
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


  // ---- small settings (sync_meta key/value) ----
  static Future<String?> meta(String key) async {
    final r = await (await db).query('sync_meta', where: 'k=?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static Future<void> setMeta(String key, String value) async =>
      (await db).insert('sync_meta', {'k': key, 'v': value}, conflictAlgorithm: ConflictAlgorithm.replace);

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
    for (final k in const ['deleted_at', 'shared', 'admin_uid', 'proof_path']) {
      w.remove(k);
    }
    return w;
  }

  static Future<void> _enqueue(DatabaseExecutor x, String table, int id, {bool delete = false}) async {
    final r = (await x.query(table, where: 'id=?', whereArgs: [id], limit: 1)).first;
    final gUid = table == 'grp' ? r['uid'] as String : await _groupUid(x, r['group_id'] as int);
    await x.insert('outbox', {
      'grp_uid': gUid,
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

  // ---- shared groups ----
  static Future<List<DbRow>> sharedGroups() async =>
      (await db).query('grp', where: 'shared=1 AND deleted_at IS NULL');

  static Future<DbRow?> groupByUid(String uid) async {
    final r = await (await db).query('grp', where: 'uid=?', whereArgs: [uid], limit: 1);
    return r.isEmpty ? null : r.first;
  }

  /// True when the group is private to this phone, or [authUid] is its admin.
  static Future<bool> isAdmin(int gid, String? authUid) async {
    final r = await (await db).query('grp', columns: ['shared', 'admin_uid'], where: 'id=?', whereArgs: [gid], limit: 1);
    if (r.isEmpty || r.first['shared'] != 1) return true;
    return authUid != null && r.first['admin_uid'] == authUid;
  }

  /// Turns a private group into a shared one and queues its whole current content for upload.
  /// Returns the group's uid (also the id of its cloud copy).
  static Future<String> shareGroupLocally(int gid, String adminUid) async {
    final d = await db;
    final uid = await d.transaction((tx) async {
      final g = (await tx.query('grp', where: 'id=?', whereArgs: [gid], limit: 1)).first;
      await tx.update('grp', {'shared': 1, 'admin_uid': adminUid}, where: 'id=?', whereArgs: [gid]);
      await _enqueue(tx, 'grp', gid);
      for (final m in await tx.query('member', where: 'group_id=?', whereArgs: [gid])) {
        await _enqueue(tx, 'member', m['id'] as int);
      }
      for (final e in await tx.query('expense', where: 'group_id=? AND deleted_at IS NULL', whereArgs: [gid])) {
        await _enqueue(tx, 'expense', e['id'] as int);
      }
      for (final x in await tx.query('settlement', where: 'group_id=? AND deleted_at IS NULL', whereArgs: [gid])) {
        await _enqueue(tx, 'settlement', x['id'] as int);
      }
      for (final t in await tx.query('topup', where: 'group_id=?', whereArgs: [gid])) {
        await _enqueue(tx, 'topup', t['id'] as int);
      }
      return g['uid'] as String;
    });
    _bump();
    return uid;
  }

  /// Makes sure a group that exists in the cloud also exists here (joining phone), and records its admin.
  static Future<void> ensureSharedGroup(String groupUid, String name, String adminUid) async {
    final d = await db;
    final g = await groupByUid(groupUid);
    if (g == null) {
      await d.insert('grp', {'name': name, 'kitty': 0, 'uid': groupUid, 'updated_at': 0, 'shared': 1, 'admin_uid': adminUid});
    } else {
      await d.update('grp', {'shared': 1, 'admin_uid': adminUid}, where: 'uid=?', whereArgs: [groupUid]);
    }
    _bump();
  }

  /// Queued changes of one shared group that have not been sent yet.
  static Future<List<DbRow>> unsentFor(String groupUid) async =>
      (await db).query('outbox', where: 'grp_uid=? AND sent_at IS NULL', whereArgs: [groupUid], orderBy: 'seq');

  static Future<void> markSentIds(List<String> opIds) async {
    final d = await db;
    final n = _now();
    await d.transaction((tx) async {
      for (final id in opIds) {
        await tx.update('outbox', {'sent_at': n}, where: 'op_id=?', whereArgs: [id]);
        await tx.insert('applied_ops', {'op_id': id, 'applied_at': n}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  static Future<bool> opApplied(String opId) async =>
      (await (await db).query('applied_ops', where: 'op_id=?', whereArgs: [opId], limit: 1)).isNotEmpty;

  static Future<void> markOpApplied(String opId) async => (await db)
      .insert('applied_ops', {'op_id': opId, 'applied_at': _now()}, conflictAlgorithm: ConflictAlgorithm.ignore);

  /// (updated_at, deleted) of a record, or null if this phone has never seen it.
  static Future<({int updatedAt, bool deleted})?> recordStamp(String table, String uid) async {
    if (!_synced.contains(table)) return null;
    final d = await db;
    final cols = _deletable.contains(table) ? ['updated_at', 'deleted_at'] : ['updated_at'];
    final r = await d.query(table, columns: cols, where: 'uid=?', whereArgs: [uid], limit: 1);
    if (r.isEmpty) return null;
    return (updatedAt: r.first['updated_at'] as int, deleted: r.first['deleted_at'] != null);
  }

  // Local id of a record by uid, creating an empty placeholder when its change has not arrived yet
  // (changes of one batch can arrive in any order; the real change replaces the placeholder).
  static Future<int> _idByUid(DatabaseExecutor x, String table, String uid, {int? groupId}) async {
    final r = await x.query(table, columns: ['id'], where: 'uid=?', whereArgs: [uid], limit: 1);
    if (r.isNotEmpty) return r.first['id'] as int;
    if (table == 'grp') {
      return x.insert('grp', {'name': 'Shared group', 'kitty': 0, 'uid': uid, 'updated_at': 0, 'shared': 1});
    }
    if (table == 'member') {
      return x.insert('member', {'group_id': groupId, 'name': '?', 'uid': uid, 'updated_at': 0});
    }
    throw StateError('cannot create placeholder for $table');
  }

  static Future<int> _memberRef(DatabaseExecutor x, Object? uid, int groupId) async =>
      uid == 'kitty' ? kittyId : _idByUid(x, 'member', uid as String, groupId: groupId);

  /// Applies one change that came from another phone. Idempotent; does not queue anything.
  static Future<void> applyRemote(SyncOp op) async {
    final d = await db;
    final p = op.payload;
    await d.transaction((tx) async {
      final existing = await tx.query(op.table, columns: ['id'], where: 'uid=?', whereArgs: [op.recUid], limit: 1);
      int? id = existing.isEmpty ? null : existing.first['id'] as int;

      if (op.isDelete) {
        if (id == null) {
          // A delete for something never seen: remember it so an older create cannot bring it back.
          if (op.table == 'grp') {
            await tx.insert('grp', {'name': '', 'kitty': 0, 'uid': op.recUid, 'updated_at': op.updatedAt, 'deleted_at': op.updatedAt, 'shared': 1});
          }
          return;
        }
        final vals = <String, Object?>{'deleted_at': op.updatedAt, 'updated_at': op.updatedAt};
        if (op.table == 'settlement') {
          vals['ref'] = null;
          vals['proof_hash'] = null;
        }
        if (_deletable.contains(op.table)) await tx.update(op.table, vals, where: 'id=?', whereArgs: [id]);
        return;
      }

      switch (op.table) {
        case 'grp':
          final vals = {'name': p['name'], 'kitty': p['kitty'] ?? 0, 'updated_at': op.updatedAt, 'deleted_at': null, 'shared': 1};
          if (id == null) {
            await tx.insert('grp', {...vals, 'uid': op.recUid});
          } else {
            await tx.update('grp', vals, where: 'id=?', whereArgs: [id]);
          }
          break;
        case 'member':
          final gid = await _idByUid(tx, 'grp', p['group_id'] as String);
          final vals = {
            'group_id': gid, 'name': p['name'], 'upi_id': p['upi_id'], 'active': p['active'] ?? 1,
            'phone': p['phone'], 'updated_at': op.updatedAt,
          };
          if (id == null) {
            await tx.insert('member', {...vals, 'uid': op.recUid});
          } else {
            await tx.update('member', vals, where: 'id=?', whereArgs: [id]);
          }
          break;
        case 'expense':
          final gid = await _idByUid(tx, 'grp', p['group_id'] as String);
          final vals = {
            'group_id': gid, 'title': p['title'], 'amount': p['amount'], 'category': p['category'], 'note': p['note'],
            'split_type': p['split_type'], 'date': p['date'], 'updated_at': op.updatedAt, 'deleted_at': null,
          };
          if (id == null) {
            id = await tx.insert('expense', {...vals, 'uid': op.recUid});
          } else {
            await tx.update('expense', vals, where: 'id=?', whereArgs: [id]);
          }
          await tx.delete('payer', where: 'expense_id=?', whereArgs: [id]);
          await tx.delete('share', where: 'expense_id=?', whereArgs: [id]);
          for (final e in Map<String, Object?>.from(p['payers'] as Map).entries) {
            await tx.insert('payer', {'expense_id': id, 'member_id': await _memberRef(tx, e.key, gid), 'amount': e.value});
          }
          for (final e in Map<String, Object?>.from(p['shares'] as Map).entries) {
            await tx.insert('share', {'expense_id': id, 'member_id': await _memberRef(tx, e.key, gid), 'amount': e.value});
          }
          break;
        case 'settlement':
          final gid = await _idByUid(tx, 'grp', p['group_id'] as String);
          var ref = p['ref'] as String?;
          var hash = p['proof_hash'] as String?;
          int? deletedAt;
          // The same payment recorded on two phones: both phones keep the one with the smaller uid.
          for (final col in const ['ref', 'proof_hash']) {
            final v = col == 'ref' ? ref : hash;
            if (v == null) continue;
            final other = await tx.query('settlement', where: '$col=? AND uid<>?', whereArgs: [v, op.recUid], limit: 1);
            if (other.isEmpty) continue;
            if (op.recUid.compareTo(other.first['uid'] as String) < 0) {
              await tx.update('settlement', {'ref': null, 'proof_hash': null, 'deleted_at': op.updatedAt},
                  where: 'id=?', whereArgs: [other.first['id']]);
            } else {
              ref = null;
              hash = null;
              deletedAt = op.updatedAt;
            }
          }
          final vals = {
            'group_id': gid, 'from_id': await _memberRef(tx, p['from_id'], gid), 'to_id': await _memberRef(tx, p['to_id'], gid),
            'amount': p['amount'], 'ref': ref, 'proof_hash': hash, 'method': p['method'], 'status': p['status'],
            'note': p['note'], 'date': p['date'], 'updated_at': op.updatedAt, 'deleted_at': deletedAt,
          };
          if (id == null) {
            await tx.insert('settlement', {...vals, 'uid': op.recUid});
          } else {
            await tx.update('settlement', vals, where: 'id=?', whereArgs: [id]);
          }
          break;
        case 'topup':
          final gid = await _idByUid(tx, 'grp', p['group_id'] as String);
          final vals = {
            'group_id': gid, 'member_id': await _memberRef(tx, p['member_id'], gid), 'amount': p['amount'],
            'date': p['date'], 'updated_at': op.updatedAt,
          };
          if (id == null) {
            await tx.insert('topup', {...vals, 'uid': op.recUid});
          } else {
            await tx.update('topup', vals, where: 'id=?', whereArgs: [id]);
          }
          break;
      }
    });
    _bump();
  }

  /// Which uid a member id refers to (used by tests and diagnostics).
  static Future<String?> memberUid(int id) async {
    final r = await (await db).query('member', columns: ['uid'], where: 'id=?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : r.first['uid'] as String?;
  }

  /// Test hook: closes the database so a test can reopen it (and run migrations).
  @visibleForTesting
  static Future<void> closeForTest() async {
    await _db?.close();
    _db = null;
  }
}
