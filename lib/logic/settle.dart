// Pure Dart (no Flutter imports) so it can be unit-tested with `dart test`.
// All money is stored as integer paise to avoid floating point errors.

const int kittyId = 0; // pseudo-member representing the shared trip kitty

class ExpenseData {
  /// memberId -> paise paid. Empty map => paid from the kitty.
  final Map<int, int> payers;
  final int amount;
  final Map<int, int> shares; // memberId -> paise owed
  const ExpenseData(this.payers, this.amount, this.shares);
}

class SettlementData {
  final int from, to, amount;
  const SettlementData(this.from, this.to, this.amount);
}

class TopupData {
  final int member, amount;
  const TopupData(this.member, this.amount);
}

class Transfer {
  final int from, to, amount;
  const Transfer(this.from, this.to, this.amount);
  @override
  String toString() => '$from->$to:$amount';
}

/// Net = paid + topups + settlements sent - owed - settlements received.
/// Positive => the group owes this member. Negative => member owes the group.
Map<int, int> computeNet(
  List<int> members,
  List<ExpenseData> expenses,
  List<SettlementData> settlements,
  List<TopupData> topups, {
  bool kitty = false,
}) {
  final net = {for (final m in members) m: 0};
  void add(int id, int v) => net[id] = (net[id] ?? 0) + v;
  for (final e in expenses) {
    e.payers.forEach(add);
    e.shares.forEach((m, s) => add(m, -s));
  }
  for (final s in settlements) {
    add(s.from, s.amount);
    add(s.to, -s.amount);
  }
  for (final t in topups) {
    add(t.member, t.amount);
  }
  if (kitty) {
    final total = net.values.fold<int>(0, (a, b) => a + b);
    net[kittyId] = -total; // kitty owes members whatever is left in the pool
  }
  return net;
}

/// Greedy minimum-transaction settle-up.
List<Transfer> simplify(Map<int, int> net) {
  final debtors = <MapEntry<int, int>>[];
  final creditors = <MapEntry<int, int>>[];
  net.forEach((id, v) {
    if (v < 0) debtors.add(MapEntry(id, -v));
    if (v > 0) creditors.add(MapEntry(id, v));
  });
  debtors.sort((a, b) => b.value.compareTo(a.value));
  creditors.sort((a, b) => b.value.compareTo(a.value));
  final out = <Transfer>[];
  var i = 0, j = 0;
  final d = debtors.map((e) => e.value).toList();
  final c = creditors.map((e) => e.value).toList();
  while (i < debtors.length && j < creditors.length) {
    final amt = d[i] < c[j] ? d[i] : c[j];
    if (amt > 0) out.add(Transfer(debtors[i].key, creditors[j].key, amt));
    d[i] -= amt;
    c[j] -= amt;
    if (d[i] == 0) i++;
    if (c[j] == 0) j++;
  }
  return out;
}

// ---------- split helpers (return memberId -> paise, always summing to total) ----------

Map<int, int> splitEqual(int total, List<int> ids) {
  if (ids.isEmpty) return {};
  final base = total ~/ ids.length;
  var rem = total - base * ids.length;
  return {for (final id in ids) id: base + (rem-- > 0 ? 1 : 0)};
}

/// weights can be percentages or share counts. Weights must be >= 0.
Map<int, int> splitWeighted(int total, Map<int, double> weights) {
  final sum = weights.values.fold<double>(0, (a, b) => a + b);
  if (sum <= 0) return {};
  final out = <int, int>{};
  var assigned = 0;
  final ids = weights.keys.toList();
  for (final id in ids) {
    final v = (total * weights[id]! / sum).floor();
    out[id] = v;
    assigned += v;
  }
  var rem = total - assigned;
  for (var k = 0; rem > 0; k = (k + 1) % ids.length, rem--) {
    out[ids[k]] = out[ids[k]]! + 1;
  }
  return out;
}

/// Returns null if the parts sum to total, else a user-facing message.
String? validateExact(int total, Map<int, int> parts) {
  final s = parts.values.fold<int>(0, (a, b) => a + b);
  if (s == total) return null;
  final diff = (total - s) / 100;
  return diff > 0
      ? 'Rs ${diff.toStringAsFixed(2)} still unassigned'
      : 'Rs ${(-diff).toStringAsFixed(2)} over the total';
}

// ---------- strict input parsing (never throws) ----------

final _money = RegExp(r'^\d{1,9}(\.\d{1,2})?$');
final _weight = RegExp(r'^\d{1,6}(\.\d{1,4})?$');

/// "1,250.5" -> 125050. Returns null for anything that is not a plain non-negative
/// amount with at most 2 decimals (letters, minus sign, 2+ dots, Infinity, NaN, 1e5 ...).
int? parseMoney(String s) {
  final t = s.replaceAll(',', '').trim();
  if (!_money.hasMatch(t)) return null;
  final parts = t.split('.');
  final frac = (parts.length > 1 ? parts[1] : '').padRight(2, '0');
  return int.parse(parts[0]) * 100 + int.parse(frac);
}

int toPaise(String s) => parseMoney(s) ?? 0;

/// Percentages / share counts: non-negative, finite, at most 4 decimals.
double? parseWeight(String s) {
  final t = s.trim();
  if (!_weight.hasMatch(t)) return null;
  return double.parse(t);
}
