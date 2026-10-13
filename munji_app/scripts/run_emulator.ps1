# Run the app against the local Firebase emulator (Windows PowerShell).
# Start the emulator first, in munji-backend2:  npm run emu
#
# If Windows refuses to run scripts, once per user:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

$ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Wi-Fi' -ErrorAction SilentlyContinue |
       Select-Object -First 1).IPAddress
if (-not $ip) {
  $ip = (Get-NetIPAddress -AddressFamily IPv4 |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
         Select-Object -First 1).IPAddress
}
if (-not $ip) {
  Write-Host 'No LAN IP found. Is the PC on Wi-Fi?'
  exit 1
}
Write-Host "Emulator host: $ip  (phone and PC must be on the same Wi-Fi)"
flutter run --dart-define=MUNJI_EMULATOR=true --dart-define=MUNJI_EMULATOR_HOST=$ip @args
