import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../data/repo.dart';
import '../logic/proof_parser.dart';
import '../logic/settle.dart';
import '../services/services.dart';
import 'add_expense.dart';

/// One screen for every kind of payment evidence: UPI screenshot, bank/UPI SMS text, bill photo,
/// or no evidence at all (cash / offline payment).
/// Flow: pick/share/paste -> on-device OCR -> parse -> you confirm -> duplicate checks -> save.
class ProofScreen extends StatefulWidget {
  final int groupId;
  final String groupName;
  final String? imagePath; // from Share Sheet
  final String? sharedText; // SMS text from Share Sheet
  final int? presetFrom, presetTo, presetAmount; // from a suggested settle-up row
  const ProofScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    this.imagePath,
    this.sharedText,
    this.presetFrom,
    this.presetTo,
    this.presetAmount,
  });
  @override
  State<ProofScreen> createState() => _ProofScreenState();
}

class _ProofScreenState extends State<ProofScreen> {
  List<DbRow> members = [];
  bool bill = false; // false = settle-up payment, true = bill/receipt for a new expense
  bool busy = false;
  String? imagePath, imageHash, rawText;
  String payType = 'UPI';
  static const payTypes = ['UPI', 'Cash', 'Bank transfer', 'Other'];
  final amountC = TextEditingController();
  final refC = TextEditingController();
  final noteC = TextEditingController();
  int? fromId, toId;
  DateTime? when;
  String? hint;

  @override
  void initState() {
    super.initState();
    fromId = widget.presetFrom;
    toId = widget.presetTo;
    if (widget.presetAmount != null) amountC.text = (widget.presetAmount! / 100).toStringAsFixed(2);
    Repo.members(widget.groupId).then((m) {
      final ids = m.map((x) => x['id']).toSet();
      if (!ids.contains(fromId)) fromId = null; // a preset member may have been removed meanwhile
      if (!ids.contains(toId)) toId = null;
      setState(() => members = m);
      if (widget.imagePath != null) _processImage(widget.imagePath!);
      if (widget.sharedText != null) _processText(widget.sharedText!);
    });
  }

  Future<void> _pick(ImageSource src) async {
    final f = await ImagePicker().pickImage(source: src, maxWidth: 1080, maxHeight: 2400, imageQuality: 85);
    if (f != null) await _processImage(f.path);
  }

  Future<void> _processImage(String path) async {
    setState(() => busy = true);
    try {
      final kept = await OcrService.keep(path); // downscales large images, fingerprints the file
      final text = await OcrService.read(kept.path);
      imagePath = kept.path;
      imageHash = kept.hash;
      _apply(text);
      if (!bill && await Repo.hashExists(kept.hash)) {
        hint = 'Warning: this exact screenshot was already uploaded. ${hint ?? ''}';
      }
    } catch (e) {
      _snack('Could not read the image. You can type the details instead.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _paste() async {
    final c = TextEditingController(text: (await Clipboard.getData('text/plain'))?.text ?? '');
    if (!mounted) return;
    final txt = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Paste payment SMS'),
        content: TextField(controller: c, maxLines: 6, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Read')),
        ],
      ),
    );
    if (txt != null && txt.trim().isNotEmpty) _processText(txt);
  }

  void _processText(String t) => setState(() => _apply(t));

