import 'package:flutter_test/flutter_test.dart';
import 'package:spliteasy/logic/contact_utils.dart';

void main() {
  group('normalizePhone', () {
    test('Indian formats become +91XXXXXXXXXX', () {
      for (final s in ['9876543210', '98765 43210', '098765-43210', '+91 98765 43210', '91 9876543210', '0091 98765 43210', '(98765) 43210']) {
        expect(normalizePhone(s), '+919876543210', reason: s);
      }
    });
    test('other countries need an explicit + or 00', () {
      expect(normalizePhone('+1 (415) 555-2671'), '+14155552671');
      expect(normalizePhone('0044 20 7946 0958'), '+442079460958');
    });
    test('rejects things that cannot be a mobile number', () {
      for (final s in ['', '   ', 'abc', '12345', '5876543210', '+91 12345 67890', '98765432101234567', '+0123456789']) {
        expect(normalizePhone(s), isNull, reason: s);
      }
    });
    test('is idempotent', () {
      final once = normalizePhone('98765 43210')!;
      expect(normalizePhone(once), once);
    });
  });

  group('formatPhone', () {
    test('groups Indian numbers, leaves others alone', () {
      expect(formatPhone('+919876543210'), '+91 98765 43210');
      expect(formatPhone('+14155552671'), '+14155552671');
    });
  });
}
