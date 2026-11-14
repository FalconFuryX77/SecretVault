import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/gesture.dart';

/// Detects discrete tilt gestures (Left, Right, Up, Down, Shake) and
/// high-intensity hard-shake panic events from sensor data.
class GestureDetectorService {
  final _gestureController = StreamController<Gesture>.broadcast();
  Stream<Gesture> get gestures => _gestureController.stream;

  final _panicController = StreamController<void>.broadcast();
  Stream<void> get onPanicTriggered => _panicController.stream;

  // Custom stream for unit tests
  final Stream<AccelerometerEvent>? _customAccelStream;
  StreamSubscription? _accelSub;

  // EMA Low-Pass Filter State
  static const double _filterAlpha = 0.40;
  double _smoothAx = 0.0, _smoothAy = 0.0, _smoothAz = 9.81;
  bool _filterInitialized = false;

  // Rolling dynamic acceleration buffer for transit/vehicle motion estimation
  static const int _rollingBufferSize = 40;
  final List<double> _rollingDynBuffer = [];
  DateTime _lastVehicleMotionTime = DateTime(0);
  int _consecutivePanicSamples = 0;
  DateTime _lastPanicTriggerTime = DateTime(0);

  /// Returns true if high ambient vibration (vehicle/transit/bumpy road) is currently detected.
  bool get isVehicleMotionDetected =>
      DateTime.now().difference(_lastVehicleMotionTime).inMilliseconds < 2500;

  // Discrete tilt & shake parameters
  static const double _motionStartTiltNormal = 4.0;
  static const double _motionStartTiltVehicle = 5.8;
  static const double _neutralThreshold = 3.2;
  bool _discreteArmed = true;
  DateTime _lastDiscreteDetected = DateTime(0);
  final List<AccelerometerEvent> _discreteWindowSamples = [];
  Timer? _discreteWindowTimer;

  GestureDetectorService({
    Stream<AccelerometerEvent>? accelStream,
    Stream<GyroscopeEvent>? gyroStream,
  }) : _customAccelStream = accelStream;

