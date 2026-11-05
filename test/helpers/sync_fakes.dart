import 'package:spliteasy/logic/merge.dart';
import 'package:spliteasy/sync/sync_engine.dart';

/// In-memory relay. [online]=false makes every call fail, like a phone with no internet.
class MemoryBackend implements SyncBackend {
  final List<SyncOp> log = [];
  bool online = true;

  @override
  Future<void> push(List<SyncOp> ops) async {
    if (!online) throw Exception('offline');
    log.addAll(ops);
  }

  @override
  Future<PullResult> pull(int cursor) async {
    if (!online) throw Exception('offline');
    return PullResult(log.sublist(cursor), log.length);
  }
}

/// One phone's records, queue and bookkeeping, held in memory.
class MemoryStore implements SyncStore {
  @override
  final String deviceId;
  MemoryStore(this.deviceId);

  final Map<String, Map<String, Object?>> records = {}; // "table|uid" -> payload (+ stamp)
  final Map<String, Stamp> stamps = {};
  final List<SyncOp> outbox = [];
  final Set<String> sent = {}, applied = {};
  int _cursor = 0;
  int applyCount = 0;
  int _n = 0;

  /// A change made on this phone: writes the record and queues the op.
  void localWrite(String table, String uid, Map<String, Object?> payload, int at, {bool delete = false}) {
    final op = SyncOp(
        opId: '$deviceId-${_n++}',
        table: table,
        recUid: uid,
        action: delete ? 'delete' : 'upsert',
        payload: delete ? {} : payload,
        updatedAt: at,
        origin: deviceId);
    _put(op);
    outbox.add(op);
  }

  void _put(SyncOp op) {
    final k = '${op.table}|${op.recUid}';
    stamps[k] = op.stamp;
    if (op.isDelete) {
      records[k] = {'_deleted': true};
    } else {
      records[k] = {...op.payload};
    }
  }

  /// Visible state: records that are not deleted, as comparable text.
  Map<String, String> get view => {
        for (final e in records.entries)
          if (e.value['_deleted'] != true) e.key: e.value.toString(),
      };

  @override
  Future<List<SyncOp>> unsentOps() async => outbox.where((o) => !sent.contains(o.opId)).toList();
  @override
  Future<void> markSent(List<String> ids) async {
    sent.addAll(ids);
    applied.addAll(ids);
  }

  @override
  Future<bool> alreadyApplied(String opId) async => applied.contains(opId);
  @override
  Future<void> markApplied(String opId) async => applied.add(opId);
  @override
  Future<Stamp?> stampOf(String table, String recUid) async => stamps['$table|$recUid'];
  @override
  Future<void> apply(SyncOp op) async {
    applyCount++;
    _put(op);
    applied.add(op.opId);
  }

  @override
  Future<int> cursor() async => _cursor;
  @override
  Future<void> setCursor(int c) async => _cursor = c;
}
