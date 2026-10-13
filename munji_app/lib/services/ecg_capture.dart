import 'dart:math' as math;
import 'dart:typed_data';

import 'device_config.dart';

/// The .ecg file, byte for byte what the backend's ecgFormat.js expects.
/// A change to either side is a format version bump.
///
///   offset  field         type      value
///   0       magic         4 bytes   "MUNJ"
///   4       version       uint16    1
///   6       sampleRateHz  uint16    250
///   8       uvPerLsb      float32   firmware constant
///   12      sampleCount   uint32    durationSec x 250
///   16      startedAtMs   int64     first sample, UTC epoch ms
///   24      reserved      8 bytes   zero
///   32      samples       int16 LE  raw device values, unprocessed
class EcgFile {
  static const headerBytes = 32;
  static const version = 1;

  static Uint8List build({
    required Int16List samples,
    required DateTime startedAt,
    int sampleRateHz = DeviceConfig.sampleRateHz,
    double uvPerLsb = DeviceConfig.uvPerLsb,
  }) {
    final out = ByteData(headerBytes + samples.length * 2);
    const magic = [0x4D, 0x55, 0x4E, 0x4A]; // "MUNJ"
    for (var i = 0; i < 4; i++) {
      out.setUint8(i, magic[i]);
    }
    out.setUint16(4, version, Endian.little);
    out.setUint16(6, sampleRateHz, Endian.little);
    out.setFloat32(8, uvPerLsb, Endian.little);
    out.setUint32(12, samples.length, Endian.little);
    out.setInt64(16, startedAt.toUtc().millisecondsSinceEpoch, Endian.little);
    // 24..31 reserved, already zero
    for (var i = 0; i < samples.length; i++) {
      out.setInt16(headerBytes + i * 2, samples[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }
}

/// Why a capture could not be completed.
enum CaptureFailure {
  /// The patch disconnected during the recording.
  disconnected,

  /// An electrode lost skin contact for too long.
  leadsOff,

  /// Packets stopped arriving.
  signalLost,

  /// Too many packets were dropped over the air for a usable trace.
  tooManyGaps,

  /// The file could not be uploaded.
  uploadFailed,

  /// The server checked the file and refused it.
  rejected,

  /// Recording storage is not set up in this environment yet.
  storageUnavailable,
}

/// Collects exactly [seconds] of ECG from the patch's packets.
///
/// The backend accepts only files with exactly 7500 samples, so the timing
/// of the trace must survive dropped packets. Each packet carries a 16-bit
/// sequence number; a gap is filled by holding the last sample, which keeps
/// every later sample at its true time and shows up as a short flat stretch
/// rather than squeezing the rest of the recording.
///
/// More than 2% filled (about 19 packets in 30 seconds) is too much to call
/// it a real recording, and the capture fails instead.
class CaptureBuffer {
  CaptureBuffer({this.seconds = 30, this.maxFilledFraction = 0.02})
      : samples = Int16List(seconds * DeviceConfig.sampleRateHz);

  final int seconds;
  final double maxFilledFraction;
  final Int16List samples;

  int _count = 0;
  int _filled = 0;
  int? _lastSequence;
  DateTime? _startedAt;
  final _bpms = <double>[];

  int get total => samples.length;
  int get count => _count;
  bool get isFull => _count >= total;
  double get progress => _count / total;
  int get filledSamples => _filled;
  double get filledFraction => total == 0 ? 0 : _filled / total;
  DateTime? get startedAt => _startedAt;

  /// Remaining whole seconds, for the countdown.
  int get secondsLeft =>
      ((total - _count) / DeviceConfig.sampleRateHz).ceil().clamp(0, seconds);

  /// Mean heart rate over the recording, from the patch's beat detector.
  double? get avgHr {
    if (_bpms.isEmpty) return null;
    return _bpms.reduce((a, b) => a + b) / _bpms.length;
  }

  void addBeat(double bpm) {
    if (bpm >= 20 && bpm <= 300) _bpms.add(bpm);
  }

  /// Returns a failure if this packet makes the recording unusable.
  CaptureFailure? addPacket({
    required int sequence,
    required List<int> packetSamples,
    required DateTime receivedAt,
  }) {
    if (isFull) return null;

    if (_startedAt == null) {
      // the packet arrives after its samples were taken
      final span = Duration(
          microseconds: packetSamples.length * 1000000 ~/ DeviceConfig.sampleRateHz);
      _startedAt = receivedAt.subtract(span);
    }

    final last = _lastSequence;
    if (last != null) {
      final gap = (sequence - last - 1) & 0xFFFF;
      if (gap > 0) {
        // a huge jump is a restart, not a few lost packets
        if (gap > 200) return CaptureFailure.tooManyGaps;
        final hold = _count > 0 ? samples[_count - 1] : 0;
        final n = math.min(gap * DeviceConfig.samplesPerPacket, total - _count);
        for (var i = 0; i < n; i++) {
          samples[_count++] = hold;
        }
        _filled += n;
        if (filledFraction > maxFilledFraction) return CaptureFailure.tooManyGaps;
      }
    }
    _lastSequence = sequence;

    for (final s in packetSamples) {
      if (isFull) break;
      samples[_count++] = s.clamp(-32768, 32767);
    }
    return null;
  }

  Uint8List toFile() {
    assert(isFull, 'capture not finished');
    return EcgFile.build(samples: samples, startedAt: _startedAt!);
  }
}

/// A recording read back from its .ecg file.
class EcgRecordingData {
  const EcgRecordingData({
    required this.startedAt,
    required this.sampleRateHz,
    required this.uvPerLsb,
    required this.samples,
  });

  final DateTime startedAt;
  final int sampleRateHz;
  final double uvPerLsb;
  final Int16List samples;

  Duration get duration =>
      Duration(milliseconds: samples.length * 1000 ~/ sampleRateHz);

  double mvAt(int i) => samples[i] * uvPerLsb / 1000;

  /// Parses bytes written by [EcgFile.build] (or the backend's
  /// buildRecording). Returns null for anything that is not a valid file.
  static EcgRecordingData? parse(Uint8List bytes) {
    if (bytes.length < EcgFile.headerBytes) return null;
    final d = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'MUNJ') return null;
    if (d.getUint16(4, Endian.little) != EcgFile.version) return null;
    final rate = d.getUint16(6, Endian.little);
    final scale = d.getFloat32(8, Endian.little);
    final count = d.getUint32(12, Endian.little);
    final startMs = d.getInt64(16, Endian.little);
    if (rate == 0 || bytes.length != EcgFile.headerBytes + count * 2) return null;
    final samples = Int16List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = d.getInt16(EcgFile.headerBytes + i * 2, Endian.little);
    }
    return EcgRecordingData(
      startedAt: DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true),
      sampleRateHz: rate,
      uvPerLsb: scale,
      samples: samples,
    );
  }
}
