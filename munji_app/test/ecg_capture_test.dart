import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:munji_app/services/ecg_capture.dart';

/// Run with: flutter test
///
/// These pin the .ecg layout to what functions/src/ecgFormat.js reads.
/// If one of them fails, the server will reject every recording.
void main() {
  final t0 = DateTime.utc(2026, 10, 12, 9, 0, 0);

  List<int> packet(int base) => List.generate(8, (i) => base + i);

  CaptureBuffer fullBuffer() {
    final b = CaptureBuffer();
    for (var seq = 0; !b.isFull; seq++) {
      b.addPacket(sequence: seq & 0xFFFF, packetSamples: packet(seq), receivedAt: t0);
    }
    return b;
  }

  test('30 seconds is 7500 samples and a 15032-byte file', () {
    final b = fullBuffer();
    expect(b.count, 7500);
    expect(b.toFile().length, 32 + 7500 * 2);
  });

  test('header matches ecgFormat.js', () {
    final bytes = fullBuffer().toFile();
    final d = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'MUNJ');
    expect(d.getUint16(4, Endian.little), 1);
    expect(d.getUint16(6, Endian.little), 250);
    expect(d.getFloat32(8, Endian.little), closeTo(1.5258789, 1e-6));
    expect(d.getUint32(12, Endian.little), 7500);
    for (var i = 24; i < 32; i++) {
      expect(bytes[i], 0, reason: 'reserved byte $i');
    }
  });

  test('start time is the first sample, not the first packet arrival', () {
    final b = CaptureBuffer();
    b.addPacket(sequence: 0, packetSamples: packet(0), receivedAt: t0);
    // 8 samples at 250 Hz = 32 ms before the packet arrived
    expect(b.startedAt, t0.subtract(const Duration(milliseconds: 32)));
  });

  test('samples are little-endian int16 in order', () {
    final b = CaptureBuffer(seconds: 1);
    for (var seq = 0; !b.isFull; seq++) {
      b.addPacket(sequence: seq, packetSamples: [-2, -1, 0, 1, 2, 300, -300, 32767], receivedAt: t0);
    }
    final d = ByteData.sublistView(b.toFile());
    expect(d.getInt16(32, Endian.little), -2);
    expect(d.getInt16(32 + 5 * 2, Endian.little), 300);
    expect(d.getInt16(32 + 7 * 2, Endian.little), 32767);
  });

  test('a dropped packet is filled with the last sample, keeping time', () {
    final b = CaptureBuffer();
    b.addPacket(sequence: 0, packetSamples: packet(100), receivedAt: t0);
    // sequence 1 lost
    b.addPacket(sequence: 2, packetSamples: packet(200), receivedAt: t0);
    expect(b.count, 24);
    expect(b.filledSamples, 8);
    expect(b.samples.sublist(8, 16), List.filled(8, 107)); // held
    expect(b.samples[16], 200);
  });

  test('sequence wraparound at 65535 is not a gap', () {
    final b = CaptureBuffer();
    b.addPacket(sequence: 65535, packetSamples: packet(0), receivedAt: t0);
    b.addPacket(sequence: 0, packetSamples: packet(0), receivedAt: t0);
    expect(b.filledSamples, 0);
  });

  test('more than 2% filled fails the capture', () {
    final b = CaptureBuffer();
    b.addPacket(sequence: 0, packetSamples: packet(0), receivedAt: t0);
    // 20 lost packets = 160 samples > 150 allowed
    final f = b.addPacket(sequence: 21, packetSamples: packet(0), receivedAt: t0);
    expect(f, CaptureFailure.tooManyGaps);
  });

  test('a few lost packets are tolerated', () {
    final b = CaptureBuffer();
    b.addPacket(sequence: 0, packetSamples: packet(0), receivedAt: t0);
    final f = b.addPacket(sequence: 6, packetSamples: packet(0), receivedAt: t0);
    expect(f, isNull);
  });

  test('average heart rate ignores impossible values', () {
    final b = CaptureBuffer();
    b.addBeat(70);
    b.addBeat(80);
    b.addBeat(5);
    b.addBeat(400);
    expect(b.avgHr, 75);
  });

  test('a file reads back exactly as written (history screen)', () {
    final b = fullBuffer();
    final data = EcgRecordingData.parse(b.toFile())!;
    expect(data.samples.length, 7500);
    expect(data.sampleRateHz, 250);
    expect(data.samples[0], b.samples[0]);
    expect(data.samples[7499], b.samples[7499]);
    expect(data.startedAt.millisecondsSinceEpoch, b.startedAt!.millisecondsSinceEpoch);
    expect(data.duration, const Duration(seconds: 30));
  });

  test('anything that is not a recording is refused', () {
    expect(EcgRecordingData.parse(Uint8List(10)), isNull);
    final bytes = fullBuffer().toFile();
    expect(EcgRecordingData.parse(Uint8List.sublistView(bytes, 0, bytes.length - 2)), isNull);
    final bad = Uint8List.fromList(bytes)..[0] = 0x58;
    expect(EcgRecordingData.parse(bad), isNull);
  });

  test('the countdown starts at 30 and ends at 0', () {
    final b = CaptureBuffer();
    expect(b.secondsLeft, 30);
    expect(fullBuffer().secondsLeft, 0);
  });

  group('RMSSD from RR intervals', () {
    test('null with too few intervals', () {
      expect(CaptureBuffer.rmssdOf([800, 810, 790]), isNull);
    });

    test('steady rhythm gives zero', () {
      expect(CaptureBuffer.rmssdOf(List.filled(12, 800)), 0);
    });

    test('alternating 800/840 gives 40 ms', () {
      final rr = [for (var i = 0; i < 12; i++) i.isEven ? 800 : 840];
      expect(CaptureBuffer.rmssdOf(rr), closeTo(40, 1e-9));
    });

    test('a premature beat and its pause are left out', () {
      // six steady beats, a PVC (500) and its compensatory pause (1100),
      // six steady beats: without the filter RMSSD would be about 160 ms
      final rr = [...List.filled(6, 800), 500, 1100, ...List.filled(6, 800)];
      expect(CaptureBuffer.rmssdOf(rr), 0);
    });

    test('no value when too many beats are irregular', () {
      // bigeminy: every other beat premature
      final rr = [for (var i = 0; i < 20; i++) i.isEven ? 800 : 500];
      expect(CaptureBuffer.rmssdOf(rr), isNull);
    });

    test('the buffer ignores intervals the firmware would not send', () {
      final b = CaptureBuffer();
      for (var i = 0; i < 12; i++) {
        b.addBeat(75, rrMs: i.isEven ? 800 : 840);
      }
      b.addBeat(75, rrMs: 100); // out of range, dropped
      b.addBeat(75, rrMs: 3000); // out of range, dropped
      expect(b.rmssd, closeTo(40, 1e-9));
    });
  });
}
