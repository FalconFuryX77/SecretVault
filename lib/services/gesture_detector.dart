import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/gesture.dart';

/// Transforms raw accelerometer data into discrete gesture events
/// using a sliding time-window trajectory analyzer.
///
/// Instead of making instantaneous single-event decisions (which causes
/// the initial jerk of a shake to be misread as a directional tilt),
/// this service collects a 320ms window of sensor trajectory to accurately distinguish:
/// 1. Directional oscillations / peak-to-peak reversals / dynamic jerk (SHAKE)
/// 2. Sustained single-axis gravity orientation (LEFT, RIGHT, UP, DOWN)
class GestureDetectorService {
  final _controller = StreamController<Gesture>.broadcast();
  Stream<Gesture> get gestures => _controller.stream;

  final Stream<AccelerometerEvent>? _customEventStream;
  StreamSubscription? _sub;
  Timer? _windowTimer;

  GestureDetectorService({Stream<AccelerometerEvent>? eventStream})
      : _customEventStream = eventStream;

  // ─── Thresholds ──────────────────────────────────────────
  static const double _motionStartTilt = 4.2; // Motion trigger threshold
  static const double _motionStartDynamic = 5.5; // Dynamic trigger threshold
  static const double _neutralThreshold = 3.5; // Must drop below to re-arm

  static const double _minTiltAverage = 4.5; // Minimum sustained tilt
  static const double _shakePeakToPeak = 14.0; // Peak-to-peak swing for shake
  static const double _shakeDynamicEnergy = 20.0; // Dynamic energy threshold

  // ─── State Machine ───────────────────────────────────────
  bool _armed = true; // Ready to detect new gesture
  bool _isCollecting = false; // Currently filling window
  DateTime _lastDetected = DateTime(0);

  final List<AccelerometerEvent> _windowSamples = [];
  static const _windowDuration = Duration(milliseconds: 320);
  static const _cooldown = Duration(milliseconds: 650);

  void start() {
    _sub?.cancel();
    _windowTimer?.cancel();
    _armed = true;
    _isCollecting = false;
    _windowSamples.clear();

    try {
      final stream = _customEventStream ??
          accelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 30),
          );
      _sub = stream.listen(
        _onEvent,
        onError: (_) {
          // Gracefully ignore stream errors on unsupported environments
        },
      );
    } catch (_) {}
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _windowTimer?.cancel();
    _windowTimer = null;
    _isCollecting = false;
    _windowSamples.clear();
  }

  void _onEvent(AccelerometerEvent e) {
    if (_controller.isClosed) return;

    final now = DateTime.now();
    final totalMagnitude = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final dynamicAcceleration = (totalMagnitude - 9.81).abs();
    final absX = e.x.abs();
    final absY = e.y.abs();

    // 1. Re-arm check: Device must return to flat neutral after cooldown
    if (!_armed) {
      if (now.difference(_lastDetected) >= _cooldown &&
          absX < _neutralThreshold &&
          absY < _neutralThreshold &&
          dynamicAcceleration < 4.0) {
        _armed = true;
        _isCollecting = false;
        _windowSamples.clear();
      }
      return;
    }

    // 2. If not currently collecting, check if deliberate motion started
    if (!_isCollecting) {
      final bool hasTiltMotion = absX >= _motionStartTilt || absY >= _motionStartTilt;
      final bool hasDynamicMotion = dynamicAcceleration >= _motionStartDynamic;

      if (hasTiltMotion || hasDynamicMotion) {
        _isCollecting = true;
        _windowSamples.clear();
        _windowSamples.add(e);

        // Schedule guaranteed evaluation after window completes
        _windowTimer?.cancel();
        _windowTimer = Timer(_windowDuration, _evaluateWindow);
      }
      return;
    }

    // 3. Collecting samples during the active window
    _windowSamples.add(e);
  }

  void _evaluateWindow() {
    _windowTimer?.cancel();
    _windowTimer = null;

    if (_windowSamples.isEmpty) {
      _isCollecting = false;
      return;
    }

    double minX = _windowSamples[0].x, maxX = _windowSamples[0].x;
    double minY = _windowSamples[0].y, maxY = _windowSamples[0].y;
    double minZ = _windowSamples[0].z, maxZ = _windowSamples[0].z;

    double sumX = 0, sumY = 0;
    double totalDynamicEnergy = 0;
    int signChangesX = 0;
    int signChangesY = 0;

    for (int i = 0; i < _windowSamples.length; i++) {
      final sample = _windowSamples[i];
      final mag = sqrt(sample.x * sample.x + sample.y * sample.y + sample.z * sample.z);
      final dyn = (mag - 9.81).abs();
      totalDynamicEnergy += dyn * dyn;

      if (sample.x < minX) minX = sample.x;
      if (sample.x > maxX) maxX = sample.x;
      if (sample.y < minY) minY = sample.y;
      if (sample.y > maxY) maxY = sample.y;
      if (sample.z < minZ) minZ = sample.z;
      if (sample.z > maxZ) maxZ = sample.z;

      // Sum latter half of window where user settles into tilt
      if (i >= _windowSamples.length ~/ 3) {
        sumX += sample.x;
        sumY += sample.y;
      }

      // Count sign reversals with significant amplitude
      if (i > 0) {
        final prev = _windowSamples[i - 1];
        if ((sample.x > 2.5 && prev.x < -2.5) || (sample.x < -2.5 && prev.x > 2.5)) {
          signChangesX++;
        }
        if ((sample.y > 2.5 && prev.y < -2.5) || (sample.y < -2.5 && prev.y > 2.5)) {
          signChangesY++;
        }
      }
    }

    final int sampleCount = _windowSamples.length;
    final int latterCount = sampleCount - (sampleCount ~/ 3);
    final double avgX = latterCount > 0 ? (sumX / latterCount) : 0;
    final double avgY = latterCount > 0 ? (sumY / latterCount) : 0;
    final double meanDynamicEnergy = totalDynamicEnergy / sampleCount;

    final double ptpX = maxX - minX;
    final double ptpY = maxY - minY;
    final double ptpZ = maxZ - minZ;
    final double maxPtp = max(ptpX, max(ptpY, ptpZ));

    Gesture? detected;

    // A. Check for Shake first based on trajectory oscillation, reversals, or dynamic swing
    final bool hasReversals = (signChangesX >= 1 || signChangesY >= 1);
    final bool hasLargeSwing = maxPtp >= _shakePeakToPeak;
    final bool hasHighEnergy = meanDynamicEnergy >= _shakeDynamicEnergy;

    if (hasReversals || (hasLargeSwing && hasHighEnergy) || maxPtp >= 18.0) {
      detected = Gesture.shake;
    } else {
      // B. Directional Tilt (sustained hold along dominant axis)
      final double absAvgX = avgX.abs();
      final double absAvgY = avgY.abs();

      final bool isXDominant = absAvgX >= _minTiltAverage && absAvgX > (absAvgY * 1.15);
      final bool isYDominant = absAvgY >= _minTiltAverage && absAvgY > (absAvgX * 1.15);

      if (isXDominant) {
        detected = avgX > 0 ? Gesture.left : Gesture.right;
      } else if (isYDominant) {
        detected = avgY > 0 ? Gesture.down : Gesture.up;
      }
    }

    _isCollecting = false;
    _windowSamples.clear();

    if (detected != null) {
      _armed = false;
      _lastDetected = DateTime.now();
      _controller.add(detected);
    }
  }

  void dispose() {
    stop();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
