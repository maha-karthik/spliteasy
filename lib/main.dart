import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'data/repo.dart';
import 'services/auth_service.dart';
import 'ui/account_screen.dart';
import 'ui/welcome_screen.dart';
import 'ui/group_screen.dart';
import 'ui/proof_screen.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.init(); // optional cloud sign-in; the app works without it
  runApp(const SplitEasyApp());
}

class SplitEasyApp extends StatefulWidget {
  const SplitEasyApp({super.key});
  @override
  State<SplitEasyApp> createState() => _SplitEasyAppState();
}

class _SplitEasyAppState extends State<SplitEasyApp> {
  StreamSubscription? _sub;
  bool _busy = false; // one share dialog at a time

  @override
  void initState() {
    super.initState();
    // Cold start: wait until the first frame so the navigator exists before pushing a screen.
    ReceiveSharingIntent.instance.getInitialMedia().then((f) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleShared(f));
      ReceiveSharingIntent.instance.reset();
    });
    // App already running: shares arrive on the stream.
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(_handleShared);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handleShared(List<SharedMediaFile> files) async {
    if (files.isEmpty || _busy) return;
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    _busy = true;
    try {
      final groups = await Repo.groups();
      if (groups.isEmpty) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Create a group first, then share again')));
        }
        return;
      }
      DbRow? g = groups.length == 1 ? groups.first : null;
      if (g == null && ctx.mounted) {
        g = await showModalBottomSheet<DbRow>(
            context: ctx,
            builder: (c) => ListView(children: [
                  ListTile(title: Text('Add ${files.length > 1 ? '${files.length} proofs' : 'proof'} to which group?')),
                  for (final x in groups) ListTile(title: Text(x['name'] as String), onTap: () => Navigator.pop(c, x)),
                ]));
      }
      if (g == null) return;
      final chosen = g;
      // Several shared images are handled one after another, each confirmed by the user.
      for (final f in files) {
        final nav = navKey.currentState;
        if (nav == null) break;
        final isText = f.type == SharedMediaType.text || f.type == SharedMediaType.url;
        await nav.push(MaterialPageRoute(
            builder: (_) => ProofScreen(
                groupId: chosen['id'] as int,
                groupName: chosen['name'] as String,
                imagePath: isText ? null : f.path,
                sharedText: isText ? f.path : null)));
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SplitEasy',
      navigatorKey: navKey,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<DbRow> groups = [];

  @override
  void initState() {
    super.initState();
    Repo.changes.addListener(_load);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWelcome());
  }

  Future<void> _maybeWelcome() async {
    if (await Repo.meta('welcome_seen') == '1' || !mounted) return;
    await _showWelcome();
  }

  Future<void> _showWelcome() => Navigator.push(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => WelcomeScreen(onDone: () => Repo.setMeta('welcome_seen', '1'))));

  @override
  void dispose() {
    Repo.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final g = await Repo.groups();
    if (mounted) setState(() => groups = g);
  }

  Future<void> _create() async {
    final c = TextEditingController();
    var kitty = false;
    String? err;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                  title: const Text('New group'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: c,
                        autofocus: true,
                        maxLength: 40,
                        decoration: InputDecoration(labelText: 'Group / trip name', errorText: err)),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Trip kitty pool'),
                        subtitle: const Text('Everyone adds money up front; expenses draw from it'),
                        value: kitty,
                        onChanged: (v) => set(() => kitty = v)),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => c.text.trim().isEmpty ? set(() => err = 'Name cannot be empty') : Navigator.pop(ctx, true),
                        child: const Text('Create')),
                  ],
                )));
    if (ok == true) await Repo.addGroup(c.text.trim(), kitty);
  }

  Future<bool> _confirmDeleteGroup(DbRow g) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                title: Text('Delete ${g['name']}?'),
                content: const Text('All its expenses and payments will be deleted.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                ],
              )) ==
      true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SplitEasy'), actions: [
        IconButton(icon: const Icon(Icons.info_outline), tooltip: 'Why SplitEasy', onPressed: _showWelcome),
        StreamBuilder<bool>(
            stream: AuthService.signedIn,
            initialData: AuthService.user != null,
            builder: (c, snap) => IconButton(
                icon: Icon(snap.data == true ? Icons.account_circle : Icons.account_circle_outlined),
                tooltip: 'Account',
                onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const AccountScreen())))),
      ]),
      body: groups.isEmpty
          ? const Center(child: Text('Create your first group'))
          : ListView(children: [
              for (final g in groups)
                Dismissible(
                  key: ValueKey(g['id']),
                  direction: DismissDirection.endToStart,
                  background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
                  confirmDismiss: (_) => _confirmDeleteGroup(g),
                  onDismissed: (_) => Repo.deleteGroup(g['id'] as int),
                  child: ListTile(
                    leading: Icon(g['kitty'] == 1 ? Icons.savings : Icons.groups),
                    title: Text(g['name'] as String),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete group',
                        onPressed: () async {
                          if (await _confirmDeleteGroup(g)) await Repo.deleteGroup(g['id'] as int);
                        }),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupScreen(group: g))),
                  ),
                ),
            ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Group')),
    );
  }
}