  void start() {
    stop();
    _discreteArmed = true;
    _filterInitialized = false;
    _discreteWindowSamples.clear();
    _rollingDynBuffer.clear();
    _consecutivePanicSamples = 0;

    if (_customAccelStream != null) {
      _accelSub = _customAccelStream.listen(_onAccelEvent, onError: (_) {});
    } else {
      try {
        _accelSub = accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 20),
        ).listen(_onAccelEvent, onError: (_) {});
      } catch (_) {}
    }
  }

  void stop() {
    _accelSub?.cancel();
    _accelSub = null;
    _discreteWindowTimer?.cancel();
    _discreteWindowTimer = null;
    _filterInitialized = false;
    _discreteWindowSamples.clear();
    _rollingDynBuffer.clear();
    _consecutivePanicSamples = 0;
  }

  void _onAccelEvent(AccelerometerEvent e) {
    if (!_filterInitialized) {
      _smoothAx = e.x;
      _smoothAy = e.y;
      _smoothAz = e.z;
      _filterInitialized = true;
    } else {
      _smoothAx = _smoothAx * (1.0 - _filterAlpha) + e.x * _filterAlpha;
      _smoothAy = _smoothAy * (1.0 - _filterAlpha) + e.y * _filterAlpha;
      _smoothAz = _smoothAz * (1.0 - _filterAlpha) + e.z * _filterAlpha;
    }

    _updateVehicleMotionState(e);
    _checkPanicMotion(e);
    _checkDiscreteMotion(e);
  }

  /// Evaluates rolling dynamic acceleration variance to identify continuous vehicle/transit vibration.
  void _updateVehicleMotionState(AccelerometerEvent e) {
    final totalMag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final dynAccel = (totalMag - 9.81).abs();

    _rollingDynBuffer.add(dynAccel);
    if (_rollingDynBuffer.length > _rollingBufferSize) {
      _rollingDynBuffer.removeAt(0);
    }

    if (_rollingDynBuffer.length >= 15) {
      double sum = 0.0;
      for (final val in _rollingDynBuffer) {
        sum += val;
      }
      final mean = sum / _rollingDynBuffer.length;

      double varSum = 0.0;
      for (final val in _rollingDynBuffer) {
        final diff = val - mean;
        varSum += diff * diff;
      }
      final variance = varSum / _rollingDynBuffer.length;

      // When continuous road rumble / vibration variance is high (e.g. car, auto-rickshaw)
      if (variance >= 0.5 || mean >= 1.4) {
        _lastVehicleMotionTime = DateTime.now();
      }
    }
  }

  /// Detects intense, hard shakes OR face-down flip.
  /// Dynamically raises thresholds and requires multi-sample confirmation in moving vehicles
  /// so road bumps and potholes never trigger an accidental emergency panic wipe.
  void _checkPanicMotion(AccelerometerEvent e) {
    final totalMag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final dynAccel = (totalMag - 9.81).abs();

    final inVehicle = isVehicleMotionDetected;
    final panicThreshold = inVehicle ? 34.0 : 22.0;
    final singleSampleThreshold = inVehicle ? 40.0 : 26.0;

    if (dynAccel >= panicThreshold) {
      _consecutivePanicSamples++;
    } else {
      _consecutivePanicSamples = 0;
    }

    final isHardShake = dynAccel >= singleSampleThreshold ||
        _consecutivePanicSamples >= (inVehicle ? 3 : 2);

    final isFaceDown = e.z <= -8.5 && _smoothAz <= -7.5;

    if (isHardShake || isFaceDown) {
      final now = DateTime.now();
      if (now.difference(_lastPanicTriggerTime).inMilliseconds >= 800) {
        _lastPanicTriggerTime = now;
        _consecutivePanicSamples = 0;
        if (!_panicController.isClosed) {
          _panicController.add(null);
        }
      }
    }
  }

  /// Processes accelerometer samples over a sliding window to identify
  /// Left, Right, Up, Down tilt gestures or deliberate multi-cycle Shake.
  void _checkDiscreteMotion(AccelerometerEvent e) {
    if (_gestureController.isClosed) return;
    final now = DateTime.now();
    final totalMag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final dyn = (totalMag - 9.81).abs();
    final absX = e.x.abs();
    final absY = e.y.abs();

    final inVehicle = isVehicleMotionDetected;
    final maxAllowedDynForRearm = inVehicle ? 5.5 : 3.5;

    if (!_discreteArmed) {
      // Re-arm when device is held relatively still and neutral
      if (now.difference(_lastDiscreteDetected) >= const Duration(milliseconds: 600) &&
          absX < _neutralThreshold &&
          absY < _neutralThreshold &&
          dyn < maxAllowedDynForRearm) {
        _discreteArmed = true;
        _discreteWindowSamples.clear();
      }
      return;
    }

    final startTilt = inVehicle ? _motionStartTiltVehicle : _motionStartTiltNormal;
    final startDyn = inVehicle ? 7.5 : 5.0;

    if (_discreteWindowSamples.isEmpty) {
      if (absX >= startTilt || absY >= startTilt || dyn >= startDyn) {
        _discreteWindowSamples.add(e);
        _discreteWindowTimer?.cancel();
        _discreteWindowTimer = Timer(const Duration(milliseconds: 320), _evaluateDiscreteWindow);
      }
      return;
    }

    _discreteWindowSamples.add(e);
  }

  void _evaluateDiscreteWindow() {
    _discreteWindowTimer?.cancel();
    _discreteWindowTimer = null;
    if (_discreteWindowSamples.isEmpty) return;

    final inVehicle = isVehicleMotionDetected;

    double minX = _discreteWindowSamples[0].x, maxX = _discreteWindowSamples[0].x;
    double minY = _discreteWindowSamples[0].y, maxY = _discreteWindowSamples[0].y;
    double minZ = _discreteWindowSamples[0].z, maxZ = _discreteWindowSamples[0].z;
    double sumX = 0, sumY = 0;
    double totalDyn = 0;
    int signChangesX = 0, signChangesY = 0;

    for (int i = 0; i < _discreteWindowSamples.length; i++) {
      final s = _discreteWindowSamples[i];
      final mag = sqrt(s.x * s.x + s.y * s.y + s.z * s.z);
      final dyn = (mag - 9.81).abs();
      totalDyn += dyn * dyn;

      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
      if (s.y < minY) minY = s.y;
      if (s.y > maxY) maxY = s.y;
      if (s.z < minZ) minZ = s.z;
      if (s.z > maxZ) maxZ = s.z;

      // Weight the sustained tail of the movement window for tilts
      if (i >= _discreteWindowSamples.length ~/ 3) {
        sumX += s.x;
        sumY += s.y;
      }

      if (i > 0) {
        final prev = _discreteWindowSamples[i - 1];
        if ((s.x > 2.5 && prev.x < -2.5) || (s.x < -2.5 && prev.x > 2.5)) signChangesX++;
        if ((s.y > 2.5 && prev.y < -2.5) || (s.y < -2.5 && prev.y > 2.5)) signChangesY++;
      }
    }

    final int count = _discreteWindowSamples.length;
    final int latterCount = count - (count ~/ 3);
    final double avgX = latterCount > 0 ? (sumX / latterCount) : 0;
    final double avgY = latterCount > 0 ? (sumY / latterCount) : 0;
    final double meanDyn = totalDyn / count;

    final double ptpX = maxX - minX;
    final double ptpY = maxY - minY;
    final double ptpZ = maxZ - minZ;
    final double maxPtp = max(ptpX, max(ptpY, ptpZ));

    Gesture? detected;

    if (inVehicle) {
      // In vehicle mode: reject single-bump road shocks.
      // Require multi-cycle deliberate hand oscillation (>= 3 sign reversals with high ptp)
      final isDeliberateMultiShake =
          ((signChangesX >= 3 || signChangesY >= 3) && maxPtp >= 17.0 && meanDyn >= 18.0) ||
          maxPtp >= 24.0;

      if (isDeliberateMultiShake) {
        detected = Gesture.shake;
      } else {
        final double absAvgX = avgX.abs();
        final double absAvgY = avgY.abs();
        // Higher threshold for deliberate tilt in transit
        if (absAvgX >= 5.5 && absAvgX > (absAvgY * 1.25)) {
          detected = avgX > 0 ? Gesture.left : Gesture.right;
        } else if (absAvgY >= 5.5 && absAvgY > (absAvgX * 1.25)) {
          detected = avgY > 0 ? Gesture.down : Gesture.up;
        }
      }
    } else {
      // Normal stationary / walking mode
      final isShake = (signChangesX >= 2 || signChangesY >= 2 || (maxPtp >= 13.0 && meanDyn >= 16.0) || maxPtp >= 16.0);
      if (isShake) {
        detected = Gesture.shake;
      } else {
        final double absAvgX = avgX.abs();
        final double absAvgY = avgY.abs();
        if (absAvgX >= 4.0 && absAvgX > (absAvgY * 1.15)) {
          detected = avgX > 0 ? Gesture.left : Gesture.right;
        } else if (absAvgY >= 4.0 && absAvgY > (absAvgX * 1.15)) {
          detected = avgY > 0 ? Gesture.down : Gesture.up;
        }
      }
    }

    _discreteWindowSamples.clear();
    if (detected != null) {
      _discreteArmed = false;
      _lastDiscreteDetected = DateTime.now();
      _gestureController.add(detected);
    }
  }

  void dispose() {
    stop();
    _gestureController.close();
    _panicController.close();
  }
}

