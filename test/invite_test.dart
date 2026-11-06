import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliteasy/logic/invite.dart';

void main() {
  test('codes are 6 readable characters and vary', () {
    final seen = <String>{};
    for (var i = 0; i < 500; i++) {
      final c = newInviteCode();
      expect(normalizeInviteCode(c), c);
      seen.add(c);
    }
    expect(seen.length, greaterThan(490));
    expect(newInviteCode(Random(7)), newInviteCode(Random(7)));
  });
  test('typed codes are tidied or rejected', () {
    expect(normalizeInviteCode(' k7m-2qx '), 'K7M2QX');
    expect(normalizeInviteCode('K7M2Q'), isNull);
    expect(normalizeInviteCode('K7M2QXX'), isNull);
    expect(normalizeInviteCode('K7M2Q0'), isNull); // 0 is never used
    expect(normalizeInviteCode('K7M2QI'), isNull); // nor I
  });
}
