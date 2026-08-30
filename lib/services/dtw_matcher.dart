import 'dart:math';
import '../models/motion_point.dart';
import '../models/gesture_template.dart';

/// Pure Dart Dynamic Time Warping (DTW) matcher with Z-Score normalization,
/// angular direction cosine alignment, and noise-robust morphological shape comparison.
class DtwMatcher {
  /// Standard resampled point count for trajectory comparison
  static const int resampledLength = 36;

  /// Sakoe-Chiba window radius to constrain warping path
  static const int warpingWindow = 10;

  /// Default acceptance threshold for distance score (lower = stricter match)
  static const double defaultMatchThreshold = 3.0;

  /// Compares an input trajectory against a stored template using multi-dimensional DTW.
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

    // 2. Energy check: Validate movement dynamic energy
    double candidateGyroEnergy = 0.0;
    double candidateAccelEnergy = 0.0;
    for (final p in resampledCandidate) {
      candidateGyroEnergy += p.gyroMagnitude;
      candidateAccelEnergy += p.dynamicAcceleration;
    }
    candidateGyroEnergy /= resampledCandidate.length;
    candidateAccelEnergy /= resampledCandidate.length;

    double templateGyroEnergy = 0.0;
    for (final p in resampledTemplate) {
      templateGyroEnergy += p.gyroMagnitude;
    }
    templateGyroEnergy /= resampledTemplate.length;

    // Reject stationary or flat lines if template requires active rotation
    if (candidateGyroEnergy < 0.35 && templateGyroEnergy >= 0.8 && candidateAccelEnergy < 2.0) {
      return const DtwResult(
        score: 99.0,
        confidence: 0.0,
        isMatch: false,
      );
    }

    // 3. Compute Z-Score normalized feature matrices
    final List<List<double>> normCandidate = _zScoreNormalize(resampledCandidate);
    final List<List<double>> normTemplate = _zScoreNormalize(resampledTemplate);

    // 4. Compute constrained DTW distance on normalized trajectories
    final double cost = _computeDtwCost(
      normCandidate,
      normTemplate,
      resampledCandidate,
      resampledTemplate,
    );
    final double normalizedScore = cost / resampledLength;

    // 5. Compute confidence percentage [0.0 - 1.0]
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
    List<MotionPoint> raw1,
    List<MotionPoint> raw2,
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
        final double dist = _pointDistance(
          norm1[i - 1],
          norm2[j - 1],
          raw1[i - 1],
          raw2[j - 1],
        );
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

  /// Multi-dimensional distance between normalized 6-channel state vectors
  /// combined with angular velocity direction cosine alignment and raw acceleration shapes.
  static double _pointDistance(
    List<double> n1,
    List<double> n2,
    MotionPoint raw1,
    MotionPoint raw2,
  ) {
    // 1. Normalized Gyro & Accel Euclidean distance
    double normSumSq = 0.0;
    for (int k = 0; k < 6; k++) {
      final double diff = n1[k] - n2[k];
      final double weight = (k < 3) ? 1.3 : 0.7; // Gyroscope channels have higher weight
      normSumSq += diff * diff * weight;
    }
    final double normEuclidean = sqrt(normSumSq);

    // 2. Angular Direction Cosine alignment
    final double mag1 = raw1.gyroMagnitude;
    final double mag2 = raw2.gyroMagnitude;
    double cosinePenalty = 0.0;

    if (mag1 > 0.3 && mag2 > 0.3) {
      final double dot = (raw1.gx * raw2.gx + raw1.gy * raw2.gy + raw1.gz * raw2.gz) / (mag1 * mag2);
      final double clampedDot = max(-1.0, min(1.0, dot));
      // Significant penalty for inverted directions (e.g. dot = -1 yields 2.0 penalty)
      cosinePenalty = (1.0 - clampedDot) * 1.0;
    } else if ((mag1 > 0.8 && mag2 < 0.2) || (mag2 > 0.8 && mag1 < 0.2)) {
      // One has large rotation and the other has none
      cosinePenalty = 1.5;
    }

    return normEuclidean + cosinePenalty;
  }

  /// Z-Score normalizes each of the 6 sensor channels across the trajectory
  /// to eliminate scale, velocity, and amplitude variations.
  static List<List<double>> _zScoreNormalize(List<MotionPoint> points) {
    final int count = points.length;
    if (count == 0) return [];

    final List<double> means = List.filled(6, 0.0);
    final List<double> stdDevs = List.filled(6, 0.0);

    // Compute channel means
    for (final p in points) {
      means[0] += p.gx;
      means[1] += p.gy;
      means[2] += p.gz;
      means[3] += p.ax;
      means[4] += p.ay;
      means[5] += p.az;
    }
    for (int k = 0; k < 6; k++) {
      means[k] /= count;
    }

    // Compute channel standard deviations
    for (final p in points) {
      final vals = [p.gx, p.gy, p.gz, p.ax, p.ay, p.az];
      for (int k = 0; k < 6; k++) {
        final double diff = vals[k] - means[k];
        stdDevs[k] += diff * diff;
      }
    }
    for (int k = 0; k < 6; k++) {
      stdDevs[k] = sqrt(stdDevs[k] / count);
      if (stdDevs[k] < 0.1) stdDevs[k] = 1.0; // Avoid division by near-zero for constant channels
    }

    // Produce normalized matrix [count x 6]
    final List<List<double>> normalized = [];
    for (final p in points) {
      final vals = [p.gx, p.gy, p.gz, p.ax, p.ay, p.az];
      final List<double> row = List.filled(6, 0.0);
      for (int k = 0; k < 6; k++) {
        row[k] = (vals[k] - means[k]) / stdDevs[k];
      }
      normalized.add(row);
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
