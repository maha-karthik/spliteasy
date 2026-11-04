import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../data/repo.dart';
import '../logic/proof_parser.dart';
import '../logic/settle.dart';
import '../services/services.dart';

/// Add a new expense, or edit one when [editing] is given.
class AddExpenseScreen extends StatefulWidget {
  final int groupId;
  final int? initialAmount; // paise
  final String? proofPath;
  final int? initialPayer;
  final DbRow? editing;
  const AddExpenseScreen({super.key, required this.groupId, this.initialAmount, this.proofPath, this.initialPayer, this.editing});
  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  List<DbRow> members = [];
  bool kitty = false, ready = false;
  final titleC = TextEditingController();
  final amountC = TextEditingController();
  final noteC = TextEditingController();
  bool fromKitty = false, multiPay = false;
  int? payer;
  final payerSel = <int>{};
  final payerVals = <int, TextEditingController>{};
  String category = 'Food';
  String split = 'Equal';
  String? proof;
  final selected = <int>{};
  final values = <int, TextEditingController>{}; // exact amount / percent / share count per member
  static const cats = ['Food', 'Travel', 'Stay', 'Fuel', 'Shopping', 'Tickets', 'Other'];

  bool get isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    proof = widget.proofPath;
    if (widget.initialAmount != null) amountC.text = (widget.initialAmount! / 100).toStringAsFixed(2);
    _init();
  }

  Future<void> _init() async {
    final g = (await Repo.groups()).firstWhere((g) => g['id'] == widget.groupId);
    final all = await Repo.members(widget.groupId, all: true);
    final e = widget.editing;
    final sh = e == null ? <int, int>{} : await Repo.sharesOf(e['id'] as int);
    final py = e == null ? <int, int>{} : await Repo.payersOf(e['id'] as int);
    final involved = {...sh.keys, ...py.keys};
    final ms = all.where((m) => m['active'] == 1 || involved.contains(m['id'])).toList();
    if (!mounted) return;
    setState(() {
      kitty = g['kitty'] == 1;
      members = ms;
      for (final m in ms) {
        values[m['id'] as int] = TextEditingController();
        payerVals[m['id'] as int] = TextEditingController();
      }
      if (e != null) {
        titleC.text = e['title'] as String;
        amountC.text = ((e['amount'] as int) / 100).toStringAsFixed(2);
        noteC.text = (e['note'] as String?) ?? '';
        category = cats.contains(e['category']) ? e['category'] as String : 'Other';
        proof = e['proof_path'] as String?;
        split = 'Exact'; // editing keeps the stored amounts exactly; switch to Equal to re-split
        selected.addAll(sh.keys);
        sh.forEach((id, v) => values[id]!.text = (v / 100).toStringAsFixed(2));
        if (py.isEmpty) {
          fromKitty = true;
        } else if (py.length == 1) {
          payer = py.keys.first;
        } else {
          multiPay = true;
          payerSel.addAll(py.keys);
          py.forEach((id, v) => payerVals[id]!.text = (v / 100).toStringAsFixed(2));
        }
      } else {
        selected.addAll(ms.where((m) => m['active'] == 1).map((m) => m['id'] as int));
        payer = widget.initialPayer ?? (ms.isNotEmpty ? ms.first['id'] as int : null);
      }
      ready = true;
    });
  }

  String _name(int id) => members.firstWhere((m) => m['id'] == id)['name'] as String;

  Future<void> _attach() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1080, maxHeight: 2400, imageQuality: 85);
    if (f == null) return;
    final kept = await OcrService.keep(f.path);
    setState(() => proof = kept.path);
    if (amountC.text.isEmpty) {
      final t = ProofParser.parseBillTotal(await OcrService.read(kept.path));
      if (t != null && mounted) setState(() => amountC.text = (t / 100).toStringAsFixed(2));
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    final title = titleC.text.trim();
    if (title.isEmpty) return _snack('Enter what the expense was for');
    final total = parseMoney(amountC.text);
    if (total == null || total <= 0) return _snack('Enter a valid amount above 0 (max 2 decimals)');
    final ids = selected.toList();
    if (ids.isEmpty) return _snack('Select at least one person to split with');

    // ---- who paid ----
    Map<int, int> payers;
    if (fromKitty) {
      payers = {};
    } else if (multiPay) {
      payers = {};
      for (final id in payerSel) {
        final v = parseMoney(payerVals[id]!.text);
        if (v == null || v <= 0) return _snack('Enter the amount ${_name(id)} paid');
        payers[id] = v;
      }
      if (payers.isEmpty) return _snack('Select who paid');
      final err = validateExact(total, payers);
      if (err != null) return _snack('Payers: $err');
    } else {
      if (payer == null) return _snack('Choose who paid');
      payers = {payer!: total};
    }

    // ---- how it is split ----
    Map<int, int> shares;
    switch (split) {
      case 'Exact':
        shares = {};
        for (final id in ids) {
          final v = parseMoney(values[id]!.text);
          if (v == null) return _snack('Enter a valid amount for ${_name(id)}');
          shares[id] = v;
        }
        final err = validateExact(total, shares);
        if (err != null) return _snack('Split: $err');
        break;
      case 'Percent':
      case 'Shares':
        final w = <int, double>{};
        for (final id in ids) {
          final v = parseWeight(values[id]!.text);
          if (v == null) return _snack('Enter a valid ${split == 'Percent' ? 'percentage' : 'share count'} for ${_name(id)}');
          w[id] = v;
        }
        if (split == 'Percent' && (w.values.fold<double>(0, (a, b) => a + b) - 100).abs() > 0.01) {
          return _snack('Percentages must add up to 100');
        }
        shares = splitWeighted(total, w);
        if (shares.isEmpty) return _snack('Enter at least one share above 0');
        break;
      default:
        shares = splitEqual(total, ids);
    }

    final row = <String, Object?>{
      'group_id': widget.groupId,
      'title': title,
      'amount': total,
      'category': category,
      'note': noteC.text.trim(),
      'split_type': split,
      'proof_path': proof,
      'date': isEdit ? widget.editing!['date'] : DateTime.now().millisecondsSinceEpoch,
    };
    if (isEdit) {
      await Repo.updateExpense(widget.editing!['id'] as int, row, payers, shares);
    } else {
      await Repo.addExpense(row, payers, shares);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Widget _payerSection() {
    final items = members.map((m) => DropdownMenuItem(value: m['id'] as int, child: Text(m['name'] as String))).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (kitty) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pay from kitty'), value: fromKitty, onChanged: (v) => setState(() => fromKitty = v)),
      if (!fromKitty) ...[
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Multiple payers'), value: multiPay, onChanged: (v) => setState(() => multiPay = v)),
        if (!multiPay)
          DropdownButtonFormField<int>(
              value: payer, items: items, onChanged: (v) => setState(() => payer = v),
              decoration: const InputDecoration(labelText: 'Paid by', border: OutlineInputBorder()))
        else
          for (final m in members)
            Row(children: [
              Checkbox(value: payerSel.contains(m['id']), onChanged: (v) => setState(() => v! ? payerSel.add(m['id'] as int) : payerSel.remove(m['id']))),
              Expanded(child: Text(m['name'] as String)),
              if (payerSel.contains(m['id']))
                SizedBox(
                    width: 100,
                    child: TextField(
                        controller: payerVals[m['id']],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [moneyFormatter],
                        decoration: const InputDecoration(hintText: '₹ paid'))),
            ]),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit expense' : 'Add expense')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: titleC, maxLength: 60, decoration: const InputDecoration(labelText: 'What was it for?', border: OutlineInputBorder())),
        const SizedBox(height: 4),
        TextField(
            controller: amountC,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [moneyFormatter],
            decoration: const InputDecoration(labelText: 'Amount (₹)', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
            value: category, items: cats.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => category = v!), decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        _payerSection(),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'Equal', label: Text('Equal')),
            ButtonSegment(value: 'Exact', label: Text('₹')),
            ButtonSegment(value: 'Percent', label: Text('%')),
            ButtonSegment(value: 'Shares', label: Text('Shares')),
          ],
          selected: {split},
          onSelectionChanged: (s) => setState(() {
            split = s.first;
            for (final c in values.values) {
              c.text = split == 'Shares' ? '1' : '';
            }
          }),
        ),
        if (isEdit && split == 'Exact')
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('Showing the saved split. Change the amount? Switch to Equal to re-split.', style: TextStyle(fontSize: 12))),
        const SizedBox(height: 8),
        for (final m in members)
          Row(children: [
            Checkbox(value: selected.contains(m['id']), onChanged: (v) => setState(() => v! ? selected.add(m['id'] as int) : selected.remove(m['id']))),
            Expanded(child: Text(m['name'] as String)),
            if (split != 'Equal' && selected.contains(m['id']))
              SizedBox(
                  width: 90,
                  child: TextField(
                      controller: values[m['id']],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [split == 'Exact' ? moneyFormatter : weightFormatter],
                      decoration: InputDecoration(hintText: split == 'Percent' ? '%' : split == 'Shares' ? 'x' : '₹'))),
          ]),
        const SizedBox(height: 8),
        TextField(controller: noteC, maxLength: 120, decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton.icon(onPressed: _attach, icon: const Icon(Icons.attach_file), label: Text(proof == null ? 'Attach bill/proof' : 'Change proof')),
          const SizedBox(width: 12),
          if (proof != null) SizedBox(height: 48, child: Image.file(File(proof!), errorBuilder: (_, __, ___) => const Icon(Icons.image))),
        ]),
        const SizedBox(height: 20),
        FilledButton(onPressed: _save, child: Text(isEdit ? 'Save changes' : 'Save expense')),
      ]),
    );
  }
}
