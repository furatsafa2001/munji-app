import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/device_service.dart';
import 'caregiver_screens.dart';
import 'device_screen.dart';
import 'patient_shell.dart';
import 'profile_screen.dart';

/// Decides where a verified user lands.
///
/// A patient who has never paired a device is sent through device setup once —
/// it is not optional, because Munji cannot monitor anything without it.
/// A paired patient lands on the home tabs; a caregiver on the list of
/// people they look after. The pairing flag lives in
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
        // An error (rules, network) must not leave the user on a spinner.
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

        // Only a patient's phone reports device status. start() is a no-op
        // once running, so rebuilds of this stream do not restart it.
        if (isPatient) {
          MunjiDevice.registry.start();
          MunjiDevice.hourly.start();
        }

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

        if (isPatient) {
          return PatientShell(
            isArabic: isArabic,
            onLocaleChanged: onLocaleChanged,
            fullName: (data['fullName'] ?? '') as String,
          );
        }

        return CaregiverShell(
          isArabic: isArabic,
          onLocaleChanged: onLocaleChanged,
        );
      },
    );
  }
}
