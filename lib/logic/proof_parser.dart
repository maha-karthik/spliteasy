// Pure Dart. Extracts payment details from OCR text of a UPI screenshot, a bank/UPI SMS,
// or a bill/receipt.

class ParsedProof {
  int? amountPaise;
  String? ref; // 12-digit UTR (or PhonePe T-id)
  List<String> upiIds;
  DateTime? when;
  bool? isDebit; // true = "paid/sent/debited", false = "received/credited"
  String raw;
  ParsedProof(this.raw, {this.amountPaise, this.ref, this.upiIds = const [], this.when, this.isDebit});
}

class MemberLite {
  final int id;
  final String name;
  final String? upiId;
  const MemberLite(this.id, this.name, this.upiId);
}

class ProofParser {
  static final _amtSymbol =
      RegExp(r'(?:₹|INR|Rs\.?)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', caseSensitive: false);
  static final _amtWord = RegExp(
      r'(?:amount|paid|sent|debited|credited|received)[^0-9\n]{0,14}([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false);
  static final _bareLine = RegExp(r'^[^\w]{0,2}([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{1,2})?|[0-9]{1,7}(?:\.[0-9]{1,2})?)$');
  // Captures O/o/I/l too: OCR often confuses them with 0/1 inside long reference numbers.
  static final _refLabeled = RegExp(
      r'(?:UTR|UPI\s*Ref(?:erence)?(?:\s*(?:No|ID|Number))?|(?:Transaction\s*)?Ref(?:erence)?\s*(?:No|ID|Number)|(?:UPI\s*)?Transaction\s*(?:ID|No)|Txn\s*(?:ID|No))[\s:\-\.#]{0,8}([0-9OoIl]{12})(?![0-9OoIl])',
      caseSensitive: false);

  /// Fixes OCR letter/digit confusion; returns null unless at least 6 characters were real digits.
  static String? _fixDigits(String s) {
    if (RegExp(r'\d').allMatches(s).length < 6) return null;
    return s.replaceAll(RegExp('[Oo]'), '0').replaceAll(RegExp('[Il]'), '1');
  }
  static final _ref12 = RegExp(r'(?<!\d)\d{12}(?!\d)');
  static final _phonePe = RegExp(r'\bT\d{16,22}\b');
  static final _upi = RegExp(r'[A-Za-z0-9.\-_]{2,}@[A-Za-z]{2,}');
  static final _dateText = RegExp(
      r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\.?,?\s+(\d{4})(?:,?\s+(?:at\s+)?(\d{1,2}):(\d{2})\s*([AaPp][Mm])?)?');
  static final _dateNum = RegExp(r'(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})');
  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12
  };

  static int? _paise(String s) {
    final v = double.tryParse(s.replaceAll(',', ''));
    return v == null ? null : (v * 100).round();
  }

  static ParsedProof parse(String raw) {
    final text = raw.replaceAll('\u00A0', ' ');
    final p = ParsedProof(text);

    // amount: symbol-prefixed first, then keyword, then a lone number on its own line
    final m1 = _amtSymbol.firstMatch(text);
    if (m1 != null) {
      p.amountPaise = _paise(m1.group(1)!);
    } else {
      final m2 = _amtWord.firstMatch(text);
      if (m2 != null) {
        p.amountPaise = _paise(m2.group(1)!);
      } else {
        for (final line in text.split('\n')) {
          final m3 = _bareLine.firstMatch(line.trim());
          if (m3 != null && m3.group(1)!.replaceAll(RegExp(r'[,.]'), '').length < 9) {
            p.amountPaise = _paise(m3.group(1)!);
            break;
          }
        }
      }
    }

    final labeled = _refLabeled.firstMatch(text)?.group(1);
    p.ref = (labeled == null ? null : _fixDigits(labeled)) ??
        _ref12.firstMatch(text)?.group(0) ??
        _phonePe.firstMatch(text)?.group(0);

    p.upiIds = _upi.allMatches(text).map((m) => m.group(0)!.toLowerCase()).toSet().toList();

    final low = text.toLowerCase();
    if (RegExp(r'debited|paid to|sent to|you paid|payment successful|money sent').hasMatch(low)) {
      p.isDebit = true;
    } else if (RegExp(r'credited|received from|you received').hasMatch(low)) {
      p.isDebit = false;
    }

    p.when = _parseDate(text);
    return p;
  }

  static DateTime? _parseDate(String t) {
    final a = _dateText.firstMatch(t);
    if (a != null) {
      final mon = _months[a.group(2)!.toLowerCase()];
      if (mon != null) {
        var h = int.tryParse(a.group(4) ?? '') ?? 0;
        final mi = int.tryParse(a.group(5) ?? '') ?? 0;
        final ap = a.group(6)?.toLowerCase();
        if (ap == 'pm' && h < 12) h += 12;
        if (ap == 'am' && h == 12) h = 0;
        return DateTime(int.parse(a.group(3)!), mon, int.parse(a.group(1)!), h, mi);
      }
    }
    final b = _dateNum.firstMatch(t);
    if (b != null) {
      var y = int.parse(b.group(3)!);
      if (y < 100) y += 2000;
      final d = int.parse(b.group(1)!), mo = int.parse(b.group(2)!);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) return DateTime(y, mo, d);
    }
    return null;
  }

  /// Members whose UPI id appears in the text; falls back to name-token matches.
  /// 0 results = nothing found, 1 = confident, >1 = ask the user to choose.
  static List<MemberLite> matchMembers(String raw, List<String> upiIds, List<MemberLite> members) {
    final byUpi = members
        .where((m) => m.upiId != null && upiIds.contains(m.upiId!.toLowerCase()))
        .toList();
    if (byUpi.isNotEmpty) return byUpi;
    final low = raw.toLowerCase();
    return members.where((m) {
      final tokens = m.name.toLowerCase().split(RegExp(r'\s+')).where((t) => t.length >= 3);
      return tokens.any(low.contains);
    }).toList();
  }

  /// Picks the grand total from a bill: "grand total" > "net payable/amount due" > "total".
  static int? parseBillTotal(String raw) {
    final lines = raw.split('\n');
    final num = RegExp(r'([0-9][0-9,]*\.[0-9]{2}|[0-9][0-9,]{2,})');
    int bestScore = 0;
    int? best;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].toLowerCase();
      int score = 0;
      if (l.contains('sub total') || l.contains('subtotal') || l.contains('total tax') || l.contains('gst')) {
        continue;
      }
      if (l.contains('grand total')) {
        score = 4;
      } else if (l.contains('net payable') || l.contains('amount due') || l.contains('total payable') || l.contains('net amount')) {
        score = 3;
      } else if (l.contains('total')) {
        score = 2;
      }
      if (score == 0) continue;
      var m = num.allMatches(lines[i]).toList();
      if (m.isEmpty && i + 1 < lines.length) m = num.allMatches(lines[i + 1]).toList();
      if (m.isEmpty) continue;
      final v = _paise(m.last.group(1)!);
      if (v != null && score >= bestScore) {
        bestScore = score;
        best = v;
      }
    }
    return best;
  }
}
