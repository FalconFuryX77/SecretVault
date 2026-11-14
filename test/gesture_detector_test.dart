import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/services/gesture_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GestureDetectorService Trajectory Window Tests', () {
    test('Simulated Shake gesture produces Gesture.shake', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      Gesture? detected;
      detector.gestures.listen((g) => detected = g);
      detector.start();

      // Send initial motion trigger
      controller.add(AccelerometerEvent(8.0, 0.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 40));

      // Oscillate across X axis with sign changes and high peak-to-peak amplitude
      controller.add(AccelerometerEvent(-10.0, 1.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 60));

      controller.add(AccelerometerEvent(12.0, -1.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 60));

      controller.add(AccelerometerEvent(-8.0, 0.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 60));

      controller.add(AccelerometerEvent(6.0, 0.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 350)); // Allow window timer to fire

      expect(detected, equals(Gesture.shake));
      detector.dispose();
      await controller.close();
    });

    test('Simulated sustained Tilt Left produces Gesture.left', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      Gesture? detected;
      detector.gestures.listen((g) => detected = g);
      detector.start();

      for (int i = 0; i < 8; i++) {
        controller.add(AccelerometerEvent(7.5, 0.5, 6.2));
        await Future.delayed(const Duration(milliseconds: 40));
      }
      await Future.delayed(const Duration(milliseconds: 350));

      expect(detected, equals(Gesture.left));
      detector.dispose();
      await controller.close();
    });

    test('Simulated sustained Tilt Right produces Gesture.right', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      Gesture? detected;
      detector.gestures.listen((g) => detected = g);
      detector.start();

      for (int i = 0; i < 8; i++) {
        controller.add(AccelerometerEvent(-7.5, 0.5, 6.2));
        await Future.delayed(const Duration(milliseconds: 40));
      }
      await Future.delayed(const Duration(milliseconds: 350));

      expect(detected, equals(Gesture.right));
      detector.dispose();
      await controller.close();
    });

    test('Simulated sustained Tilt Down produces Gesture.down', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      Gesture? detected;
      detector.gestures.listen((g) => detected = g);
      detector.start();

      for (int i = 0; i < 8; i++) {
        controller.add(AccelerometerEvent(0.2, 7.8, 5.8));
        await Future.delayed(const Duration(milliseconds: 40));
      }
      await Future.delayed(const Duration(milliseconds: 350));

      expect(detected, equals(Gesture.down));
      detector.dispose();
      await controller.close();
    });

    test('Simulated sustained Tilt Up produces Gesture.up', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      Gesture? detected;
      detector.gestures.listen((g) => detected = g);
      detector.start();

      for (int i = 0; i < 8; i++) {
        controller.add(AccelerometerEvent(0.2, -7.8, 5.8));
        await Future.delayed(const Duration(milliseconds: 40));
      }
      await Future.delayed(const Duration(milliseconds: 350));

      expect(detected, equals(Gesture.up));
      detector.dispose();
      await controller.close();
    });

    test('Simulated high-g snap triggers onPanicTriggered stream', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      bool panicFired = false;
      detector.onPanicTriggered.listen((_) => panicFired = true);
      detector.start();

      // Sudden aggressive dynamic acceleration (> 35 m/s^2)
      controller.add(AccelerometerEvent(32.0, 18.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(panicFired, isTrue);
      detector.dispose();
      await controller.close();
    });

    test('Vehicle transit vibration is detected and filters road potholes / false shakes', () async {
      final controller = StreamController<AccelerometerEvent>.broadcast();
      final detector = GestureDetectorService(
        accelStream: controller.stream,
        gyroStream: const Stream.empty(),
      );

      Gesture? detected;
      bool panicFired = false;
      detector.gestures.listen((g) => detected = g);
      detector.onPanicTriggered.listen((_) => panicFired = true);
      detector.start();

      // Simulate vehicle / auto-rickshaw engine vibration & bumpy road (high continuous variance)
      for (int i = 0; i < 25; i++) {
        final jitter = (i % 2 == 0 ? 3.0 : -3.0);
        controller.add(AccelerometerEvent(jitter, jitter * 0.5, 9.8 + (i % 3 == 0 ? 2.5 : -2.5)));
        await Future.delayed(const Duration(milliseconds: 20));
      }

      // Verify vehicle transit state is active
      expect(detector.isVehicleMotionDetected, isTrue);

      // Simulate a sudden pothole / road bump (single shock of 20 m/s^2 dynamic accel)
      // Normal threshold was 22.0, which on rough roads would risk panic wipe
      controller.add(AccelerometerEvent(2.0, 1.0, 26.0)); // total ~26 - 9.8 = 16.2 dynamic
      await Future.delayed(const Duration(milliseconds: 60));

      // Pothole must NOT trigger panic wipe
      expect(panicFired, isFalse);

      // Single bump with 1 sign reversal must NOT trigger Shake in vehicle mode
      controller.add(AccelerometerEvent(5.0, 0.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 40));
      controller.add(AccelerometerEvent(-6.0, 0.0, 9.8));
      await Future.delayed(const Duration(milliseconds: 350));

      // False shake rejected
      expect(detected, isNull);

      // But a deliberate, firm tilt in vehicle mode (holding >= 6.0 m/s^2) DOES succeed
      for (int i = 0; i < 9; i++) {
        controller.add(AccelerometerEvent(7.8, 0.5, 6.0));
        await Future.delayed(const Duration(milliseconds: 40));
      }
      await Future.delayed(const Duration(milliseconds: 350));

      expect(detected, equals(Gesture.left));

      detector.dispose();
      await controller.close();
    });
  });
}
