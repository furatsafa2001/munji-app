#!/bin/bash
# Run the app against the local Firebase emulator.
# Start the emulator first, in munji-backend2:  npm run emu
IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
if [ -z "$IP" ]; then
  echo "No LAN IP found. Is the Mac on Wi-Fi?"; exit 1
fi
echo "Emulator host: $IP  (phone and Mac must be on the same Wi-Fi)"
flutter run --dart-define=MUNJI_EMULATOR=true --dart-define=MUNJI_EMULATOR_HOST=$IP "$@"
