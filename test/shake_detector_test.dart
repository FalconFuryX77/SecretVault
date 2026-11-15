import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/services/shake_detector.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  test('a hard shake fires once', () async {
    final accel = StreamController<AccelerometerEvent>.broadcast();
    final detector = ShakeDetector(accelStream: accel.stream)..start();
    var shakes = 0;
    detector.onShake.listen((_) => shakes++);

    accel.add(AccelerometerEvent(32.0, 18.0, 9.8));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(shakes, 1);

    // A second spike within the cooldown doesn't fire again.
    accel.add(AccelerometerEvent(-32.0, -18.0, 9.8));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(shakes, 1);

    detector.dispose();
    await accel.close();
  });

  test('ordinary handling does not fire', () async {
    final accel = StreamController<AccelerometerEvent>.broadcast();
    final detector = ShakeDetector(accelStream: accel.stream)..start();
    var shakes = 0;
    detector.onShake.listen((_) => shakes++);

    // Picking up, tilting, setting down, holding it face down: all far
    // below a hard shake.
    for (final e in [
      AccelerometerEvent(0.0, 0.0, 9.8),
      AccelerometerEvent(7.5, 0.5, 6.2),
      AccelerometerEvent(-7.5, 0.5, 6.2),
      AccelerometerEvent(0.2, 7.8, 5.8),
      AccelerometerEvent(0.0, 0.0, -9.8),
      AccelerometerEvent(3.0, 3.0, 14.0),
    ]) {
      accel.add(e);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(shakes, 0);

    detector.dispose();
    await accel.close();
  });

  test('road vibration is recognised and a pothole does not fire', () async {
    final accel = StreamController<AccelerometerEvent>.broadcast();
    final detector = ShakeDetector(accelStream: accel.stream)..start();
    var shakes = 0;
    detector.onShake.listen((_) => shakes++);

    for (var i = 0; i < 30; i++) {
      final jitter = (i.isEven ? 1.0 : -1.0) * 2.0;
      accel.add(AccelerometerEvent(jitter, jitter * 0.5, 9.8 + (i % 3 == 0 ? 2.5 : -2.5)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(detector.isVehicleMotionDetected, isTrue);

    // A single ~16 m/s2 bump is ignored in transit.
    accel.add(AccelerometerEvent(2.0, 1.0, 26.0));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(shakes, 0);

    detector.dispose();
    await accel.close();
  });
}
