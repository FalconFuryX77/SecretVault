import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/motion_point.dart';
import 'package:gesture_unlock/models/gesture_template.dart';
import 'package:gesture_unlock/services/dtw_matcher.dart';

void main() {
  group('DtwMatcher 6-DOF Trajectory Tests', () {
    // Generate a synthetic circle gesture
    List<MotionPoint> generateCircleTrajectory({int sampleCount = 30, double speedFactor = 1.0}) {
      final List<MotionPoint> points = [];
      for (int i = 0; i < sampleCount; i++) {
        final double theta = (i / (sampleCount - 1)) * 2 * pi;
        points.add(MotionPoint(
          timestampMs: (i * 30 * speedFactor).round(),
          gx: sin(theta) * 3.0,
          gy: cos(theta) * 3.0,
          gz: 0.5,
          ax: cos(theta) * 4.0,
          ay: sin(theta) * 4.0,
          az: 9.81,
        ));
      }
      return points;
    }

    // Generate a synthetic straight jab gesture
    List<MotionPoint> generateJabTrajectory({int sampleCount = 30}) {
      final List<MotionPoint> points = [];
      for (int i = 0; i < sampleCount; i++) {
        points.add(MotionPoint(
          timestampMs: i * 30,
          gx: 0.1,
          gy: 0.1,
          gz: 0.1,
          ax: (i < 15) ? (i * 1.5) : ((30 - i) * 1.5),
          ay: 0.2,
          az: 9.81,
        ));
      }
      return points;
    }

    late GestureTemplate circleTemplate;

    setUp(() {
      final circlePoints = generateCircleTrajectory(sampleCount: 35);
      circleTemplate = GestureTemplate(
        id: 'circle-template',
        name: 'Circle Wand',
        points: circlePoints,
        durationMs: 1050,
        createdAt: DateTime.now(),
      );
    });

    test('Identical gesture matches with near-zero distance and high confidence', () {
      final candidate = generateCircleTrajectory(sampleCount: 35);
      final result = DtwMatcher.match(candidate: candidate, template: circleTemplate);

      expect(result.isMatch, isTrue);
      expect(result.score, lessThan(0.5));
      expect(result.confidence, greaterThan(0.90));
    });

    test('Temporally stretched / compressed gesture matches due to dynamic warping', () {
      // 1.5x slower drawing
      final slowCandidate = generateCircleTrajectory(sampleCount: 50, speedFactor: 1.5);
      final result = DtwMatcher.match(candidate: slowCandidate, template: circleTemplate);

      expect(result.isMatch, isTrue);
      expect(result.score, lessThan(DtwMatcher.defaultMatchThreshold));
      expect(result.confidence, greaterThan(0.60));
    });

    test('Completely dissimilar gesture (Jab vs Circle) is rejected', () {
      final jabCandidate = generateJabTrajectory(sampleCount: 30);
      final result = DtwMatcher.match(candidate: jabCandidate, template: circleTemplate);

      expect(result.isMatch, isFalse);
      expect(result.score, greaterThan(DtwMatcher.defaultMatchThreshold));
      expect(result.confidence, lessThan(0.50));
    });

    test('Resample normalizes arbitrary point counts to exact target length', () {
      final shortSequence = generateCircleTrajectory(sampleCount: 12);
      final resampled = DtwMatcher.resample(shortSequence, 36);

      expect(resampled.length, equals(36));
      expect(resampled.first.gx, closeTo(shortSequence.first.gx, 0.01));
      expect(resampled.last.gx, closeTo(shortSequence.last.gx, 0.01));
    });
  });
}