  void _apply(String text) {
    rawText = text;
    final mlite = members.map((m) => MemberLite(m['id'] as int, m['name'] as String, m['upi_id'] as String?)).toList();
    if (bill) {
      final total = ProofParser.parseBillTotal(text);
      if (total != null) amountC.text = (total / 100).toStringAsFixed(2);
      hint = total == null ? 'Could not find a total. Please type it.' : 'Total read from the bill. Please confirm.';
      return;
    }
    final p = ProofParser.parse(text);
    if (p.amountPaise != null) amountC.text = (p.amountPaise! / 100).toStringAsFixed(2);
    if (p.ref != null) refC.text = p.ref!;
    when = p.when;
    final matches = ProofParser.matchMembers(text, p.upiIds, mlite);
    // A debit screenshot names the receiver; a credit names the sender.
    if (matches.length == 1) {
      if (p.isDebit == false) {
        fromId = matches.first.id;
      } else {
        toId = matches.first.id;
      }
    }
    hint = matches.length > 1
        ? 'Several members match. Please choose who received it.'
        : matches.isEmpty
            ? 'Could not match a member. Please choose.'
            : 'Matched ${matches.first.name}. Please confirm.';
    if (p.amountPaise == null) hint = '$hint Amount not found, please type it.';
    if (p.ref == null) hint = '$hint No UTR found, so duplicate protection relies on the screenshot fingerprint only.';
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    final paise = parseMoney(amountC.text);
    if (paise == null || paise <= 0) return _snack('Enter a valid amount above 0 (max 2 decimals)');
    if (bill) {
      final ok = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
              builder: (_) => AddExpenseScreen(groupId: widget.groupId, initialAmount: paise, proofPath: imagePath, initialPayer: fromId)));
      if (ok == true && mounted) Navigator.pop(context, true);
      return;
    }
    if (fromId == null || toId == null) return _snack('Choose who paid and who received');
    if (fromId == toId) return _snack('Payer and receiver must be different');
    final ref = refC.text.trim();
    final hasProof = imagePath != null || rawText != null;
    try {
      await Repo.addSettlement(
        gid: widget.groupId, from: fromId!, to: toId!, amount: paise,
        ref: ref.isEmpty ? null : ref,
        proofHash: imageHash,
        method: imagePath != null ? 'screenshot' : (rawText != null ? 'sms' : payType.toLowerCase()),
        status: hasProof ? (ref.isNotEmpty ? 'verified' : 'unverified') : 'manual',
        proofPath: imagePath, note: noteC.text.trim(), when: when,
      );
    } on DuplicateException catch (e) {
      if (!mounted) return;
      showDialog(
          context: context,
          builder: (_) => AlertDialog(
                title: const Text('Duplicate receipt'),
                content: Text('$e. Nothing was changed.'),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ));
      return;
    }
    final to = members.firstWhere((m) => m['id'] == toId)['name'];
    final from = members.firstWhere((m) => m['id'] == fromId)['name'];
    Soundbox.announce('Received ${paise ~/ 100} rupees from $from to $to');
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final items = members.map((m) => DropdownMenuItem<int>(value: m['id'] as int, child: Text(m['name'] as String))).toList();
    return Scaffold(
      appBar: AppBar(title: Text(bill ? 'Add bill' : 'Record payment')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Payment'), icon: Icon(Icons.payments)),
            ButtonSegment(value: true, label: Text('Bill'), icon: Icon(Icons.receipt_long)),
          ],
          selected: {bill},
          onSelectionChanged: (s) => setState(() {
            bill = s.first;
            if (rawText != null) _apply(rawText!);
          }),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: () => _pick(ImageSource.gallery), icon: const Icon(Icons.photo), label: const Text('Gallery')),
          OutlinedButton.icon(onPressed: () => _pick(ImageSource.camera), icon: const Icon(Icons.photo_camera), label: const Text('Camera')),
          if (!bill) OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.sms), label: const Text('Paste SMS')),
        ]),
        if (!bill && imagePath == null && rawText == null)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No proof? Just fill the details below to record a cash or offline payment.')),
        if (busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (imagePath != null)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(imagePath!), height: 160, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()))),
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(hint!, style: TextStyle(color: Theme.of(context).colorScheme.primary))),
        const SizedBox(height: 12),
        TextField(
            controller: amountC,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [moneyFormatter],
            decoration: const InputDecoration(labelText: 'Amount (₹)', border: OutlineInputBorder())),
        if (!bill) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(value: fromId, items: items, onChanged: (v) => setState(() => fromId = v),
              decoration: const InputDecoration(labelText: 'Paid by', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(value: toId, items: items, onChanged: (v) => setState(() => toId = v),
              decoration: const InputDecoration(labelText: 'Received by', border: OutlineInputBorder())),
          if (imagePath == null && rawText == null) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
                value: payType,
                items: payTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                onChanged: (v) => setState(() => payType = v!),
                decoration: const InputDecoration(labelText: 'Paid how', border: OutlineInputBorder())),
          ],
          const SizedBox(height: 12),
          TextField(controller: refC, decoration: const InputDecoration(labelText: 'UTR / transaction ID (optional)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: noteC, maxLength: 80, decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder())),
        ] else ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(value: fromId, items: items, onChanged: (v) => setState(() => fromId = v),
              decoration: const InputDecoration(labelText: 'Who paid the bill', border: OutlineInputBorder())),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: Text(bill ? 'Continue to split' : 'Record payment')),
      ]),
    );
  }
}
