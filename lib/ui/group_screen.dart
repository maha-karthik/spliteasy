import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../data/repo.dart';
import '../logic/settle.dart';
import '../services/auth_service.dart';
import '../services/group_sync.dart';
import '../services/services.dart';
import 'account_screen.dart';
import 'add_expense.dart';
import 'members_screen.dart';
import 'proof_screen.dart';

class GroupScreen extends StatefulWidget {
  final DbRow group;
  const GroupScreen({super.key, required this.group});
  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  Ledger? ledger;
  List<DbRow> expenses = [], payments = [];
  Map<int, String> payerText = {};
  bool shared = false, admin = true;
  late String gname = widget.group['name'] as String;
  int get gid => widget.group['id'] as int;
  bool get kitty => widget.group['kitty'] == 1;

  @override
  void initState() {
    super.initState();
    Repo.changes.addListener(_load); // refreshes after ANY write, including Share Sheet proofs
    _load();
  }

  @override
  void dispose() {
    Repo.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final l = await Repo.ledger(gid, kitty: kitty);
    final e = await Repo.expenses(gid);
    final p = await Repo.settlements(gid);
    final pt = <int, String>{};
    for (final x in e) {
      final py = await Repo.payersOf(x['id'] as int);
      pt[x['id'] as int] = py.isEmpty ? 'Kitty' : py.keys.map(l.nameOf).join(' + ');
    }
    final g = await Repo.groupById(gid);
    final isShared = g?['shared'] == 1;
    final isAdm = await Repo.isAdmin(gid, AuthService.user?.uid);
    if (mounted) setState(() { ledger = l; expenses = e; payments = p; payerText = pt; shared = isShared; admin = isAdm; });
  }

