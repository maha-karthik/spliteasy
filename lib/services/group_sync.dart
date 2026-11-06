import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../data/repo.dart';
import '../logic/invite.dart';
import '../sync/sqlite_store.dart';
import '../sync/sync_engine.dart';
import 'auth_service.dart';

/// The cloud relay for one shared group, as the sync engine sees it.
class FirestoreBackend implements SyncBackend {
  final String gid, uid;
  FirestoreBackend(this.gid, this.uid);

  CollectionReference<Map<String, dynamic>> get _ops =>
      FirebaseFirestore.instance.collection('groups').doc(gid).collection('ops');

  Future<void> _commit(List<SyncOp> chunk) {
    final b = FirebaseFirestore.instance.batch();
    for (final op in chunk) {
      b.set(_ops.doc(op.opId), {
        'table': op.table,
        'recUid': op.recUid,
        'action': op.action,
        'payload': jsonEncode(op.payload),
        'updatedAt': op.updatedAt,
        'origin': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    return b.commit().timeout(const Duration(seconds: 20));
  }

  @override
  Future<void> push(List<SyncOp> ops) async {
    for (var i = 0; i < ops.length; i += 400) {
      final chunk = ops.sublist(i, min(i + 400, ops.length));
      try {
        await _commit(chunk);
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
        // The rules refused something in this batch (for example a non-admin's member edit).
        // Send the rest one by one and drop only what the rules refuse, so it cannot block syncing.
        for (final op in chunk) {
          try {
            await _commit([op]);
          } on FirebaseException catch (e2) {
            if (e2.code != 'permission-denied') rethrow;
          }
        }
      }
    }
  }

  @override
  Future<PullResult> pull(int cursor) async {
    final snap = await _ops
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromMillisecondsSinceEpoch(cursor))
        .orderBy('createdAt')
        .limit(500)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 20));
    var newest = cursor;
    final out = <SyncOp>[];
    for (final d in snap.docs) {
      final m = d.data();
      final at = (m['createdAt'] as Timestamp).millisecondsSinceEpoch;
      if (at > newest) newest = at;
      out.add(SyncOp(
          opId: d.id,
          table: m['table'] as String,
          recUid: m['recUid'] as String,
          action: m['action'] as String,
          payload: Map<String, Object?>.from(jsonDecode(m['payload'] as String) as Map),
          updatedAt: m['updatedAt'] as int,
          origin: (m['origin'] as String?) ?? ''));
    }
    return PullResult(out, newest);
  }
}

class InviteInfo {
  final String code, gid, groupName;
  final List<({String uid, String name})> people;
  InviteInfo(this.code, this.gid, this.groupName, this.people);
}

/// Shares groups, creates and redeems invites, and keeps shared groups in step with the cloud.
class GroupSyncService {
  static Timer? _debounce;
  static bool _running = false, _again = false, _started = false;
  static final Map<String, StreamSubscription<dynamic>> _watching = {};

  /// 'Synced', 'Offline, will retry', or an error; shown on the group screen.
  static final ValueNotifier<String> status = ValueNotifier('');

  static FirebaseFirestore get _fs => FirebaseFirestore.instance;

  static void start() {
    if (_started || !AuthService.ready) return;
    _started = true;
    Repo.changes.addListener(_schedule);
    AuthService.signedIn.listen((signedIn) {
      if (signedIn) {
        unawaited(_watchAll());
        unawaited(syncAll());
      } else {
        for (final s in _watching.values) {
          s.cancel();
        }
        _watching.clear();
      }
    });
  }

