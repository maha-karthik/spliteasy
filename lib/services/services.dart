import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:url_launcher/url_launcher.dart';
import '../data/repo.dart';

/// Typing guards: digits and one dot, max 2 decimals (money) / 4 decimals (percent, shares).
final moneyFormatter = FilteringTextInputFormatter.allow(RegExp(r'^\d{0,9}\.?\d{0,2}'));
final weightFormatter = FilteringTextInputFormatter.allow(RegExp(r'^\d{0,6}\.?\d{0,4}'));

String rupees(int paise) {
  final neg = paise < 0;
  final v = paise.abs();
  final whole = (v ~/ 100).toString();
  final frac = (v % 100).toString().padLeft(2, '0');
  String g; // Indian digit grouping: 12,34,567
  if (whole.length <= 3) {
    g = whole;
  } else {
    final last3 = whole.substring(whole.length - 3);
    var rest = whole.substring(0, whole.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    g = '${parts.join(',')},$last3';
  }
  return '${neg ? '-' : ''}₹$g${frac == '00' ? '' : '.$frac'}';
}

class KeptImage {
  final String path;
  final String hash;
  const KeptImage(this.path, this.hash);
}

class OcrService {
  /// On-device OCR (async via platform channel, so the UI thread is never blocked).
  static Future<String> read(String path) async {
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final res = await rec.processImage(InputImage.fromFilePath(path));
      return res.text;
    } finally {
      await rec.close();
    }
  }

  /// Copies a picked or shared image into app storage, downscaling anything larger than
  /// 1080x2400 (applies to Share Sheet images too), and returns a fingerprint of the result
  /// so the same screenshot cannot be recorded twice even when no UTR could be read.
  static Future<KeptImage> keep(String src) async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'proofs'));
    await dir.create(recursive: true);
    Uint8List out = await File(src).readAsBytes();
    var ext = p.extension(src);
    ui.ImmutableBuffer? buf;
    ui.ImageDescriptor? desc;
    try {
      buf = await ui.ImmutableBuffer.fromUint8List(out);
      desc = await ui.ImageDescriptor.encoded(buf); // reads size only, no full decode
      final scale = [1080 / desc.width, 2400 / desc.height, 1.0].reduce((a, b) => a < b ? a : b);
      if (scale < 1.0) {
        final codec = await desc.instantiateCodec(targetWidth: (desc.width * scale).round());
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        frame.image.dispose();
        codec.dispose();
        if (data != null) {
          out = data.buffer.asUint8List();
          ext = '.png';
        }
      }
    } catch (_) {
      // unsupported format or decode failure: keep the original bytes
    } finally {
      desc?.dispose();
      buf?.dispose();
    }
    final dest = p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}${ext.isEmpty ? '.jpg' : ext}');
    await File(dest).writeAsBytes(out);
    return KeptImage(dest, _fingerprint(out));
  }

  static String _fingerprint(Uint8List b) {
    var h = -3750763034362895579; // FNV-1a 64-bit offset basis (0xcbf29ce484222325 as signed int)
    for (final x in b) {
      h ^= x;
      h *= 0x100000001b3;
    }
    return '${h.toRadixString(16)}_${b.length}';
  }
}

class Soundbox {
  static final FlutterTts _tts = FlutterTts();
  static Future<void> announce(String message) async {
    try {
      await SystemSound.play(SystemSoundType.alert);
      await _tts.setLanguage('en-IN');
      await _tts.speak(message);
    } catch (_) {/* audio is best-effort */}
  }
}

class Upi {
  static Future<bool> pay({required String vpa, required String name, required int paise, String note = 'SplitEasy'}) {
    final uri = Uri(scheme: 'upi', host: 'pay', queryParameters: {
      'pa': vpa, 'pn': name, 'am': (paise / 100).toStringAsFixed(2), 'cu': 'INR', 'tn': note,
    });
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class PdfService {
  static String _r(int paise) => 'Rs ${(paise / 100).toStringAsFixed(2)}'; // base PDF fonts lack the rupee glyph

  static Future<String> build(String groupName, int gid, Ledger ledger) async {
    final doc = pw.Document();
    final ex = await Repo.expenses(gid);
    final st = await Repo.settlements(gid);
    final payerText = <int, String>{};
    for (final e in ex) {
      final py = await Repo.payersOf(e['id'] as int);
      payerText[e['id'] as int] = py.isEmpty ? 'Kitty' : py.entries.map((x) => '${ledger.nameOf(x.key)} ${_r(x.value)}').join(', ');
    }
    String d(Object? ms) {
      final t = DateTime.fromMillisecondsSinceEpoch(ms as int);
      return '${t.day.toString().padLeft(2, '0')}-${t.month.toString().padLeft(2, '0')}-${t.year}';
    }

    pw.TextStyle h() => pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      build: (c) => [
        pw.Header(level: 0, child: pw.Text('SplitEasy ledger: $groupName', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold))),
        pw.Text('Generated ${d(DateTime.now().millisecondsSinceEpoch)}'),
        pw.SizedBox(height: 12),
        pw.Text('Balances', style: h()),
        pw.TableHelper.fromTextArray(
          headers: ['Member', 'Net'],
          data: ledger.net.entries.map((e) => [ledger.nameOf(e.key), _r(e.value)]).toList(),
        ),
        pw.SizedBox(height: 12),
        pw.Text('Suggested settle-up', style: h()),
        pw.TableHelper.fromTextArray(
          headers: ['From', 'To', 'Amount'],
          data: ledger.transfers.map((t) => [ledger.nameOf(t.from), ledger.nameOf(t.to), _r(t.amount)]).toList(),
        ),
        pw.SizedBox(height: 12),
        pw.Text('Expenses', style: h()),
        pw.TableHelper.fromTextArray(
          headers: ['Date', 'Title', 'Paid by', 'Amount', 'Proof'],
          data: ex
              .map((e) => [d(e['date']), e['title'], payerText[e['id']], _r(e['amount'] as int), e['proof_path'] != null ? 'Yes' : '-'])
              .toList(),
        ),
        pw.SizedBox(height: 12),
        pw.Text('Payments', style: h()),
        pw.TableHelper.fromTextArray(
          headers: ['Date', 'From', 'To', 'Amount', 'Type', 'UTR / Ref', 'Status'],
          data: st
              .map((s) => [
                    d(s['date']), ledger.nameOf(s['from_id'] as int), ledger.nameOf(s['to_id'] as int),
                    _r(s['amount'] as int), s['method'], s['ref'] ?? '-', s['status']
                  ])
              .toList(),
        ),
      ],
    ));
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'ledger_${groupName.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.pdf'));
    await file.writeAsBytes(await doc.save());
    return file.path;
  }
}
