import 'package:flutter/material.dart';

class _Page {
  final IconData big;
  final List<IconData> orbit;
  final String title, body;
  final List<Color> colors;
  const _Page(this.big, this.orbit, this.title, this.body, this.colors);
}

const _pages = [
  _Page(Icons.groups_2_rounded, [Icons.restaurant, Icons.local_gas_station, Icons.hotel, Icons.movie],
      'Split bills, keep friendships', 'Trips, flatmates, dinners. Add who paid and who shared, and SplitEasy works out exactly who owes whom, to the paisa.',
      [Color(0xFF0F766E), Color(0xFF14B8A6)]),
  _Page(Icons.cloud_off_rounded, [Icons.lock, Icons.speed, Icons.battery_saver, Icons.flight],
      'Works without internet', 'Everything is saved on your phone first. No account needed, nothing leaves your phone unless you choose to share a group.',
      [Color(0xFF1D4ED8), Color(0xFF60A5FA)]),
  _Page(Icons.fact_check_rounded, [Icons.receipt_long, Icons.sms, Icons.image, Icons.currency_rupee],
      'Proof, not promises', 'Attach a payment screenshot or SMS. SplitEasy reads the amount and transaction number, blocks duplicates, and never marks a payment verified on its own.',
      [Color(0xFF7C3AED), Color(0xFFA78BFA)]),
  _Page(Icons.sync_rounded, [Icons.phone_android, Icons.person_add, Icons.notifications_active, Icons.verified_user],
      'Everyone on the same page', 'Sign in to share a group with an invite code. Each person sees the same expenses and balances, even after being offline.',
      [Color(0xFFEA580C), Color(0xFFFBBF24)]),
];

/// Shown on first launch, and from the info button on the home screen.
class WelcomeScreen extends StatefulWidget {
  final VoidCallback? onDone;
  const WelcomeScreen({super.key, this.onDone});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final ctl = PageController();
  int i = 0;

  void _finish() {
    widget.onDone?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final last = i == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _finish, child: Text(last ? '' : 'Skip'))),
          Expanded(
              child: PageView.builder(
                  controller: ctl,
                  itemCount: _pages.length,
                  onPageChanged: (v) => setState(() => i = v),
                  itemBuilder: (_, k) => _view(_pages[k]))),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var k = 0; k < _pages.length; k++)
              AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.all(4),
                  width: k == i ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: k == i ? Theme.of(context).colorScheme.primary : Colors.grey, borderRadius: BorderRadius.circular(4))),
          ]),
          Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                      onPressed: last ? _finish : () => ctl.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                      child: Text(last ? 'Get started' : 'Next', style: const TextStyle(fontSize: 17))))),
        ]),
      ),
    );
  }

  Widget _view(_Page p) {
    const spots = [Alignment(-0.9, -0.7), Alignment(0.9, -0.5), Alignment(-0.8, 0.8), Alignment(0.85, 0.7)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          height: 260,
          width: double.infinity,
          decoration: BoxDecoration(
              gradient: LinearGradient(colors: p.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(32)),
          child: Stack(children: [
            Positioned(right: -40, top: -40, child: CircleAvatar(radius: 90, backgroundColor: Colors.white.withValues(alpha: 0.12))),
            Positioned(left: -30, bottom: -50, child: CircleAvatar(radius: 80, backgroundColor: Colors.white.withValues(alpha: 0.10))),
            for (var k = 0; k < p.orbit.length; k++)
              Align(
                  alignment: spots[k],
                  child: CircleAvatar(radius: 24, backgroundColor: Colors.white.withValues(alpha: 0.22), child: Icon(p.orbit[k], color: Colors.white))),
            Center(
                child: Container(
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 18, offset: const Offset(0, 8))
                    ]),
                    child: Icon(p.big, size: 64, color: p.colors.first))),
          ]),
        ),
        const SizedBox(height: 32),
        Text(p.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text(p.body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, height: 1.4)),
      ]),
    );
  }
}
