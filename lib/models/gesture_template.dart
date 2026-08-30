import 'dart:convert';
import 'motion_point.dart';

/// Represents a standardized, recorded 6-DOF air trajectory template
/// used for Dynamic Time Warping (DTW) recognition.
class GestureTemplate {
  final String id;
  final String name;
  final List<MotionPoint> points;
  final int durationMs;
  final DateTime createdAt;

  const GestureTemplate({
    required this.id,
    required this.name,
    required this.points,
    required this.durationMs,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'points': points.map((p) => p.toJson()).toList(),
        'durationMs': durationMs,
        'createdAt': createdAt.toIso8601String(),
      };

  factory GestureTemplate.fromMap(Map<String, dynamic> map) => GestureTemplate(
        id: map['id'] as String,
        name: map['name'] as String,
        points: (map['points'] as List<dynamic>)
            .map((p) => MotionPoint.fromJson(p as Map<String, dynamic>))
            .toList(),
        durationMs: (map['durationMs'] as num).toInt(),
        createdAt: DateTime.parse(map['createdAt'] as String),
      );

  String toJson() => jsonEncode(toMap());

  factory GestureTemplate.fromJson(String source) =>
      GestureTemplate.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
