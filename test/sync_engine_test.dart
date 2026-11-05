import 'package:flutter_test/flutter_test.dart';
import 'package:spliteasy/sync/sync_engine.dart';
import 'helpers/sync_fakes.dart';

void main() {
  test('two phones that each add an expense end up with both', () async {
    final relay = MemoryBackend();
    final a = MemoryStore('A'), b = MemoryStore('B');
    a.localWrite('expense', 'e1', {'title': 'petrol', 'amount': 350000}, 100);
    b.localWrite('expense', 'e2', {'title': 'tea', 'amount': 6000}, 110);
    await SyncEngine.run(a, relay);
    await SyncEngine.run(b, relay);
    await SyncEngine.run(a, relay);
    expect(a.view, b.view);
    expect(a.view.keys, containsAll(['expense|e1', 'expense|e2']));
  });

  test('changes made offline wait in the queue and go out later, nothing lost', () async {
    final relay = MemoryBackend()..online = false;
    final a = MemoryStore('A'), b = MemoryStore('B');
    a.localWrite('expense', 'e1', {'title': 'hotel'}, 100);
    final r = await SyncEngine.run(a, relay);
    expect(r.offline, isTrue);
    expect((await a.unsentOps()).length, 1);
    relay.online = true;
    final r2 = await SyncEngine.run(a, relay);
    expect(r2.pushed, 1);
    expect((await a.unsentOps()), isEmpty);
    await SyncEngine.run(b, relay);
    expect(b.view.keys, ['expense|e1']);
  });

  test('a change delivered twice is applied once', () async {
    final relay = MemoryBackend();
    final a = MemoryStore('A'), b = MemoryStore('B');
    a.localWrite('settlement', 's1', {'amount': 50000}, 100);
    await SyncEngine.run(a, relay);
    relay.log.add(relay.log.first); // the relay replays the same op
    await SyncEngine.run(b, relay);
    await SyncEngine.run(b, relay);
    expect(b.applyCount, 1);
    expect(b.view.keys, ['settlement|s1']);
  });

  test('a later edit beats an earlier delete, and a later delete beats an earlier edit', () async {
    for (final deleteIsLater in [false, true]) {
      final relay = MemoryBackend();
      final a = MemoryStore('A'), b = MemoryStore('B');
      a.localWrite('expense', 'e1', {'title': 'x'}, 50);
      await SyncEngine.run(a, relay);
      await SyncEngine.run(b, relay);
      a.localWrite('expense', 'e1', {'title': 'edited'}, deleteIsLater ? 100 : 200);
      b.localWrite('expense', 'e1', {}, deleteIsLater ? 200 : 100, delete: true);
      for (var i = 0; i < 2; i++) {
        await SyncEngine.run(a, relay);
        await SyncEngine.run(b, relay);
      }
      expect(a.view, b.view, reason: 'phones disagree (deleteIsLater=$deleteIsLater)');
      expect(a.view.isEmpty, deleteIsLater);
    }
  });

  test('same result whichever phone syncs first', () async {
    Future<Map<String, String>> scenario(List<String> order) async {
      final relay = MemoryBackend();
      final s = {'A': MemoryStore('A'), 'B': MemoryStore('B'), 'C': MemoryStore('C')};
      s['A']!.localWrite('member', 'm1', {'name': 'priya'}, 100);
      s['B']!.localWrite('member', 'm1', {'name': 'Priya K'}, 100); // exact same millisecond
      s['C']!.localWrite('member', 'm1', {}, 100, delete: true);
      for (final k in [...order, ...order]) {
        await SyncEngine.run(s[k]!, relay);
      }
      expect(s['A']!.view, s['B']!.view);
      expect(s['B']!.view, s['C']!.view);
      return s['A']!.view;
    }

    final results = <String>{};
    for (final o in [['A', 'B', 'C'], ['C', 'B', 'A'], ['B', 'A', 'C'], ['C', 'A', 'B']]) {
      results.add((await scenario(o)).toString());
    }
    expect(results.length, 1, reason: results.toString());
  });

  test('SyncOp survives a round trip through JSON', () {
    const op = SyncOp(opId: 'o1', table: 'expense', recUid: 'u1', action: 'upsert', payload: {'a': 1}, updatedAt: 9, origin: 'A');
    final back = SyncOp.fromJson(op.toJson());
    expect(back.opId, 'o1');
    expect(back.payload, {'a': 1});
    expect(back.stamp.toString(), op.stamp.toString());
  });
}
