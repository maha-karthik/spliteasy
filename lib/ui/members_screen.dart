import 'package:flutter/material.dart';
import '../data/repo.dart';
import '../services/services.dart';

final _upiRe = RegExp(r'^[A-Za-z0-9.\-_]{2,}@[A-Za-z]{2,}$');

/// Add or edit a member. Returns true if something was saved.
Future<bool> memberDialog(BuildContext context, int gid, {DbRow? existing, required List<DbRow> current}) async {
  final n = TextEditingController(text: existing?['name'] as String? ?? '');
  final u = TextEditingController(text: existing?['upi_id'] as String? ?? '');
  String? err;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(existing == null ? 'Add member' : 'Edit member'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, autofocus: true, maxLength: 30, decoration: InputDecoration(labelText: 'Name', errorText: err)),
          TextField(controller: u, decoration: const InputDecoration(labelText: 'UPI ID (optional)', hintText: 'name@okhdfcbank')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final name = n.text.trim();
              final upi = u.text.trim();
              final dup = current.any((m) => m['id'] != existing?['id'] && (m['name'] as String).toLowerCase() == name.toLowerCase());
              if (name.isEmpty) return set(() => err = 'Name cannot be empty');
              if (dup) return set(() => err = 'A member with this name already exists');
              if (upi.isNotEmpty && !_upiRe.hasMatch(upi)) return set(() => err = 'UPI ID looks invalid (example: name@ybl)');
              Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  if (existing == null) {
    await Repo.addMember(gid, n.text.trim(), u.text);
  } else {
    await Repo.updateMember(existing['id'] as int, n.text.trim(), u.text);
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
                  subtitle: Text(m['upi_id'] as String? ?? 'No UPI ID'),
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
