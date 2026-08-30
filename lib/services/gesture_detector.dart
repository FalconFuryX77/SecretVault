import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/gesture.dart';
import '../models/motion_point.dart';

/// 6-DOF Spatial Motion & 3D Wand Trajectory Service with reference baseline capture,
/// dynamic path integration, deadzone trimming, and panic detection.
class GestureDetectorService {
  // Streams
  final _gestureController = StreamController<Gesture>.broadcast();
  Stream<Gesture> get gestures => _gestureController.stream;

  final _motionPointController = StreamController<MotionPoint>.broadcast();
  Stream<MotionPoint> get motionPoints => _motionPointController.stream;

  final _trajectoryController = StreamController<List<MotionPoint>>.broadcast();
  Stream<List<MotionPoint>> get trajectoryStream => _trajectoryController.stream;

  final _panicController = StreamController<void>.broadcast();
  Stream<void> get onPanicTriggered => _panicController.stream;

  // Custom streams for unit tests
  final Stream<AccelerometerEvent>? _customAccelStream;
  final Stream<GyroscopeEvent>? _customGyroStream;

  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;

  // EMA Low-Pass Filter State
  static const double _filterAlpha = 0.40;
  double _smoothGx = 0.0, _smoothGy = 0.0, _smoothGz = 0.0;
  double _smoothAx = 0.0, _smoothAy = 0.0, _smoothAz = 9.81;
  bool _filterInitialized = false;

  // Reference Orientation Baseline (Captured when user touches screen)
  double _refAx = 0.0, _refAy = 0.0, _refAz = 9.81;

  // Integrated 2D/3D Displacement Path from Reference
  double _velX = 0.0, _velY = 0.0, _velZ = 0.0;
  double _posX = 0.0, _posY = 0.0, _posZ = 0.0;
  int _lastSampleTimeMs = 0;

  // Trajectory recording state
  bool _isManualRecording = false;
  bool _isAutoRecording = false;
  final List<MotionPoint> _activeTrajectory = [];
  Timer? _autoRecordTimeoutTimer;
  Timer? _quietPeriodTimer;

  // Panic detection parameters
  static const double _panicDynamicThreshold = 24.0;
  DateTime _lastPanicTriggerTime = DateTime(0);

  // Auto air-draw detection thresholds
  static const double _motionStartGyro = 1.2; // rad/s rotation
  static const double _motionStartAccel = 2.4; // dynamic m/s^2
  static const double _motionStopThreshold = 0.6; // quiet threshold

  // Backward compatibility discrete thresholds
  static const double _motionStartTilt = 4.2;
  static const double _neutralThreshold = 3.5;
  bool _discreteArmed = true;
  DateTime _lastDiscreteDetected = DateTime(0);
  final List<AccelerometerEvent> _discreteWindowSamples = [];
  Timer? _discreteWindowTimer;

  GestureDetectorService({
    Stream<AccelerometerEvent>? accelStream,
    Stream<GyroscopeEvent>? gyroStream,
  })  : _customAccelStream = accelStream,
        _customGyroStream = gyroStream;

