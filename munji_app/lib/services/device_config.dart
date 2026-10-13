/// Everything the Munji firmware team told us, in one place.
///
/// Values confirmed with the hardware engineer. [RealMunjiDeviceService]
/// reads only from here — nothing else in the app changes when the firmware
/// evolves.
class DeviceConfig {
  DeviceConfig._();

  // ── 1. Finding the device ────────────────────────────────────────────────

  /// Devices advertise as MUNJI-XXXX, where XXXX comes from the ESP32-S3's
  /// hardware ID. Matching the prefix finds any Munji device.
  static const String namePrefix = 'MUNJI';

  // ── 2. The Munji GATT service ────────────────────────────────────────────

  static const String serviceUuid = '9f6b0001-7c8a-4f2b-a6d1-6c9e4a2f1000';

  /// Raw ECG stream. Notify, 18-byte packets.
  static const String ecgCharacteristicUuid =
      '9f6b0002-7c8a-4f2b-a6d1-6c9e4a2f1000';

  /// Electrode contact, 4 bytes. Byte 0 holds the flags (1 = detached):
  ///   bit 0  P electrode
  ///   bit 1  N electrode
  ///   bit 2  reference electrode
  ///   bit 3  any electrode
  /// Bytes 1–3 are the chip's raw status, kept for debugging.
  ///
  /// Firmware before Oct 2026 sent this only during its lead check between
  /// measurement cycles, not while streaming. Confirm with the newer build.
  static const String leadOffCharacteristicUuid =
      '9f6b0003-7c8a-4f2b-a6d1-6c9e4a2f1000';

  static const int leadOffP = 0x01;
  static const int leadOffN = 0x02;
  static const int leadOffRef = 0x04;
  static const int leadOffAny = 0x08;

  /// Heart data from the MAX30003 R-to-R detector, sent on each detected
  /// beat. 6 bytes, little-endian:
  ///   [0..1]  BPM x 10, uint16
  ///   [2..3]  RR interval in ms, uint16
  ///   [4..5]  RMSSD x 10, uint16 (0 until three beats are seen)
  ///
  /// The firmware ignores RR outside 250–2000 ms, so a rate below 30 never
  /// arrives here. That is fine for display; alert rules for severe
  /// bradycardia and pauses must work from the ECG itself (month 3).
  static const String heartCharacteristicUuid =
      '9f6b0004-7c8a-4f2b-a6d1-6c9e4a2f1000';

  static const int heartPacketBytes = 6;

  /// With no beat for this long, the app shows "no reading" rather than the
  /// last value.
  static const Duration heartStaleAfter = Duration(seconds: 5);

  /// How long after connecting before HRV is shown. The firmware computes
  /// RMSSD over its own short window and the first values after a link
  /// comes up are dominated by noise.
  static const Duration hrvWarmUp = Duration(minutes: 1);

  /// How often the patient's phone publishes the latest heart rate and HRV
  /// to `device/current` while the patch is connected. This is what the
  /// caregiver sees, so it bounds how stale their view can be.
  static const Duration liveWriteEvery = Duration(minutes: 1);

  // ── 3. Standard BLE services ─────────────────────────────────────────────

  /// Battery Service 0x180F → Battery Level 0x2A19.
  static const String batteryCharacteristicUuid =
      '00002a19-0000-1000-8000-00805f9b34fb';

  /// Device Information 0x180A → Serial Number 0x2A25.
  /// The stable per-device ID we store against the patient.
  static const String serialNumberCharacteristicUuid =
      '00002a25-0000-1000-8000-00805f9b34fb';

  /// Device Information 0x180A → Firmware Revision 0x2A26.
  /// Stored so a future bug can be traced to the firmware that produced it.
  static const String firmwareRevisionCharacteristicUuid =
      '00002a26-0000-1000-8000-00805f9b34fb';

  // ── 4. ECG packet layout ─────────────────────────────────────────────────
  //
  //   [0..1]   sequence number, uint16
  //   [2..17]  8 samples, int16 each
  //   total    18 bytes, ~31.25 packets per second

  /// Bytes before the first sample. Skipping these matters: read them as a
  /// sample and every packet opens with a spike that is not in the signal.
  static const int headerBytes = 2;

  static const int bytesPerSample = 2;
  static const int samplesPerPacket = 8;
  static const bool littleEndian = true;
  static const int sampleRateHz = 250;

  /// Samples are signed. Reading them unsigned turns the negative half of the
  /// waveform into very large positive numbers.
  static const bool signedSamples = true;

  /// Microvolts per sample unit. MAX30003 at gain 20 V/V, VREF 1000 mV,
  /// 18-bit result shifted right by 2 in firmware:
  ///   1000 / (2^17 x 20) x 4 = 0.0015258789 mV = 1.5258789 uV
  /// Written into every recording's header, so a later gain change cannot
  /// corrupt older recordings.
  static const double uvPerLsb = 1.5258789;

  // ── 5. Pairing ───────────────────────────────────────────────────────────

  /// No PIN in the current firmware. Bonding may be added later.
  static const bool requiresBonding = false;

  // ── 6. Bench testing ─────────────────────────────────────────────────────

  /// Shows the "Live readings" link on the device screen once connected.
  /// It opens an engineer view of the raw stream (waveform, beats, HRV,
  /// electrodes, battery, packet loss). Set to false before release to
  /// patients.
  static const bool showLiveReadings = true;

  // ── Derived ──────────────────────────────────────────────────────────────

  static bool get isConfigured =>
      namePrefix.isNotEmpty &&
      serviceUuid.isNotEmpty &&
      ecgCharacteristicUuid.isNotEmpty;

  static int get expectedPacketBytes =>
      headerBytes + (samplesPerPacket * bytesPerSample);
}
