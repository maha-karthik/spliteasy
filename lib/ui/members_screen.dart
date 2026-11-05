import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/repo.dart';
import '../logic/contact_utils.dart';
import '../services/contact_service.dart';
import '../services/services.dart';

final _upiRe = RegExp(r'^[A-Za-z0-9.\-_]{2,}@[A-Za-z]{2,}$');

/// Add or edit a member. Returns true if something was saved.
/// Name can be typed or filled from Android's contact picker (no contacts permission needed).
/// Mobile number and UPI ID are both optional.
Future<bool> memberDialog(BuildContext context, int gid, {DbRow? existing, required List<DbRow> current}) async {
  final n = TextEditingController(text: existing?['name'] as String? ?? '');
  final ph = TextEditingController(text: formatPhone(existing?['phone'] as String? ?? ''));
  final u = TextEditingController(text: existing?['upi_id'] as String? ?? '');
  String? errName, errPhone, errUpi;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> fromContacts() async {
          try {
            final p = await ContactService.pick();
            if (p == null || !ctx.mounted) return; // user cancelled
            var chosen = p.phones.isEmpty ? null : p.phones.first;
            if (p.phones.length > 1) {
              chosen = await showDialog<String>(
                  context: ctx,
                  builder: (c) => SimpleDialog(
                        title: Text('Which number for ${p.name.isEmpty ? 'this contact' : p.name}?'),
                        children: [
                          for (final x in p.phones) SimpleDialogOption(onPressed: () => Navigator.pop(c, x), child: Text(formatPhone(x))),
                        ],
                      )) ??
                  p.phones.first;
            }
            if (!ctx.mounted) return;
            set(() {
              if (p.name.isNotEmpty) n.text = p.name.length > 30 ? p.name.substring(0, 30) : p.name;
              if (chosen != null) ph.text = formatPhone(chosen);
              errName = null;
              errPhone = chosen == null ? 'This contact has no mobile number. You can type one or leave it empty.' : null;
            });
          } catch (_) {
            if (ctx.mounted) set(() => errPhone = 'Contact picker is not available. Please type the details instead.');
          }
        }

        return AlertDialog(
          title: Text(existing == null ? 'Add member' : 'Edit member'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: TextField(controller: n, autofocus: existing == null, maxLength: 30, decoration: InputDecoration(labelText: 'Name', errorText: errName))),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: IconButton.filledTonal(
                      tooltip: 'Select from contacts', icon: const Icon(Icons.contacts), onPressed: fromContacts),
                ),
              ]),
              TextField(
                controller: ph,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s()]'))],
                decoration: InputDecoration(labelText: 'Mobile number (optional)', hintText: '98765 43210', errorText: errPhone),
              ),
              TextField(controller: u, decoration: InputDecoration(labelText: 'UPI ID (optional)', hintText: 'name@okhdfcbank', errorText: errUpi)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final name = n.text.trim();
                final upi = u.text.trim();
                final phRaw = ph.text.trim();
                final phone = phRaw.isEmpty ? null : normalizePhone(phRaw);
                String? eName, ePhone, eUpi;
                if (name.isEmpty) {
                  eName = 'Name cannot be empty';
                } else if (current.any((m) => m['id'] != existing?['id'] && (m['name'] as String).toLowerCase() == name.toLowerCase())) {
                  eName = 'A member with this name already exists';
                }
                if (phRaw.isNotEmpty && phone == null) {
                  ePhone = 'Enter a valid mobile number (10 digits, or start with + and the country code)';
                } else if (phone != null && current.any((m) => m['id'] != existing?['id'] && m['phone'] == phone)) {
                  ePhone = 'A member with this number already exists';
                }
                if (upi.isNotEmpty && !_upiRe.hasMatch(upi)) eUpi = 'UPI ID looks invalid (example: name@ybl)';
                set(() {
                  errName = eName;
                  errPhone = ePhone;
                  errUpi = eUpi;
                });
                if (eName == null && ePhone == null && eUpi == null) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) return false;
  final phone = ph.text.trim().isEmpty ? null : normalizePhone(ph.text);
  if (existing == null) {
    await Repo.addMember(gid, n.text.trim(), u.text, phone: phone);
  } else {
    await Repo.updateMember(existing['id'] as int, n.text.trim(), u.text, phone: phone);
  }
  return true;
}

class MembersScreen extends StatefulWidget {
  final int groupId;
  final bool kitty;
  const MembersScreen({super.key, required this.groupId, required this.kitty});
  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  Ledger? l;

  @override
  void initState() {
    super.initState();
    Repo.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    Repo.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final x = await Repo.ledger(widget.groupId, kitty: widget.kitty);
    if (mounted) setState(() => l = x);
  }

  Future<void> _remove(DbRow m) async {
    final bal = l!.net[m['id']] ?? 0;
    if (bal != 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${m['name']} ${bal > 0 ? 'is owed' : 'owes'} ${rupees(bal.abs())}. Settle up before removing.')));
      return;
    }
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text('Remove ${m['name']}?'),
              content: const Text('Past expenses keep their name for history. They will no longer appear in new expenses.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
              ],
            ));
    if (yes == true) await Repo.archiveMember(m['id'] as int);
  }

  String _subtitle(DbRow m) {
    final parts = <String>[];
    final phone = m['phone'] as String?;
    final upi = m['upi_id'] as String?;
    if (phone != null && phone.isNotEmpty) parts.add(formatPhone(phone));
    if (upi != null && upi.isNotEmpty) parts.add(upi);
    return parts.isEmpty ? 'No UPI ID' : parts.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final x = l;
    return Scaffold(
      appBar: AppBar(title: const Text('Members')),
      body: x == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              for (final m in x.active)
                ListTile(
                  title: Text(m['name'] as String),
                  subtitle: Text(_subtitle(m)),
                  trailing: Wrap(children: [
                    IconButton(icon: const Icon(Icons.edit), onPressed: () => memberDialog(context, widget.groupId, existing: m, current: x.active)),
                    IconButton(icon: const Icon(Icons.person_remove), onPressed: () => _remove(m)),
                  ]),
                ),
              if (x.active.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No members yet'))),
            ]),
      floatingActionButton: x == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => memberDialog(context, widget.groupId, current: x.active),
              icon: const Icon(Icons.person_add),
              label: const Text('Member')),
    );
  }
}
