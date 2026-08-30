import 'dart:math';
import 'dart:ui';
import '../models/motion_point.dart';
import '../models/gesture_template.dart';
import 'gesture_detector.dart';

/// Pure Dart Dynamic Time Warping (DTW) matcher with 2D/3D relative spatial path integration,
/// Z-Score normalization, orientation invariance, and shape/direction matching.
class DtwMatcher {
  /// Standard resampled point count for trajectory comparison
  static const int resampledLength = 36;

  /// Sakoe-Chiba window radius to constrain warping path
  static const int warpingWindow = 8;

  /// Default acceptance threshold for distance score (lower = stricter match)
  static const double defaultMatchThreshold = 3.2;

  /// Compares an input trajectory against a stored template using spatial path + kinematic DTW.
  /// Returns a [DtwResult] containing the normalized distance score and match verdict.
  static DtwResult match({
    required List<MotionPoint> candidate,
    required GestureTemplate template,
    double threshold = defaultMatchThreshold,
  }) {
    if (candidate.length < 6 || template.points.length < 6) {
      return const DtwResult(
        score: double.infinity,
        confidence: 0.0,
        isMatch: false,
      );
    }

    // 1. Resample both candidate and template to uniform length
    final List<MotionPoint> resampledCandidate = resample(candidate, resampledLength);
    final List<MotionPoint> resampledTemplate = resample(template.points, resampledLength);

    // 2. Energy check: Reject stationary candidates if template has deliberate motion
    double candEnergy = 0.0;
    for (final p in resampledCandidate) {
      candEnergy += p.dynamicAcceleration + p.gyroMagnitude;
    }
    candEnergy /= resampledCandidate.length;

    double tmplEnergy = 0.0;
    for (final p in resampledTemplate) {
      tmplEnergy += p.dynamicAcceleration + p.gyroMagnitude;
    }
    tmplEnergy /= resampledTemplate.length;

    if (candEnergy < 0.45 && tmplEnergy >= 1.0) {
      return const DtwResult(
        score: 99.0,
        confidence: 0.0,
        isMatch: false,
      );
    }

    // 3. Compute 2D relative spatial paths for both trajectories
    final List<Offset> candidatePath = GestureDetectorService.compute2DPath(resampledCandidate);
    final List<Offset> templatePath = GestureDetectorService.compute2DPath(resampledTemplate);

    // 4. Compute Z-Score normalized feature matrices (combines spatial path + velocity + gyro)
    final List<List<double>> normCandidate = _extractFeatureMatrix(resampledCandidate, candidatePath);
    final List<List<double>> normTemplate = _extractFeatureMatrix(resampledTemplate, templatePath);

    // 5. Compute constrained DTW distance on normalized trajectories
    final double cost = _computeDtwCost(normCandidate, normTemplate);
    final double normalizedScore = cost / resampledLength;

    // 6. Compute confidence percentage [0.0 - 1.0]
    final double confidence = max(0.0, min(1.0, 1.0 - (normalizedScore / (threshold * 1.5))));
    final bool isMatch = normalizedScore <= threshold;

    return DtwResult(
      score: normalizedScore,
      confidence: confidence,
      isMatch: isMatch,
    );
  }

