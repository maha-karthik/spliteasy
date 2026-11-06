import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import '../logic/auth_utils.dart';
import '../services/auth_service.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final email = TextEditingController();
  final pass = TextEditingController();
  String? errEmail, errPass, message;
  bool busy = false;

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await job();
    } on FirebaseAuthException catch (e) {
      message = friendlyAuthError(e.code);
    } catch (e) {
      message = 'Something went wrong. Check your internet and try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  bool _checkEmail() {
    errEmail = isValidEmail(email.text) ? null : 'Enter a valid email';
    return errEmail == null;
  }

  bool _checkBoth({required bool strongPass}) {
    final e = _checkEmail();
    errPass = strongPass ? passwordProblem(pass.text) : (pass.text.isEmpty ? 'Enter your password' : null);
    setState(() {});
    return e && errPass == null;
  }

  Future<void> _reset() async {
    if (!_checkEmail()) {
      setState(() {});
      return;
    }
    await _run(() async {
      await AuthService.resetPassword(email.text);
      message = 'If that email has an account, a reset link is on its way.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!AuthService.ready)
          const Card(
              child: ListTile(
                  leading: Icon(Icons.cloud_off),
                  title: Text('Cloud sign-in is not available in this build'),
                  subtitle: Text('Everything still works on this phone without it.')))
        else
          StreamBuilder<bool>(
              stream: AuthService.signedIn,
              initialData: AuthService.user != null,
              builder: (_, snap) => snap.data == true ? _signedIn() : _signedOut()),
      ]),
    );
  }

  Widget _signedIn() {
    final u = AuthService.user;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
          child: ListTile(
              leading: const Icon(Icons.verified_user),
              title: Text(u?.displayName?.isNotEmpty == true ? u!.displayName! : (u?.email ?? 'Signed in')),
              subtitle: Text(u?.email ?? ''))),
      const SizedBox(height: 8),
      const Text('You are signed in. Sharing groups with other phones comes in the next update; your data stays on this phone until then.'),
      const SizedBox(height: 16),
      OutlinedButton.icon(
          onPressed: busy ? null : () => _run(AuthService.signOut), icon: const Icon(Icons.logout), label: const Text('Sign out')),
    ]);
  }

  Widget _signedOut() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Sign in only if you want to share groups with other people. Without it the app works fully on this phone.'),
      const SizedBox(height: 16),
      FilledButton.icon(
          onPressed: busy ? null : () => _run(AuthService.google), icon: const Icon(Icons.login), label: const Text('Continue with Google')),
      const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: Text('or use email'))),
      TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: InputDecoration(labelText: 'Email', errorText: errEmail)),
      TextField(
          controller: pass,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(labelText: 'Password', errorText: errPass)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: FilledButton.tonal(
                onPressed: busy
                    ? null
                    : () {
                        if (_checkBoth(strongPass: false)) _run(() => AuthService.emailSignIn(email.text, pass.text));
                      },
                child: const Text('Sign in'))),
        const SizedBox(width: 8),
        Expanded(
            child: OutlinedButton(
                onPressed: busy
                    ? null
                    : () {
                        if (_checkBoth(strongPass: true)) _run(() => AuthService.emailRegister(email.text, pass.text));
                      },
                child: const Text('Create account'))),
      ]),
      TextButton(onPressed: busy ? null : _reset, child: const Text('Forgot password?')),
      if (busy) const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator())),
      if (message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!, style: const TextStyle(color: Colors.orange))),
    ]);
  }
}
