import 'package:flutter/material.dart';

import '../theme/munji_theme.dart';
import 'capture_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';

/// The patient's five tabs: Home, Reports, Monitor, Guide, Profile.
/// Monitor is the 30-second ECG capture, which is where the patient's real
/// trace lives; the home screen links to it. Guide shows a holding screen
/// until it is built.
///
/// IndexedStack keeps every tab alive, so going to Profile and back does
/// not throw away the live ECG trace or restart the heart-rate timers.
class PatientShell extends StatefulWidget {
  const PatientShell({
    super.key,
    required this.isArabic,
    required this.onLocaleChanged,
    required this.fullName,
  });

  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;
  final String fullName;

  @override
  State<PatientShell> createState() => _PatientShellState();
}

class _PatientShellState extends State<PatientShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    final tabs = <_Tab>[
      _Tab(Icons.home_rounded, ar ? 'الرئيسية' : 'Home'),
      _Tab(Icons.insert_chart_outlined_rounded, ar ? 'التقارير' : 'Reports'),
      _Tab(Icons.monitor_heart_outlined, ar ? 'القياس' : 'Monitor'),
      _Tab(Icons.menu_book_rounded, ar ? 'الإرشادات' : 'Guide'),
      _Tab(Icons.person_outline_rounded, ar ? 'حسابي' : 'Profile'),
    ];

    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(
            isArabic: ar,
            fullName: widget.fullName,
            onOpenCapture: () => setState(() => _index = 2),
          ),
          ReportsScreen(isArabic: ar, fullName: widget.fullName),
          CaptureScreen(isArabic: ar, fullName: widget.fullName),
          _Soon(isArabic: ar, title: tabs[3].label, icon: tabs[3].icon),
          ProfileScreen(
            isArabic: ar,
            onLocaleChanged: widget.onLocaleChanged,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: MunjiColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x2100537A)),
            boxShadow: MunjiShadow.e2,
          ),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: _TabButton(
                    tab: tabs[i],
                    selected: i == _index,
                    onTap: () => setState(() => _index = i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab {
  const _Tab(this.icon, this.label);
  final IconData icon;
  final String label;
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? MunjiColors.blue : MunjiColors.muted;
    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? MunjiColors.blue50 : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tab.icon, size: 21, color: color),
              const SizedBox(height: 3),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Soon extends StatelessWidget {
  const _Soon({required this.isArabic, required this.title, required this.icon});

  final bool isArabic;
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(MunjiSpace.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 44, color: MunjiColors.blue500),
                const SizedBox(height: MunjiSpace.md),
                Text(title, style: MunjiText.h2),
                const SizedBox(height: MunjiSpace.xs),
                Text(
                  isArabic ? 'قريبًا' : 'Coming soon',
                  style: MunjiText.small,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
