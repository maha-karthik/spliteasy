import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliteasy/logic/ids.dart';
import 'package:spliteasy/logic/merge.dart';

List<List<T>> _permutations<T>(List<T> xs) {
  if (xs.length <= 1) return [xs];
  final out = <List<T>>[];
  for (var i = 0; i < xs.length; i++) {
    final rest = [...xs]..removeAt(i);
    for (final p in _permutations(rest)) {
      out.add([xs[i], ...p]);
    }
  }
  return out;
}

Stamp _apply(List<Stamp> arrivals) {
  Stamp? cur;
  for (final s in arrivals) {
    if (incomingWins(cur, s)) cur = s;
  }
  return cur!;
}

void main() {
  group('newUid', () {
    test('is a valid v4 uuid and unique', () {
      final seen = <String>{};
      for (var i = 0; i < 2000; i++) {
        final u = newUid();
        expect(isUid(u), isTrue, reason: u);
        expect(seen.add(u), isTrue, reason: 'duplicate $u');
      }
    });
    test('is deterministic for a seeded generator and rejects bad strings', () {
      expect(newUid(Random(1)), newUid(Random(1)));
      expect(isUid('not-a-uid'), isFalse);
      expect(isUid('3f2b8c1e-9a4d-1e7b-8c21-5d6f0a1b2c3d'), isFalse); // version 1
    });
  });

  group('incomingWins', () {
    test('anything beats nothing', () => expect(incomingWins(null, const Stamp(1)), isTrue));
    test('newer wins, older loses', () {
      expect(incomingWins(const Stamp(100), const Stamp(101)), isTrue);
      expect(incomingWins(const Stamp(100), const Stamp(99)), isFalse);
    });
    test('a newer edit beats an older delete, a newer delete beats an older edit', () {
      expect(incomingWins(const Stamp(100, deleted: true), const Stamp(200)), isTrue);
      expect(incomingWins(const Stamp(100), const Stamp(200, deleted: true)), isTrue);
    });
    test('same instant: delete wins, then higher origin', () {
      expect(incomingWins(const Stamp(100, origin: 'a'), const Stamp(100, deleted: true, origin: 'a')), isTrue);
      expect(incomingWins(const Stamp(100, deleted: true, origin: 'a'), const Stamp(100, origin: 'z')), isFalse);
      expect(incomingWins(const Stamp(100, origin: 'a'), const Stamp(100, origin: 'b')), isTrue);
      expect(incomingWins(const Stamp(100, origin: 'b'), const Stamp(100, origin: 'a')), isFalse);
    });
    test('identical stamp changes nothing (replay is harmless)', () {
      expect(incomingWins(const Stamp(100, origin: 'a'), const Stamp(100, origin: 'a')), isFalse);
    });
  });

  group('convergence', () {
    test('every arrival order gives the same winner', () {
      const stamps = [
        Stamp(100, origin: 'phoneA'),
        Stamp(100, origin: 'phoneB'),
        Stamp(100, deleted: true, origin: 'phoneC'),
        Stamp(90, origin: 'phoneD'),
        Stamp(250, origin: 'phoneA'),
      ];
      final results = _permutations(stamps).map((p) => _apply(p).toString()).toSet();
      expect(results.length, 1, reason: results.toString());
      expect(results.single, 'Stamp(250, phoneA)');
    });
    test('equal-time delete beats edits in every order', () {
      const stamps = [Stamp(5, origin: 'x'), Stamp(5, origin: 'y'), Stamp(5, deleted: true, origin: 'a')];
      final results = _permutations(stamps).map((p) => _apply(p).toString()).toSet();
      expect(results.single, 'Stamp(5, deleted, a)');
    });
  });

  group('AppliedOps', () {
    test('an operation is applied once however often it is replayed', () {
      final ops = AppliedOps();
      expect(ops.firstTime('op-1'), isTrue);
      expect(ops.firstTime('op-1'), isFalse);
      expect(ops.firstTime('op-2'), isTrue);
    });
  });
}