  void start() {
    stop();
    _discreteArmed = true;
    _filterInitialized = false;
    _activeTrajectory.clear();
    _discreteWindowSamples.clear();

    if (_customAccelStream != null) {
      _accelSub = _customAccelStream.listen(_onAccelEvent, onError: (_) {});
    } else {
      try {
        _accelSub = accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 20),
        ).listen(_onAccelEvent, onError: (_) {});
      } catch (_) {}
    }

    if (_customGyroStream != null) {
      _gyroSub = _customGyroStream.listen(_onGyroEvent, onError: (_) {});
    } else {
      try {
        _gyroSub = gyroscopeEventStream(
          samplingPeriod: const Duration(milliseconds: 20),
        ).listen(_onGyroEvent, onError: (_) {});
      } catch (_) {}
    }
  }

  void stop() {
    _accelSub?.cancel();
    _accelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
    _autoRecordTimeoutTimer?.cancel();
    _autoRecordTimeoutTimer = null;
    _quietPeriodTimer?.cancel();
    _quietPeriodTimer = null;
    _discreteWindowTimer?.cancel();
    _discreteWindowTimer = null;
    _isManualRecording = false;
    _isAutoRecording = false;
    _filterInitialized = false;
    _activeTrajectory.clear();
    _discreteWindowSamples.clear();
  }

  /// Sets the reference baseline to the current phone orientation at the instant
  /// the user touches down on the screen.
  void startRecording() {
    _isManualRecording = true;
    _isAutoRecording = false;
    _autoRecordTimeoutTimer?.cancel();
    _quietPeriodTimer?.cancel();
    _activeTrajectory.clear();

    // Lock reference baseline to current orientation
    _refAx = _smoothAx;
    _refAy = _smoothAy;
    _refAz = _smoothAz;

    // Reset kinematic integrator
    _velX = 0.0;
    _velY = 0.0;
    _velZ = 0.0;
    _posX = 0.0;
    _posY = 0.0;
    _posZ = 0.0;
    _lastSampleTimeMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// Manually stops recording and emits the gathered trajectory
  List<MotionPoint> stopRecording() {
    _isManualRecording = false;
    final trimmed = trimDeadzone(List<MotionPoint>.from(_activeTrajectory));
    _activeTrajectory.clear();
    if (trimmed.length >= 6) {
      _trajectoryController.add(trimmed);
    }
    return trimmed;
  }

  void _onGyroEvent(GyroscopeEvent e) {
    if (!_filterInitialized) {
      _smoothGx = e.x;
      _smoothGy = e.y;
      _smoothGz = e.z;
    } else {
      _smoothGx = _smoothGx * (1.0 - _filterAlpha) + e.x * _filterAlpha;
      _smoothGy = _smoothGy * (1.0 - _filterAlpha) + e.y * _filterAlpha;
      _smoothGz = _smoothGz * (1.0 - _filterAlpha) + e.z * _filterAlpha;
    }
    _processFusedSample();
  }

  void _onAccelEvent(AccelerometerEvent e) {
    if (!_filterInitialized) {
      _smoothAx = e.x;
      _smoothAy = e.y;
      _smoothAz = e.z;
      _refAx = e.x;
      _refAy = e.y;
      _refAz = e.z;
      _filterInitialized = true;
    } else {
      _smoothAx = _smoothAx * (1.0 - _filterAlpha) + e.x * _filterAlpha;
      _smoothAy = _smoothAy * (1.0 - _filterAlpha) + e.y * _filterAlpha;
      _smoothAz = _smoothAz * (1.0 - _filterAlpha) + e.z * _filterAlpha;
    }

    _checkPanicMotion(e);
    _checkDiscreteMotion(e);
    _processFusedSample();
  }

  void _processFusedSample() {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final dt = _lastSampleTimeMs > 0 ? min(0.05, max(0.01, (nowMs - _lastSampleTimeMs) / 1000.0)) : 0.025;
    _lastSampleTimeMs = nowMs;

    // Compute dynamic acceleration relative to baseline
    final dynAx = _smoothAx - _refAx;
    final dynAy = _smoothAy - _refAy;
    final dynAz = _smoothAz - _refAz;

    // Kinematic integration with leaky damping (prevents sensor drift)
    _velX = _velX * 0.90 + (dynAx * 9.81 * dt);
    _velY = _velY * 0.90 + (dynAy * 9.81 * dt);
    _velZ = _velZ * 0.90 + (dynAz * 9.81 * dt);

    _posX += _velX * dt * 80.0;
    _posY += _velY * dt * 80.0;
    _posZ += _velZ * dt * 80.0;

    final point = MotionPoint(
      timestampMs: nowMs,
      gx: _smoothGx,
      gy: _smoothGy,
      gz: _smoothGz,
      ax: _smoothAx,
      ay: _smoothAy,
      az: _smoothAz,
    );

    if (!_motionPointController.isClosed) {
      _motionPointController.add(point);
    }

    // Handle Manual Recording
    if (_isManualRecording) {
      _activeTrajectory.add(point);
      return;
    }

    // Handle Auto Air-Draw Detection
    final gyroMag = point.gyroMagnitude;
    final dynAccel = point.dynamicAcceleration;
    final isMoving = gyroMag >= _motionStartGyro || dynAccel >= _motionStartAccel;

    if (!_isAutoRecording) {
      if (isMoving) {
        _isAutoRecording = true;
        _refAx = _smoothAx;
        _refAy = _smoothAy;
        _refAz = _smoothAz;
        _velX = 0;
        _velY = 0;
        _velZ = 0;
        _posX = 0;
        _posY = 0;
        _posZ = 0;
        _activeTrajectory.clear();
        _activeTrajectory.add(point);

        _autoRecordTimeoutTimer?.cancel();
        _autoRecordTimeoutTimer = Timer(const Duration(milliseconds: 2400), _finishAutoRecording);
      }
    } else {
      _activeTrajectory.add(point);

      if (gyroMag < _motionStopThreshold && dynAccel < 0.8) {
        _quietPeriodTimer ??= Timer(const Duration(milliseconds: 320), _finishAutoRecording);
      } else {
        _quietPeriodTimer?.cancel();
        _quietPeriodTimer = null;
      }
    }
  }

  void _finishAutoRecording() {
    _autoRecordTimeoutTimer?.cancel();
    _autoRecordTimeoutTimer = null;
    _quietPeriodTimer?.cancel();
    _quietPeriodTimer = null;

    if (!_isAutoRecording) return;
    _isAutoRecording = false;

    final trimmed = trimDeadzone(List<MotionPoint>.from(_activeTrajectory));
    _activeTrajectory.clear();

    if (trimmed.length >= 8) {
      _trajectoryController.add(trimmed);
    }
  }

  /// Trims stationary leading and trailing deadzone points from a recorded stroke.
  static List<MotionPoint> trimDeadzone(List<MotionPoint> points) {
    if (points.length < 8) return points;

    const double minGyroCutoff = 0.4; // rad/s
    const double minAccelCutoff = 0.6; // m/s^2 dynamic

    int startIdx = 0;
    while (startIdx < points.length - 4) {
      final p = points[startIdx];
      if (p.gyroMagnitude >= minGyroCutoff || p.dynamicAcceleration >= minAccelCutoff) {
        break;
      }
      startIdx++;
    }

    int endIdx = points.length - 1;
    while (endIdx > startIdx + 4) {
      final p = points[endIdx];
      if (p.gyroMagnitude >= minGyroCutoff || p.dynamicAcceleration >= minAccelCutoff) {
        break;
      }
      endIdx--;
    }

    return points.sublist(startIdx, endIdx + 1);
  }

  /// Converts a sequence of 6-DOF points into an integrated 2D spatial path
  /// relative to the initial starting orientation.
  static List<Offset> compute2DPath(List<MotionPoint> points, {double scale = 1.0}) {
    if (points.isEmpty) return [];

    final List<Offset> path = [];
    final first = points.first;
    final refAx = first.ax;
    final refAy = first.ay;

    double vx = 0.0, vy = 0.0;
    double px = 0.0, py = 0.0;

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final dt = i > 0
          ? min(0.05, max(0.01, (p.timestampMs - points[i - 1].timestampMs) / 1000.0))
          : 0.025;

      // Dynamic acceleration in device plane
      final dax = p.ax - refAx;
      final day = p.ay - refAy;

      // Combine linear acceleration and angular velocity for translation + tilt
      vx = vx * 0.90 + (dax * 12.0 + p.gz * 2.5) * dt;
      vy = vy * 0.90 + (day * 12.0 - p.gx * 2.5) * dt;

      px += vx * dt * scale * 120.0;
      py -= vy * dt * scale * 120.0;

      path.add(Offset(px, py));
    }

    return path;
  }

  void _checkPanicMotion(AccelerometerEvent e) {
    final totalMag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final dynAccel = (totalMag - 9.81).abs();

    if (dynAccel >= _panicDynamicThreshold) {
      final now = DateTime.now();
      if (now.difference(_lastPanicTriggerTime).inMilliseconds >= 800) {
        _lastPanicTriggerTime = now;
        if (!_panicController.isClosed) {
          _panicController.add(null);
        }
      }
    }
  }

  // ─── Discrete Fallback for legacy tests / settings ───
  void _checkDiscreteMotion(AccelerometerEvent e) {
    if (_gestureController.isClosed) return;
    final now = DateTime.now();
    final totalMag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final dyn = (totalMag - 9.81).abs();
    final absX = e.x.abs();
    final absY = e.y.abs();

    if (!_discreteArmed) {
      if (now.difference(_lastDiscreteDetected) >= const Duration(milliseconds: 650) &&
          absX < _neutralThreshold &&
          absY < _neutralThreshold &&
          dyn < 4.0) {
        _discreteArmed = true;
        _discreteWindowSamples.clear();
      }
      return;
    }

    if (_discreteWindowSamples.isEmpty) {
      if (absX >= _motionStartTilt || absY >= _motionStartTilt || dyn >= 5.5) {
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
    if (signChangesX >= 1 || signChangesY >= 1 || (maxPtp >= 14.0 && meanDyn >= 20.0) || maxPtp >= 18.0) {
      detected = Gesture.shake;
    } else {
      final double absAvgX = avgX.abs();
      final double absAvgY = avgY.abs();
      if (absAvgX >= 4.5 && absAvgX > (absAvgY * 1.15)) {
        detected = avgX > 0 ? Gesture.left : Gesture.right;
      } else if (absAvgY >= 4.5 && absAvgY > (absAvgX * 1.15)) {
        detected = avgY > 0 ? Gesture.down : Gesture.up;
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
    _motionPointController.close();
    _trajectoryController.close();
    _panicController.close();
  }
}
