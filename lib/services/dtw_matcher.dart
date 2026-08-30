import 'dart:math';
import '../models/motion_point.dart';
import '../models/gesture_template.dart';

/// Pure Dart Dynamic Time Warping (DTW) multi-dimensional trajectory matcher
/// for 6-DOF spatial IMU signals (Gyroscope + Accelerometer).
class DtwMatcher {
  /// Standard resampled point count for trajectory comparison
  static const int resampledLength = 36;

  /// Sakoe-Chiba window radius to constrain warping path
  static const int warpingWindow = 8;

  /// Default acceptance threshold for distance score (lower = stricter match)
  static const double defaultMatchThreshold = 3.8;

  /// Gyroscope weight vs Accelerometer weight in multi-channel distance
  static const double gyroWeight = 1.2;
  static const double accelWeight = 0.8;

  /// Compares an input trajectory against a stored template using multi-dimensional DTW.
  /// Returns a [DtwResult] containing the normalized distance score and match verdict.
  static DtwResult match({
    required List<MotionPoint> candidate,
    required GestureTemplate template,
    double threshold = defaultMatchThreshold,
  }) {
    if (candidate.length < 8 || template.points.length < 8) {
      return const DtwResult(
        score: double.infinity,
        confidence: 0.0,
        isMatch: false,
      );
    }

    // 1. Resample both candidate and template to uniform length
    final List<MotionPoint> normalizedCandidate = resample(candidate, resampledLength);
    final List<MotionPoint> normalizedTemplate = resample(template.points, resampledLength);

    // 2. Compute constrained DTW distance
    final double cost = _computeDtwCost(normalizedCandidate, normalizedTemplate);
    final double normalizedScore = cost / resampledLength;

    // 3. Compute confidence percentage [0.0 - 1.0]
    final double confidence = max(0.0, min(1.0, 1.0 - (normalizedScore / (threshold * 1.5))));
    final bool isMatch = normalizedScore <= threshold;

    return DtwResult(
      score: normalizedScore,
      confidence: confidence,
      isMatch: isMatch,
    );
  }

  /// Calculates the DTW dynamic programming matrix with a Sakoe-Chiba band.
  static double _computeDtwCost(List<MotionPoint> seq1, List<MotionPoint> seq2) {
    final int n = seq1.length;
    final int m = seq2.length;

    // Initialize DP matrix with infinity
    final List<List<double>> dtw = List.generate(
      n + 1,
      (_) => List.filled(m + 1, double.infinity),
    );

    dtw[0][0] = 0.0;

    for (int i = 1; i <= n; i++) {
      final int startJ = max(1, i - warpingWindow);
      final int endJ = min(m, i + warpingWindow);

      for (int j = startJ; j <= endJ; j++) {
        final double dist = _pointDistance(seq1[i - 1], seq2[j - 1]);
        final double minPrev = min(
          dtw[i - 1][j], // Insertion
          min(
            dtw[i][j - 1], // Deletion
            dtw[i - 1][j - 1], // Match
          ),
        );

        dtw[i][j] = dist + minPrev;
      }
    }

    return dtw[n][m];
  }

  /// Multi-dimensional weighted Euclidean distance between two 6-axis points
  static double _pointDistance(MotionPoint p1, MotionPoint p2) {
    final double dgx = p1.gx - p2.gx;
    final double dgy = p1.gy - p2.gy;
    final double dgz = p1.gz - p2.gz;
    final double gyroDist = (dgx * dgx + dgy * dgy + dgz * dgz);

    final double dax = p1.ax - p2.ax;
    final double day = p1.ay - p2.ay;
    final double daz = p1.az - p2.az;
    final double accelDist = (dax * dax + day * day + daz * daz);

    return sqrt((gyroDist * gyroWeight) + (accelDist * accelWeight));
  }

  /// Uniformly resamples a time-series trajectory into [targetCount] points
  /// using linear interpolation along the normalized temporal index.
  static List<MotionPoint> resample(List<MotionPoint> points, int targetCount) {
    if (points.length == targetCount) return List.from(points);
    if (points.isEmpty) return [];

    final List<MotionPoint> result = [];
    final double step = (points.length - 1) / (targetCount - 1);

    for (int i = 0; i < targetCount; i++) {
      final double exactIndex = i * step;
      final int low = exactIndex.floor();
      final int high = min(low + 1, points.length - 1);
      final double fraction = exactIndex - low;

      final pLow = points[low];
      final pHigh = points[high];

      final resampledPoint = MotionPoint(
        timestampMs: (pLow.timestampMs + (pHigh.timestampMs - pLow.timestampMs) * fraction).round(),
        gx: pLow.gx + (pHigh.gx - pLow.gx) * fraction,
        gy: pLow.gy + (pHigh.gy - pLow.gy) * fraction,
        gz: pLow.gz + (pHigh.gz - pLow.gz) * fraction,
        ax: pLow.ax + (pHigh.ax - pLow.ax) * fraction,
        ay: pLow.ay + (pHigh.ay - pLow.ay) * fraction,
        az: pLow.az + (pHigh.az - pLow.az) * fraction,
      );
      result.add(resampledPoint);
    }

    return result;
  }
}

/// Result of a DTW comparison
class DtwResult {
  final double score;
  final double confidence;
  final bool isMatch;

  const DtwResult({
    required this.score,
    required this.confidence,
    required this.isMatch,
  });

  @override
  String toString() =>
      'DtwResult(isMatch: $isMatch, score: ${score.toStringAsFixed(2)}, confidence: ${(confidence * 100).toStringAsFixed(1)}%)';
}
