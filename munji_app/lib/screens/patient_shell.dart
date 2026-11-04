import 'package:flutter/material.dart';

import '../theme/munji_theme.dart';
import '../widgets/vitals.dart';
import 'capture_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';

/// The patient's four tabs: Home, Reports, Monitor, Profile. (Guide comes
/// back when it has content; an empty "coming soon" tab is not shipped.)
/// Monitor is the 30-second ECG capture, which is where the patient's real
/// trace lives; the home screen links to it.
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
          ProfileScreen(
            isArabic: ar,
            onLocaleChanged: widget.onLocaleChanged,
          ),
        ],
      ),
      bottomNavigationBar: MunjiNavBar(
        index: _index,
        onTap: (i) => setState(() => _index = i),
        items: [for (final t in tabs) MunjiNavItem(t.icon, t.label)],
      ),
    );
  }
}

class _Tab {
  const _Tab(this.icon, this.label);
  final IconData icon;
  final String label;
}
