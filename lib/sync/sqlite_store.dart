import 'dart:convert';
import '../data/repo.dart';
import '../logic/merge.dart';
import 'sync_engine.dart';

/// One shared group's view of this phone's database, as the sync engine needs it.
class SqliteSyncStore implements SyncStore {
  final String groupUid;
  @override
  final String deviceId; // the signed-in account's uid
  SqliteSyncStore(this.groupUid, this.deviceId);

  @override
  Future<List<SyncOp>> unsentOps() async => [
        for (final r in await Repo.unsentFor(groupUid))
          SyncOp(
              opId: r['op_id'] as String,
              table: r['tbl'] as String,
              recUid: r['rec_uid'] as String,
              action: r['action'] as String,
              payload: Map<String, Object?>.from(jsonDecode(r['payload'] as String) as Map),
              updatedAt: r['updated_at'] as int,
              origin: deviceId)
      ];

  @override
  Future<void> markSent(List<String> opIds) => Repo.markSentIds(opIds);
  @override
  Future<bool> alreadyApplied(String opId) => Repo.opApplied(opId);
  @override
  Future<void> markApplied(String opId) => Repo.markOpApplied(opId);

  @override
  Future<Stamp?> stampOf(String table, String recUid) async {
    final s = await Repo.recordStamp(table, recUid);
    return s == null ? null : Stamp(s.updatedAt, deleted: s.deleted);
  }

  @override
  Future<void> apply(SyncOp op) async {
    await Repo.applyRemote(op);
    await Repo.markOpApplied(op.opId);
  }

  @override
  Future<int> cursor() async => int.tryParse(await Repo.meta('cursor:$groupUid') ?? '') ?? 0;
  @override
  Future<void> setCursor(int c) => Repo.setMeta('cursor:$groupUid', '$c');
}
