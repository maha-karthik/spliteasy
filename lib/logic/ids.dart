// Pure Dart. Record ids that are unique across all phones.
import 'dart:math';

final Random _secure = Random.secure();

/// Random UUID v4 such as "3f2b8c1e-9a4d-4e7b-8c21-5d6f0a1b2c3d".
/// Generated on the device, so a record has a globally unique id before it ever reaches a server.
String newUid([Random? rng]) {
  final r = rng ?? _secure;
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final s = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
    s.write(h(i));
  }
  return s.toString();
}

final RegExp _uidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

bool isUid(String s) => _uidRe.hasMatch(s);