  Future<void> _go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                title: Text(title),
                content: Text(body),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                ],
              )) ==
      true;


  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _share() async {
    if (!AuthService.ready) return _say('Cloud sharing is not available in this build.');
    if (AuthService.user == null) {
      final go = await _confirm('Sign in to share', 'Sharing needs an account so only the people you invite can see this group.');
      if (go) await _go(const AccountScreen());
      return;
    }
    final yes = await _confirm('Share "$gname"?',
        'You become the admin. Member names, expenses and payment details are copied to the cloud so invited people can see them. Payment screenshots stay on your phone. You can still use the group offline.');
    if (!yes) return;
    try {
      await GroupSyncService.shareGroup(gid);
      if (mounted) await _invite();
    } catch (e) {
      _say('Could not share. Check your internet and try again.');
    }
  }

  Future<void> _invite() async {
    try {
      final code = await GroupSyncService.createInvite(gid);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
                title: const Text('Invite code'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  SelectableText(code, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, letterSpacing: 6)),
                  const SizedBox(height: 8),
                  const Text('Valid for 7 days. Send it on WhatsApp. They open SplitEasy, tap the group icon on the home screen, and enter it.'),
                ]),
                actions: [
                  TextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        Navigator.pop(c);
                      },
                      child: const Text('Copy')),
                  FilledButton(
                      onPressed: () {
                        Share.share('Join "$gname" on SplitEasy. Open the app, tap the group icon on the home screen and enter code $code (valid 7 days).');
                        Navigator.pop(c);
                      },
                      child: const Text('Share')),
                ],
              ));
    } catch (e) {
      _say('Could not create a code. Only the admin can, and you need internet.');
    }
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: gname);
    String? err;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                  title: const Text('Rename group'),
                  content: TextField(controller: c, autofocus: true, maxLength: 40, decoration: InputDecoration(errorText: err)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => c.text.trim().isEmpty ? set(() => err = 'Name cannot be empty') : Navigator.pop(ctx, true),
                        child: const Text('Save')),
                  ],
                )));
    if (ok == true) {
      await Repo.renameGroup(gid, c.text.trim());
      setState(() => gname = c.text.trim());
    }
  }

  Future<void> _topup() async {
    final ms = ledger!.active;
    if (ms.isEmpty) return;
    int? who = ms.first['id'] as int;
    final a = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
            builder: (c, set) => AlertDialog(
                  title: const Text('Add to kitty'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButton<int>(
                        value: who,
                        isExpanded: true,
                        items: ms.map((m) => DropdownMenuItem(value: m['id'] as int, child: Text(m['name'] as String))).toList(),
                        onChanged: (v) => set(() => who = v)),
                    TextField(
                        controller: a,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [moneyFormatter],
                        decoration: InputDecoration(labelText: 'Amount (₹)', errorText: err)),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () {
                          final v = parseMoney(a.text);
                          if (v == null || v <= 0) return set(() => err = 'Enter a valid amount above 0');
                          Navigator.pop(c, true);
                        },
                        child: const Text('Add')),
                  ],
                )));
    if (ok == true && who != null) await Repo.addTopup(gid, who!, toPaise(a.text));
  }

  Future<void> _exportPdf() async {
    final path = await PdfService.build(gname, gid, ledger!);
    await Share.shareXFiles([XFile(path)], text: 'Expense ledger: $gname');
  }

  @override
  Widget build(BuildContext context) {
    final l = ledger;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(gname),
          actions: [
            IconButton(icon: const Icon(Icons.group), tooltip: 'Members', onPressed: () => _go(MembersScreen(groupId: gid, kitty: kitty))),
            if (l != null) IconButton(icon: const Icon(Icons.picture_as_pdf), tooltip: 'Export PDF', onPressed: _exportPdf),
            if (shared)
              IconButton(
                  icon: const Icon(Icons.cloud_done_outlined),
                  tooltip: 'Shared group. Tap to sync now',
                  onPressed: () async {
                    await GroupSyncService.syncAll();
                    _say(GroupSyncService.status.value.isEmpty ? 'Synced' : GroupSyncService.status.value);
                  }),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') _rename();
                if (v == 'share') _share();
                if (v == 'invite') _invite();
              },
              itemBuilder: (_) => [
                if (admin) const PopupMenuItem(value: 'rename', child: Text('Rename group')),
                if (!shared) const PopupMenuItem(value: 'share', child: Text('Share group')),
                if (shared && admin) const PopupMenuItem(value: 'invite', child: Text('New invite code')),
              ],
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Expenses'), Tab(text: 'Balances'), Tab(text: 'Payments')]),
        ),
        body: l == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [_expensesTab(l), _balancesTab(l), _paymentsTab(l)]),
        floatingActionButton: l == null
            ? null
            : Builder(builder: (c) {
                final tc = DefaultTabController.of(c);
                return AnimatedBuilder(
                    animation: tc,
                    builder: (_, __) {
                      if (tc.index == 0) {
                        return FloatingActionButton.extended(
                            heroTag: 'exp',
                            onPressed: () => l.active.isEmpty ? _go(MembersScreen(groupId: gid, kitty: kitty)) : _go(AddExpenseScreen(groupId: gid)),
                            icon: const Icon(Icons.add),
                            label: Text(l.active.isEmpty ? 'Add members first' : 'Expense'));
                      }
                      if (tc.index == 2) {
                        return FloatingActionButton.extended(
                            heroTag: 'proof',
                            onPressed: () => l.active.length < 2
                                ? ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add at least two members first')))
                                : _go(ProofScreen(groupId: gid, groupName: gname)),
                            icon: const Icon(Icons.document_scanner),
                            label: const Text('Record payment'));
                      }
                      return const SizedBox.shrink();
                    });
              }),
      ),
    );
  }

  Widget _expensesTab(Ledger l) {
    if (expenses.isEmpty) return const Center(child: Text('No expenses yet'));
    return ListView(padding: const EdgeInsets.only(bottom: 140), children: [
      for (final e in expenses)
        Dismissible(
          key: ValueKey('e${e['id']}'),
          direction: DismissDirection.endToStart,
          background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
          confirmDismiss: (_) => _confirm('Delete "${e['title']}"?', 'Balances will be recalculated.'),
          onDismissed: (_) => Repo.deleteExpense(e['id'] as int),
          child: ListTile(
            leading: e['proof_path'] != null
                ? IconButton(icon: const Icon(Icons.receipt_long), tooltip: 'View proof', onPressed: () => _showProof(e['proof_path'] as String))
                : const Icon(Icons.shopping_bag_outlined),
            title: Text(e['title'] as String),
            subtitle: Text('${e['category']} • paid by ${payerText[e['id']] ?? ''} • ${e['split_type']}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(rupees(e['amount'] as int), style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete expense',
                  onPressed: () async {
                    if (await _confirm('Delete "${e['title']}"?', 'Balances will be recalculated.')) await Repo.deleteExpense(e['id'] as int);
                  }),
            ]),
            onTap: () => _go(AddExpenseScreen(groupId: gid, editing: e)),
          ),
        ),
    ]);
  }

  Widget _balancesTab(Ledger l) {
    return ListView(padding: const EdgeInsets.only(bottom: 140), children: [
      if (kitty)
        Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
                leading: const Icon(Icons.savings),
                title: const Text('Kitty balance'),
                subtitle: const Text('Tap to add money. Shared expenses draw from it first'),
                trailing: Text(rupees(l.kittyBalance), style: const TextStyle(fontWeight: FontWeight.bold)),
                onTap: _topup)),
      if (l.visible.isEmpty) const ListTile(title: Text('Add members to get started')),
      for (final m in l.visible)
        ListTile(
          title: Text(m['active'] == 1 ? m['name'] as String : '${m['name']} (removed)'),
          subtitle: Text(m['upi_id'] as String? ?? 'No UPI ID'),
          trailing: Text(
            (l.net[m['id']] ?? 0) == 0 ? 'Settled' : (l.net[m['id']]! > 0 ? 'gets ${rupees(l.net[m['id']]!)}' : 'owes ${rupees(-l.net[m['id']]!)}'),
            style: TextStyle(color: (l.net[m['id']] ?? 0) >= 0 ? Colors.green[700] : Colors.red[700], fontWeight: FontWeight.w600),
          ),
        ),
      const Divider(),
      const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text('Suggested settle-up', style: TextStyle(fontWeight: FontWeight.bold))),
      if (l.transfers.isEmpty) const ListTile(title: Text('All settled up')),
      for (final t in l.transfers)
        ListTile(
          title: Text('${l.nameOf(t.from)} pays ${l.nameOf(t.to)}'),
          subtitle: Text(rupees(t.amount)),
          trailing: Wrap(children: [
            if (t.from != kittyId && t.to != kittyId) ...[
              Builder(builder: (_) {
                final to = l.members.firstWhere((m) => m['id'] == t.to);
                final vpa = to['upi_id'] as String?;
                return IconButton(
                    tooltip: vpa == null ? 'No UPI ID for ${to['name']}' : 'Pay via UPI app',
                    icon: const Icon(Icons.bolt),
                    onPressed: vpa == null ? null : () => Upi.pay(vpa: vpa, name: to['name'] as String, paise: t.amount, note: gname));
              }),
              IconButton(
                  tooltip: 'Record payment (UPI proof, cash or offline)',
                  icon: const Icon(Icons.payments),
                  onPressed: () => _go(ProofScreen(groupId: gid, groupName: gname, presetFrom: t.from, presetTo: t.to, presetAmount: t.amount))),
            ],
          ]),
        ),
    ]);
  }

  Widget _paymentsTab(Ledger l) {
    if (payments.isEmpty) return const Center(child: Text('No payments recorded'));
    IconData icon(String s) => s == 'verified' ? Icons.verified : (s == 'manual' ? Icons.payments_outlined : Icons.help_outline);
    Color color(String s) => s == 'verified' ? Colors.green : (s == 'manual' ? Colors.blueGrey : Colors.orange);
    return ListView(padding: const EdgeInsets.only(bottom: 140), children: [
      for (final p in payments)
        Dismissible(
          key: ValueKey('p${p['id']}'),
          direction: DismissDirection.endToStart,
          background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
          confirmDismiss: (_) => _confirm('Delete this payment?', 'Balances will be recalculated.'),
          onDismissed: (_) => Repo.deleteSettlement(p['id'] as int),
          child: ListTile(
            leading: Icon(icon(p['status'] as String), color: color(p['status'] as String)),
            title: Text('${l.nameOf(p['from_id'] as int)} → ${l.nameOf(p['to_id'] as int)}'),
            subtitle: Text('${p['method']} • ${p['status']}${p['ref'] != null ? ' • UTR ${p['ref']}' : ''}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(rupees(p['amount'] as int), style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete payment',
                  onPressed: () async {
                    if (await _confirm('Delete this payment?', 'Balances will be recalculated.')) await Repo.deleteSettlement(p['id'] as int);
                  }),
            ]),
            onTap: p['proof_path'] == null ? null : () => _showProof(p['proof_path'] as String),
          ),
        ),
    ]);
  }

  void _showProof(String path) => showDialog(
      context: context,
      builder: (_) => Dialog(
          child: InteractiveViewer(
              child: Image.file(File(path),
                  errorBuilder: (_, __, ___) => const Padding(padding: EdgeInsets.all(24), child: Text('Image no longer available'))))));
}
