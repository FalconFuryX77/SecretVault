import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/gesture.dart';

/// Transforms raw accelerometer data into discrete gesture events.
///
/// Uses a state machine approach:
///   IDLE → TRIGGERED → COOLDOWN → IDLE
///
/// The sensor must return to neutral (below threshold) before a new
/// gesture can be detected. This prevents a sustained tilt from
/// registering as multiple gestures.
class GestureDetectorService {
  final _controller = StreamController<Gesture>.broadcast();
  Stream<Gesture> get gestures => _controller.stream;

  StreamSubscription? _sub;

  // Thresholds
  static const double _tiltThreshold = 8.0;
  static const double _shakeThreshold = 25.0;
  static const double _neutralThreshold = 4.0; // Must drop below this to re-arm

  // State machine
  bool _armed = true; // Ready to detect
  DateTime _lastDetected = DateTime(0);
  static const _cooldown = Duration(milliseconds: 900);

  void start() {
    _sub?.cancel();
    _armed = true;
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen(_onEvent);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  void _onEvent(AccelerometerEvent e) {
    if (_controller.isClosed) return;

    final now = DateTime.now();
    final magnitude = e.x.abs() + e.y.abs() + e.z.abs();

    // Check if sensor returned to neutral → re-arm
    // Subtract ~9.8 for gravity on the dominant axis
    final tiltMagnitude = _maxTilt(e);
    if (!_armed && tiltMagnitude < _neutralThreshold && magnitude < _shakeThreshold) {
      _armed = true;
    }

    // Don't detect if not armed or in cooldown
    if (!_armed) return;
    if (now.difference(_lastDetected) < _cooldown) return;

    Gesture? detected;

    if (magnitude > _shakeThreshold) {
      detected = Gesture.shake;
    } else if (e.x > _tiltThreshold) {
      detected = Gesture.left;
    } else if (e.x < -_tiltThreshold) {
      detected = Gesture.right;
    } else if (e.y > _tiltThreshold) {
      detected = Gesture.down;
    } else if (e.y < -_tiltThreshold) {
      detected = Gesture.up;
    }

    if (detected != null) {
      _armed = false; // Must return to neutral before next detection
      _lastDetected = now;
      _controller.add(detected);
    }
  }

  /// Returns the maximum tilt value on X or Y axis.
  double _maxTilt(AccelerometerEvent e) {
    return e.x.abs() > e.y.abs() ? e.x.abs() : e.y.abs();
  }

  void dispose() {
    stop();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
