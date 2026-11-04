import 'package:flutter_test/flutter_test.dart';
import 'package:spliteasy/logic/proof_parser.dart';
import 'package:spliteasy/logic/settle.dart';

void main() {
  group('input parsing', () {
    test('valid amounts', () {
      expect(parseMoney('1250'), 125000);
      expect(parseMoney('1,250.5'), 125050);
      expect(parseMoney(' 0.07 '), 7);
    });
    test('rejects everything unsafe without throwing', () {
      for (final s in ['', 'abc', '-5', '1.2.3', 'Infinity', 'NaN', '1e5', '12.345', '.', '1234567890123']) {
        expect(parseMoney(s), isNull, reason: s);
      }
      expect(toPaise('abc'), 0);
    });
    test('weights', () {
      expect(parseWeight('33.5'), 33.5);
      expect(parseWeight('-1'), isNull);
      expect(parseWeight('Infinity'), isNull);
    });
  });

  group('splits', () {
    test('equal split distributes remainder paise', () {
      final s = splitEqual(1000, [1, 2, 3]);
      expect(s.values.fold<int>(0, (a, b) => a + b), 1000);
      expect(s[1], 334);
    });
    test('weighted split sums to total', () {
      expect(splitWeighted(10000, {1: 50, 2: 30, 3: 20}), {1: 5000, 2: 3000, 3: 2000});
      expect(splitWeighted(100, {1: 1, 2: 1, 3: 1}).values.fold<int>(0, (a, b) => a + b), 100);
    });
    test('exact validation', () {
      expect(validateExact(100, {1: 60, 2: 40}), isNull);
      expect(validateExact(100, {1: 60, 2: 30}), isNotNull);
    });
  });

  group('balances', () {
    test('checklist scenario: 3000 paid by A, equal split, B pays 600 partial', () {
      final exp = [ExpenseData({1: 300000}, 300000, splitEqual(300000, [1, 2, 3]))];
      final before = computeNet([1, 2, 3], exp, [], []);
      expect(before, {1: 200000, 2: -100000, 3: -100000});
      final after = computeNet([1, 2, 3], exp, [const SettlementData(2, 1, 60000)], []);
      expect(after[2], -40000); // B owes 400
      expect(after[1], 140000); // A still to receive 1400
      expect(after[3], -100000); // C unchanged
      expect(after.values.fold<int>(0, (a, b) => a + b), 0);
    });
    test('edited expense recalculates (1500 -> 900)', () {
      var net = computeNet([1, 2], [ExpenseData({1: 150000}, 150000, splitEqual(150000, [1, 2]))], [], []);
      expect(net[2], -75000);
      net = computeNet([1, 2], [ExpenseData({1: 90000}, 90000, splitEqual(90000, [1, 2]))], [], []);
      expect(net[2], -45000);
    });
    test('multiple payers', () {
      // 900 bill: A paid 600, B paid 300, split equally across A, B, C
      final net = computeNet([1, 2, 3], [ExpenseData({1: 60000, 2: 30000}, 90000, splitEqual(90000, [1, 2, 3]))], [], []);
      expect(net, {1: 30000, 2: 0, 3: -30000});
      expect(simplify(net).single.toString(), '3->1:30000');
    });
    test('partial and advance overpayment', () {
      final base = [ExpenseData({1: 20000}, 20000, splitEqual(20000, [1, 2]))];
      expect(computeNet([1, 2], base, [const SettlementData(2, 1, 4000)], [])[2], -6000);
      expect(computeNet([1, 2], base, [const SettlementData(2, 1, 15000)], [])[2], 5000);
    });
    test('simple trip simplifies to 2 transfers', () {
      final net = computeNet([1, 2, 3], [
        ExpenseData({1: 90000}, 90000, splitEqual(90000, [1, 2, 3])),
        ExpenseData({2: 30000}, 30000, splitEqual(30000, [1, 2, 3])),
      ], [], []);
      expect(net.values.fold<int>(0, (a, b) => a + b), 0);
      expect(simplify(net).length, 2);
    });
    test('kitty pool depletes before top-ups', () {
      final net = computeNet([1, 2], [ExpenseData({}, 6000, splitEqual(6000, [1, 2]))], [],
          [const TopupData(1, 5000), const TopupData(2, 5000)], kitty: true);
      expect(net[1], 2000);
      expect(net[kittyId], -4000);
      expect(net.values.fold<int>(0, (a, b) => a + b), 0);
    });
  });

  group('proof parser', () {
    test('GPay-style screenshot', () {
      final p = ProofParser.parse('Paid to RAHUL KUMAR\nrahul@okhdfcbank\n₹1,250\n'
          'Completed\n04 Nov 2026, 3:42 pm\nUPI transaction ID\n412345678901\n');
      expect(p.amountPaise, 125000);
      expect(p.ref, '412345678901');
      expect(p.upiIds, contains('rahul@okhdfcbank'));
      expect(p.isDebit, true);
      expect(p.when, DateTime(2026, 11, 4, 15, 42));
    });
    test('bank SMS with Rs. prefix', () {
      final p = ProofParser.parse('Rs.500.00 debited from A/c XX1234 on 04-11-26 to VPA amit@ybl '
          '(UPI Ref No 987654321098). Not you? Call 1800');
      expect(p.amountPaise, 50000);
      expect(p.ref, '987654321098');
      expect(p.upiIds, contains('amit@ybl'));
    });
    test('PhonePe transaction id', () {
      expect(ProofParser.parse('Payment successful\n₹300\nTransaction ID\nT2611041542123456789\n').ref, 'T2611041542123456789');
    });
    // Synthetic samples: real Paytm / BHIM screenshots still need to be checked on a device.
    test('Paytm-style and BHIM-style labels', () {
      expect(ProofParser.parse('Paid Successfully\n₹ 750\nUPI Ref No: 301234567890\n').ref, '301234567890');
      expect(ProofParser.parse('Transaction Successful\nINR 120.00\nTransaction Ref No. 612345678901\n').ref, '612345678901');
      expect(ProofParser.parse('Rs. 500 sent. Txn ID 512345678901').ref, '512345678901');
    });
    test('OCR letter/digit confusion in labeled UTR', () {
      expect(ProofParser.parse('UPI Ref No: 4123456789O1').ref, '412345678901');
      expect(ProofParser.parse('UTR 41234567890l').ref, '412345678901');
    });
    test('garbled text yields nothing instead of crashing', () {
      final p = ProofParser.parse('#@!~ x9 ???');
      expect(p.amountPaise, isNull);
      expect(p.ref, isNull);
    });
    test('member matching by upi then name', () {
      final ms = [const MemberLite(1, 'Rahul Kumar', 'rahul@okhdfcbank'), const MemberLite(2, 'Amit', null)];
      expect(ProofParser.matchMembers('x', ['rahul@okhdfcbank'], ms).single.id, 1);
      expect(ProofParser.matchMembers('Paid to AMIT S', [], ms).single.id, 2);
    });
    test('bill total prefers grand total', () {
      expect(ProofParser.parseBillTotal('Paneer 250.00\nSub Total 500.00\nGST 25.00\nGrand Total 525.00\n'), 52500);
    });
  });
}
