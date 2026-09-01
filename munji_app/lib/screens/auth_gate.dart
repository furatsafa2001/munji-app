import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'device_screen.dart';
import 'profile_screen.dart';

/// Decides where a verified user lands.
///
/// A patient who has never paired a device is sent through device setup once —
/// it is not optional, because Munji cannot monitor anything without it.
/// Everyone else goes straight to the profile. The pairing flag lives in
/// Firestore (`devicePaired`) rather than in the device service, because the
/// service is rebuilt on every launch and would otherwise forget.
class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.isArabic,
    required this.onLocaleChanged,
  });

  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          debugPrint('[authgate] error: ${snap.error}');
          return ProfileScreen(
            isArabic: isArabic,
            onLocaleChanged: onLocaleChanged,
          );
        }

        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snap.data!.data();
        debugPrint('[authgate] exists=${snap.data!.exists} '
            'role=${data?['role']} paired=${data?['devicePaired']}');

        // No profile document yet — let the profile screen surface the problem
        // and offer repair rather than trapping the user in a spinner.
        if (data == null) {
          return ProfileScreen(
            isArabic: isArabic,
            onLocaleChanged: onLocaleChanged,
          );
        }

        final isPatient = data['role'] == 'patient';
        final paired = data['devicePaired'] == true;

        if (isPatient && !paired) {
          return DeviceScreen(
            isArabic: isArabic,
            mode: DeviceScreenMode.setup,
            onDone: () async {
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .update({'devicePaired': true});
              // The stream above picks the change up and swaps the screen.
            },
          );
        }

        return ProfileScreen(
          isArabic: isArabic,
          onLocaleChanged: onLocaleChanged,
        );
      },
    );
  }
}
