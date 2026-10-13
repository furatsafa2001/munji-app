# Munji app

## Run during development (local emulator)

1. In `munji-backend2`: `npm run emu` (leave it running)
2. Once, after the emulator starts: `npm run seed`
3. Here: `./scripts/run_emulator.sh` (macOS) or `.\scripts\run_emulator.ps1` (Windows)

Linking (patient to caregiver) runs on Cloud Functions, which are only in
the emulator until CNTXT billing is set up for me-central2. In a release
build the linking screens show "not available right now".

Phone and Mac must be on the same Wi-Fi. Test account: `safa.khan@email.com` / `Test1234!`

## Run against the real Firebase project

    flutter run

Creates real accounts. Storage is not available yet (waiting on CNTXT billing for me-central2), so recording uploads fail; everything else works.

## Build an APK for the hardware engineer

    flutter build apk --release

Output: `build/app/outputs/flutter-apk/app-release.apk`. Release builds always use the real project, never the emulator.

## Bench testing the patch

Device screen, once connected: "Live readings" (القراءات المباشرة). Turn off with `DeviceConfig.showLiveReadings` before patient release.