  /// Calculates the DTW dynamic programming matrix with a Sakoe-Chiba band.
  static double _computeDtwCost(
    List<List<double>> norm1,
    List<List<double>> norm2,
  ) {
    final int n = norm1.length;
    final int m = norm2.length;

    final List<List<double>> dtw = List.generate(
      n + 1,
      (_) => List.filled(m + 1, double.infinity),
    );

    dtw[0][0] = 0.0;

    for (int i = 1; i <= n; i++) {
      final int startJ = max(1, i - warpingWindow);
      final int endJ = min(m, i + warpingWindow);

      for (int j = startJ; j <= endJ; j++) {
        final double dist = _vectorDistance(norm1[i - 1], norm2[j - 1]);
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

  /// Multi-dimensional distance between normalized feature vectors
  static double _vectorDistance(List<double> v1, List<double> v2) {
    // Feature channels: [px, py, vx, vy, dax, day, gx, gy, gz]
    const weights = [1.5, 1.5, 1.3, 1.3, 1.0, 1.0, 0.9, 0.9, 0.9];
    double sumSq = 0.0;

    for (int k = 0; k < v1.length; k++) {
      final double diff = v1[k] - v2[k];
      final double w = k < weights.length ? weights[k] : 1.0;
      sumSq += diff * diff * w;
    }

    return sqrt(sumSq);
  }

  /// Extracts a normalized feature matrix:
  /// [px, py, vx, vy, dax, day, gx, gy, gz] with per-channel Z-score scaling.
  static List<List<double>> _extractFeatureMatrix(
    List<MotionPoint> points,
    List<Offset> path,
  ) {
    final int count = points.length;
    if (count == 0) return [];

    final refAx = points.first.ax;
    final refAy = points.first.ay;

    final List<List<double>> rawRows = [];
    for (int i = 0; i < count; i++) {
      final p = points[i];
      final off = i < path.length ? path[i] : Offset.zero;

      // Velocity vectors for directionality
      final double vx = (i > 0 && i < path.length) ? (path[i].dx - path[i - 1].dx) : 0.0;
      final double vy = (i > 0 && i < path.length) ? (path[i].dy - path[i - 1].dy) : 0.0;

      rawRows.add([
        off.dx,
        off.dy,
        vx,
        vy,
        p.ax - refAx,
        p.ay - refAy,
        p.gx,
        p.gy,
        p.gz,
      ]);
    }

    final int numChannels = rawRows.first.length;
    final List<double> means = List.filled(numChannels, 0.0);
    final List<double> stdDevs = List.filled(numChannels, 0.0);

    for (final row in rawRows) {
      for (int k = 0; k < numChannels; k++) {
        means[k] += row[k];
      }
    }
    for (int k = 0; k < numChannels; k++) {
      means[k] /= count;
    }

    for (final row in rawRows) {
      for (int k = 0; k < numChannels; k++) {
        final diff = row[k] - means[k];
        stdDevs[k] += diff * diff;
      }
    }
    for (int k = 0; k < numChannels; k++) {
      stdDevs[k] = sqrt(stdDevs[k] / count);
      if (stdDevs[k] < 0.05) stdDevs[k] = 1.0;
    }

    final List<List<double>> normalized = [];
    for (final row in rawRows) {
      final List<double> normRow = List.filled(numChannels, 0.0);
      for (int k = 0; k < numChannels; k++) {
        normRow[k] = (row[k] - means[k]) / stdDevs[k];
      }
      normalized.add(normRow);
    }

    return normalized;
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

  /// Averages multiple resampled calibration trajectories into a single high-precision master template.
  static List<MotionPoint> fuseTemplates(List<List<MotionPoint>> multiSamples) {
    if (multiSamples.isEmpty) return [];
    if (multiSamples.length == 1) return resample(multiSamples.first, resampledLength);

    final List<List<MotionPoint>> normalizedSamples = multiSamples
        .map((s) => resample(s, resampledLength))
        .toList();

    final List<MotionPoint> fused = [];
    final int sampleCount = normalizedSamples.length;

    for (int i = 0; i < resampledLength; i++) {
      double sumGx = 0, sumGy = 0, sumGz = 0;
      double sumAx = 0, sumAy = 0, sumAz = 0;
      int sumTime = 0;

      for (int s = 0; s < sampleCount; s++) {
        final p = normalizedSamples[s][i];
        sumGx += p.gx;
        sumGy += p.gy;
        sumGz += p.gz;
        sumAx += p.ax;
        sumAy += p.ay;
        sumAz += p.az;
        sumTime += p.timestampMs;
      }

      fused.add(MotionPoint(
        timestampMs: (sumTime / sampleCount).round(),
        gx: sumGx / sampleCount,
        gy: sumGy / sampleCount,
        gz: sumGz / sampleCount,
        ax: sumAx / sampleCount,
        ay: sumAy / sampleCount,
        az: sumAz / sampleCount,
      ));
    }

    return fused;
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
