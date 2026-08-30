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
  });
}
