// Pure Dart. Invite codes for joining a shared group.
import 'dart:math';

// No 0/O, 1/I/L: easy to read out loud or type from a WhatsApp message.
const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
final Random _rng = Random.secure();

/// A random 6-character code such as "K7M2QX".
String newInviteCode([Random? rng]) {
  final r = rng ?? _rng;
  return List.generate(6, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
}

/// Tidies what a person typed or pasted: "k7m-2qx " -> "K7M2QX". Returns null if it cannot be a code.
String? normalizeInviteCode(String raw) {
  final s = raw.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');
  if (s.length != 6) return null;
  for (final c in s.split('')) {
    if (!_alphabet.contains(c)) return null;
  }
  return s;
}
