import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/gesture.dart';
import '../models/motion_point.dart';

/// 6-DOF Spatial Motion & 3D Wand Trajectory Service.
/// Fuses Accelerometer (linear motion & gravity) and Gyroscope (rotation rates)
/// to detect fluid continuous air strokes, discrete gestures, and instant panic drops.
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

  // Current reading buffers
  double _lastGx = 0.0, _lastGy = 0.0, _lastGz = 0.0;
  double _lastAx = 0.0, _lastAy = 0.0, _lastAz = 9.81;

  // Trajectory recording state
  bool _isManualRecording = false;
  bool _isAutoRecording = false;
  final List<MotionPoint> _activeTrajectory = [];
  Timer? _autoRecordTimeoutTimer;
  Timer? _quietPeriodTimer;

  // Panic detection parameters
  static const double _panicDynamicThreshold = 24.0; // Rapid shake / throw / drop
  DateTime _lastPanicTriggerTime = DateTime(0);

  // Auto air-draw detection thresholds
  static const double _motionStartGyro = 1.6; // rad/s rotation
  static const double _motionStartAccel = 3.2; // dynamic m/s^2
  static const double _motionStopThreshold = 0.8; // quiet threshold

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
    _activeTrajectory.clear();
    _discreteWindowSamples.clear();

    if (_customAccelStream != null) {
      _accelSub = _customAccelStream.listen(_onAccelEvent, onError: (_) {});
    } else {
      try {
        _accelSub = accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 25),
        ).listen(_onAccelEvent, onError: (_) {});
      } catch (_) {}
    }

    if (_customGyroStream != null) {
      _gyroSub = _customGyroStream.listen(_onGyroEvent, onError: (_) {});
    } else {
      try {
        _gyroSub = gyroscopeEventStream(
          samplingPeriod: const Duration(milliseconds: 25),
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
    _activeTrajectory.clear();
    _discreteWindowSamples.clear();
  }

  /// Manually starts recording a 3D wand trajectory (e.g. while user holds down the wand canvas)
  void startRecording() {
    _isManualRecording = true;
    _isAutoRecording = false;
    _autoRecordTimeoutTimer?.cancel();
    _quietPeriodTimer?.cancel();
    _activeTrajectory.clear();
  }

  /// Manually stops recording and emits the gathered trajectory
  List<MotionPoint> stopRecording() {
    _isManualRecording = false;
    final trajectory = List<MotionPoint>.from(_activeTrajectory);
    _activeTrajectory.clear();
    if (trajectory.length >= 6) {
      _trajectoryController.add(trajectory);
    }
    return trajectory;
  }

  void _onGyroEvent(GyroscopeEvent e) {
    _lastGx = e.x;
    _lastGy = e.y;
    _lastGz = e.z;
    _processFusedSample();
  }

  void _onAccelEvent(AccelerometerEvent e) {
    _lastAx = e.x;
    _lastAy = e.y;
    _lastAz = e.z;

    _checkPanicMotion(e);
    _checkDiscreteMotion(e);
    _processFusedSample();
  }

  void _processFusedSample() {
    final now = DateTime.now();
    final point = MotionPoint(
      timestampMs: now.millisecondsSinceEpoch,
      gx: _lastGx,
      gy: _lastGy,
      gz: _lastGz,
      ax: _lastAx,
      ay: _lastAy,
      az: _lastAz,
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
        _activeTrajectory.clear();
        _activeTrajectory.add(point);

        // Maximum recording window safety limit (2.2 seconds)
        _autoRecordTimeoutTimer?.cancel();
        _autoRecordTimeoutTimer = Timer(const Duration(milliseconds: 2200), _finishAutoRecording);
      }
    } else {
      _activeTrajectory.add(point);

      if (gyroMag < _motionStopThreshold && dynAccel < 1.0) {
        // Hand is settling down — start quiet timer
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

    if (_activeTrajectory.length >= 10) {
      final trajectory = List<MotionPoint>.from(_activeTrajectory);
      _trajectoryController.add(trajectory);
    }
    _activeTrajectory.clear();
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
