// Pure Dart. The sync algorithm, independent of any backend. Stage 3 plugs Firebase in as a
// SyncBackend and the SQLite database in as a SyncStore; nothing here touches the network or disk.
import '../logic/merge.dart';

/// One change to one record, as it travels between phones.
class SyncOp {
  final String opId; // unique per change; a replayed op is recognised by this
  final String table; // grp, member, expense, settlement, topup
  final String recUid; // the record's globally unique id
  final String action; // 'upsert' or 'delete'
  final Map<String, Object?> payload; // the record as plain data (empty for a delete)
  final int updatedAt; // when the change was made on the originating phone
  final String origin; // id of that phone, only used to break exact ties
  const SyncOp({
    required this.opId,
    required this.table,
    required this.recUid,
    required this.action,
    required this.payload,
    required this.updatedAt,
    this.origin = '',
  });

  bool get isDelete => action == 'delete';
  Stamp get stamp => Stamp(updatedAt, deleted: isDelete, origin: origin);

  Map<String, Object?> toJson() => {
        'opId': opId, 'table': table, 'recUid': recUid, 'action': action,
        'payload': payload, 'updatedAt': updatedAt, 'origin': origin,
      };

  factory SyncOp.fromJson(Map<String, Object?> j) => SyncOp(
        opId: j['opId'] as String,
        table: j['table'] as String,
        recUid: j['recUid'] as String,
        action: j['action'] as String,
        payload: Map<String, Object?>.from(j['payload'] as Map),
        updatedAt: j['updatedAt'] as int,
        origin: (j['origin'] as String?) ?? '',
      );
}

class PullResult {
  final List<SyncOp> ops;
  final int cursor; // pass this back next time to get only newer ops
  const PullResult(this.ops, this.cursor);
}

/// The relay. Stage 3 implements this with Firebase; tests use an in-memory one.
abstract class SyncBackend {
  Future<void> push(List<SyncOp> ops); // throws when offline
  Future<PullResult> pull(int cursor); // throws when offline
}

/// What one phone's local database must offer to take part in sync.
abstract class SyncStore {
  String get deviceId;
  Future<List<SyncOp>> unsentOps();
  Future<void> markSent(List<String> opIds); // also records them as already applied here
  Future<bool> alreadyApplied(String opId);
  Future<void> markApplied(String opId);
  Future<Stamp?> stampOf(String table, String recUid); // null = record not known here yet
  Future<void> apply(SyncOp op); // writes the record or tombstone and records the op as applied
  Future<int> cursor();
  Future<void> setCursor(int c);
}

class SyncResult {
  final int pushed, applied, skipped;
  final bool offline;
  const SyncResult({this.pushed = 0, this.applied = 0, this.skipped = 0, this.offline = false});
}

class SyncEngine {
  /// One round: send what is queued, then fetch and apply what others sent.
  /// If the backend cannot be reached nothing is lost: queued ops stay queued.
  static Future<SyncResult> run(SyncStore store, SyncBackend backend) async {
    var pushed = 0, applied = 0, skipped = 0;
    try {
      final out = await store.unsentOps();
      if (out.isNotEmpty) {
        await backend.push(out);
        await store.markSent(out.map((o) => o.opId).toList());
        pushed = out.length;
      }
      final got = await backend.pull(await store.cursor());
      for (final op in got.ops) {
        if (await store.alreadyApplied(op.opId)) {
          skipped++;
          continue;
        }
        if (incomingWins(await store.stampOf(op.table, op.recUid), op.stamp)) {
          await store.apply(op);
          applied++;
        } else {
          await store.markApplied(op.opId); // older or identical: remember it, change nothing
          skipped++;
        }
      }
      await store.setCursor(got.cursor);
    } catch (_) {
      return SyncResult(pushed: pushed, applied: applied, skipped: skipped, offline: true);
    }
    return SyncResult(pushed: pushed, applied: applied, skipped: skipped);
  }
}
