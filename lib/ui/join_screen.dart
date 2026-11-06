import 'package:flutter/material.dart';
import '../logic/invite.dart';
import '../services/auth_service.dart';
import '../services/group_sync.dart';
import 'account_screen.dart';

/// Enter an invite code, choose which existing person you are, and join the shared group.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});
  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final code = TextEditingController();
  String? err;
  bool busy = false;
  InviteInfo? info;
  String? me; // uid of the existing person chosen

  Future<void> _find() async {
    final c = normalizeInviteCode(code.text);
    if (c == null) {
      setState(() => err = 'A code has 6 letters and numbers');
      return;
    }
    setState(() {
      busy = true;
      err = null;
    });
    try {
      final i = await GroupSyncService.lookupInvite(c);
      setState(() {
        info = i;
        me = null;
        if (i == null) err = 'That code was not found or has expired.';
      });
    } catch (_) {
      setState(() => err = 'Could not check the code. Check your internet.');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _join() async {
    setState(() {
      busy = true;
      err = null;
    });
    try {
      await GroupSyncService.join(info!, me!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => err = 'Could not join. Ask the admin for a new code.');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = AuthService.user != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Join a group')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!AuthService.ready)
          const Text('Cloud sharing is not available in this build.')
        else if (!signedIn) ...[
          const Text('Sign in first so the admin knows who is joining.'),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen()));
                if (mounted) setState(() {});
              },
              child: const Text('Sign in')),
        ] else ...[
          TextField(
              controller: code,
              textCapitalization: TextCapitalization.characters,
              maxLength: 8,
              decoration: InputDecoration(labelText: 'Invite code', hintText: 'K7M2QX', errorText: err)),
          FilledButton(onPressed: busy ? null : _find, child: const Text('Find group')),
          if (busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (info != null) ...[
            const SizedBox(height: 16),
            Text('Group: ${info!.groupName}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Who are you in this group?'),
            RadioGroup<String>(
                groupValue: me,
                onChanged: (v) => setState(() => me = v),
                child: Column(children: [
                  for (final p in info!.people) RadioListTile<String>(title: Text(p.name), value: p.uid),
                ])),
            FilledButton(onPressed: busy || me == null ? null : _join, child: const Text('Join group')),
          ],
        ],
      ]),
    );
  }
}
