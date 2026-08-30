import 'dart:math';

/// Represents a single 6-DOF sensor sample containing both Gyroscope
/// (angular velocity in rad/s) and Accelerometer (acceleration in m/s^2).
class MotionPoint {
  final int timestampMs;
  final double gx;
  final double gy;
  final double gz;
  final double ax;
  final double ay;
  final double az;

  const MotionPoint({
    required this.timestampMs,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.ax,
    required this.ay,
    required this.az,
  });

  /// Total angular rotation magnitude (rad/s)
  double get gyroMagnitude => sqrt(gx * gx + gy * gy + gz * gz);

  /// Total acceleration magnitude (m/s^2)
  double get accelMagnitude => sqrt(ax * ax + ay * ay + az * az);

  /// Dynamic acceleration (magnitude deviation from standard gravity ~9.81 m/s^2)
  double get dynamicAcceleration => (accelMagnitude - 9.81).abs();

  Map<String, dynamic> toJson() => {
        't': timestampMs,
        'gx': gx,
        'gy': gy,
        'gz': gz,
        'ax': ax,
        'ay': ay,
        'az': az,
      };

  factory MotionPoint.fromJson(Map<String, dynamic> json) => MotionPoint(
        timestampMs: (json['t'] as num).toInt(),
        gx: (json['gx'] as num).toDouble(),
        gy: (json['gy'] as num).toDouble(),
        gz: (json['gz'] as num).toDouble(),
        ax: (json['ax'] as num).toDouble(),
        ay: (json['ay'] as num).toDouble(),
        az: (json['az'] as num).toDouble(),
      );
}
