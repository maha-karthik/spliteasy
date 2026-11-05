// Pure Dart. Phone number cleanup for members picked from contacts or typed by hand.

bool _plausible(String digits) {
  if (digits.length < 8 || digits.length > 15 || digits.startsWith('0')) return false;
  if (digits.startsWith('91')) return RegExp(r'^91[6-9]\d{9}$').hasMatch(digits); // India: 10-digit mobile
  return true;
}

/// Normalises a phone number to E.164 ("+919876543210"), or returns null if it cannot be valid.
/// Accepts "98765 43210", "098765-43210", "+91 98765 43210", "91 9876543210", "0091 98765 43210"
/// and other international numbers written with a leading "+" or "00".
String? normalizePhone(String raw, {String defaultCountryCode = '91'}) {
  final s = raw.trim();
  var d = s.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return null;
  if (s.startsWith('+')) return _plausible(d) ? '+$d' : null;
  if (d.startsWith('00')) {
    d = d.substring(2);
    return _plausible(d) ? '+$d' : null;
  }
  if (d.length == 10) {
    d = defaultCountryCode + d;
  } else if (d.length == 11 && d.startsWith('0')) {
    d = defaultCountryCode + d.substring(1);
  } else if (!(d.length == 12 && d.startsWith(defaultCountryCode))) {
    return null;
  }
  return _plausible(d) ? '+$d' : null;
}

/// "+919876543210" -> "+91 98765 43210". Other numbers are returned unchanged.
String formatPhone(String e164) {
  if (RegExp(r'^\+91[6-9]\d{9}$').hasMatch(e164)) {
    return '+91 ${e164.substring(3, 8)} ${e164.substring(8)}';
  }
  return e164;
}
