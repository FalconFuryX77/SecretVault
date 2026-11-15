import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// Detects one thing: a deliberate hard shake, used to lock the vault.
///
/// It only runs while a vault is open (the unlock provider starts and stops
/// it), so the cover app never reads the motion sensors.
///
/// Road vibration is filtered: in a moving vehicle the threshold rises and
/// more consecutive samples are required, so potholes don't lock the vault.
class ShakeDetector {
  final _shakeController = StreamController<void>.broadcast();
  Stream<void> get onShake => _shakeController.stream;

  final Stream<AccelerometerEvent>? _customAccelStream;
  StreamSubscription? _accelSub;

  // Rolling dynamic-acceleration buffer for vehicle / transit estimation.
  static const int _rollingBufferSize = 40;
  final List<double> _rollingDynBuffer = [];
  DateTime _lastVehicleMotionTime = DateTime(0);
  int _consecutiveHardSamples = 0;
  DateTime _lastTriggerTime = DateTime(0);

  /// True while sustained vibration (car, bus, rough road) is being seen.
  bool get isVehicleMotionDetected =>
      DateTime.now().difference(_lastVehicleMotionTime).inMilliseconds < 2500;

  ShakeDetector({Stream<AccelerometerEvent>? accelStream}) : _customAccelStream = accelStream;

  void start() {
    stop();
    if (_customAccelStream != null) {
      _accelSub = _customAccelStream.listen(_onAccelEvent, onError: (_) {});
    } else {
      try {
        _accelSub = accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 20),
        ).listen(_onAccelEvent, onError: (_) {});
      } catch (_) {
        // No accelerometer: the lock button and auto-lock still work.
      }
    }
  }

  void stop() {
    _accelSub?.cancel();
    _accelSub = null;
    _rollingDynBuffer.clear();
    _consecutiveHardSamples = 0;
  }

  void _onAccelEvent(AccelerometerEvent e) {
    final dynAccel = (sqrt(e.x * e.x + e.y * e.y + e.z * e.z) - 9.81).abs();
    _updateVehicleMotionState(dynAccel);
    _checkHardShake(dynAccel);
  }

  void _updateVehicleMotionState(double dynAccel) {
    _rollingDynBuffer.add(dynAccel);
    if (_rollingDynBuffer.length > _rollingBufferSize) {
      _rollingDynBuffer.removeAt(0);
    }
    if (_rollingDynBuffer.length < 15) return;

    final mean = _rollingDynBuffer.reduce((a, b) => a + b) / _rollingDynBuffer.length;
    var varSum = 0.0;
    for (final v in _rollingDynBuffer) {
      varSum += (v - mean) * (v - mean);
    }
    final variance = varSum / _rollingDynBuffer.length;
    if (variance >= 0.5 || mean >= 1.4) {
      _lastVehicleMotionTime = DateTime.now();
    }
  }

  void _checkHardShake(double dynAccel) {
    final inVehicle = isVehicleMotionDetected;
    final threshold = inVehicle ? 34.0 : 22.0;
    final singleSampleThreshold = inVehicle ? 40.0 : 26.0;

    if (dynAccel >= threshold) {
      _consecutiveHardSamples++;
    } else {
      _consecutiveHardSamples = 0;
    }

    final isHardShake =
        dynAccel >= singleSampleThreshold || _consecutiveHardSamples >= (inVehicle ? 3 : 2);
    if (!isHardShake) return;

    final now = DateTime.now();
    if (now.difference(_lastTriggerTime).inMilliseconds < 800) return;
    _lastTriggerTime = now;
    _consecutiveHardSamples = 0;
    if (!_shakeController.isClosed) _shakeController.add(null);
  }

  void dispose() {
    stop();
    _shakeController.close();
  }
}
