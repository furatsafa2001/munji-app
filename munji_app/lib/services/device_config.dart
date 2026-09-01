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

  /// Electrode contact. Notifies only when the state *changes* — so silence
  /// means nothing has changed, not that nothing is attached.
  static const String leadOffCharacteristicUuid =
      '9f6b0003-7c8a-4f2b-a6d1-6c9e4a2f1000';

  /// Heart rate, computed on-device. UUID not assigned by firmware yet.
  static const String heartRateCharacteristicUuid = '';

  /// HRV, computed on-device. UUID not assigned by firmware yet.
  static const String hrvCharacteristicUuid = '';

  // ── 3. Standard BLE services ─────────────────────────────────────────────

  /// Battery Service 0x180F → Battery Level 0x2A19.
  static const String batteryCharacteristicUuid =
      '00002a19-0000-1000-8000-00805f9b34fb';

  /// Device Information 0x180A → Serial Number 0x2A25.
  /// The stable per-device ID we store against the patient.
  static const String serialNumberCharacteristicUuid =
      '00002a25-0000-1000-8000-00805f9b34fb';

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

  // ── 5. Pairing ───────────────────────────────────────────────────────────

  /// No PIN in the current firmware. Bonding may be added later.
  static const bool requiresBonding = false;

  // ── Derived ──────────────────────────────────────────────────────────────

  static bool get isConfigured =>
      namePrefix.isNotEmpty &&
      serviceUuid.isNotEmpty &&
      ecgCharacteristicUuid.isNotEmpty;

  static int get expectedPacketBytes =>
      headerBytes + (samplesPerPacket * bytesPerSample);
}