  static void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(syncAll()));
  }

  static Future<void> _watchAll() async {
    final uid = AuthService.user?.uid;
    if (uid == null) return;
    for (final g in await Repo.sharedGroups()) {
      final gUid = g['uid'] as String;
      if (_watching.containsKey(gUid)) continue;
      _watching[gUid] = _fs
          .collection('groups')
          .doc(gUid)
          .collection('ops')
          .orderBy('createdAt', descending: true)
          .limit(1)
          .snapshots()
          .listen((_) => _schedule(), onError: (_) {});
    }
  }

  /// Sends queued changes and fetches others' changes for every shared group.
  static Future<void> syncAll() async {
    final uid = AuthService.user?.uid;
    if (uid == null) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        var offline = false;
        for (final g in await Repo.sharedGroups()) {
          final gUid = g['uid'] as String;
          for (var round = 0; round < 10; round++) {
            final r = await SyncEngine.run(SqliteSyncStore(gUid, uid), FirestoreBackend(gUid, uid));
            if (r.offline) {
              offline = true;
              break;
            }
            if (r.applied == 0) break;
          }
        }
        status.value = offline ? 'Offline. Changes will be sent when you are back online.' : 'Synced';
      } while (_again);
    } catch (e) {
      status.value = 'Sync problem: $e';
    } finally {
      _running = false;
    }
  }

  /// Turns a private group into a shared one. The signed-in person becomes its admin.
  static Future<void> shareGroup(int gid) async {
    final u = AuthService.user;
    if (u == null) throw StateError('Sign in first');
    final g = (await Repo.groups()).firstWhere((x) => x['id'] == gid);
    final gUid = g['uid'] as String;
    final b = _fs.batch();
    b.set(_fs.collection('groups').doc(gUid), {
      'name': g['name'], 'kitty': g['kitty'], 'adminUid': u.uid, 'createdAt': FieldValue.serverTimestamp(),
    });
    b.set(_fs.collection('groups').doc(gUid).collection('members').doc(u.uid), {
      'role': 'admin', 'memberUid': '', 'name': u.displayName ?? u.email ?? '', 'inviteCode': '',
      'joinedAt': FieldValue.serverTimestamp(),
    });
    await b.commit().timeout(const Duration(seconds: 20));
    await Repo.shareGroupLocally(gid, u.uid);
    await _watchAll();
    unawaited(syncAll());
  }

  /// A fresh 6-character code, valid for 7 days. Admin only (the rules check this too).
  static Future<String> createInvite(int gid) async {
    final u = AuthService.user;
    if (u == null) throw StateError('Sign in first');
    final g = (await Repo.groups()).firstWhere((x) => x['id'] == gid);
    final people = [
      for (final m in await Repo.members(gid)) {'uid': m['uid'], 'name': m['name']}
    ];
    for (var attempt = 0; attempt < 5; attempt++) {
      final code = newInviteCode();
      try {
        await _fs.collection('invites').doc(code).set({
          'gid': g['uid'], 'groupName': g['name'], 'createdBy': u.uid, 'createdAt': FieldValue.serverTimestamp(),
          'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))), 'people': people,
        }).timeout(const Duration(seconds: 20));
        return code;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied' || attempt == 4) rethrow; // a code collision looks like a refused update
      }
    }
    throw StateError('Could not create a code');
  }

  /// null if the code does not exist or has expired.
  static Future<InviteInfo?> lookupInvite(String code) async {
    final d = await _fs.collection('invites').doc(code).get().timeout(const Duration(seconds: 20));
    if (!d.exists) return null;
    final m = d.data()!;
    if ((m['expiresAt'] as Timestamp).toDate().isBefore(DateTime.now())) return null;
    return InviteInfo(code, m['gid'] as String, m['groupName'] as String, [
      for (final p in (m['people'] as List)) (uid: (p as Map)['uid'] as String, name: p['name'] as String)
    ]);
  }

  /// Joins the group behind [info] as the existing person [personUid], then downloads it.
  static Future<void> join(InviteInfo info, String personUid) async {
    final u = AuthService.user;
    if (u == null) throw StateError('Sign in first');
    final mine = _fs.collection('groups').doc(info.gid).collection('members').doc(u.uid);
    try {
      await mine.set({
        'role': 'member', 'memberUid': personUid, 'name': u.displayName ?? u.email ?? '', 'inviteCode': info.code,
        'joinedAt': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 20));
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow; // already a member: carry on if the group is readable
    }
    final g = await _fs.collection('groups').doc(info.gid).get().timeout(const Duration(seconds: 20));
    final data = g.data();
    if (data == null) throw StateError('Could not join. Ask the admin for a new code.');
    await Repo.ensureSharedGroup(info.gid, data['name'] as String, data['adminUid'] as String);
    await Repo.setMeta('me:${info.gid}', personUid);
    await _watchAll();
    await syncAll();
  }
}
