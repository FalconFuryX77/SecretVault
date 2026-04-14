import 'dart:async';
import '../models/gesture.dart';

class PatternMatcherService {
  final List<Gesture> correctPattern;
  PatternMatcherService(this.correctPattern);

  final _stateController = StreamController<UnlockState>.broadcast();
  Stream<UnlockState> get stateStream => _stateController.stream;

  final List<Gesture> _buffer = [];
  Timer? _resetTimer;

  void addGesture(Gesture g) {
    _buffer.add(g);
    _resetTimer?.cancel();

    if (_buffer.length == correctPattern.length) {
      final matched = _listEquals(_buffer, correctPattern);
      _stateController
          .add(matched ? UnlockState.unlocked : UnlockState.failed);
      _buffer.clear();
      return;
    }

    // Auto-reset if idle for 5 s
    _resetTimer = Timer(const Duration(seconds: 5), reset);
  }

  void reset() {
    _buffer.clear();
    _resetTimer?.cancel();
    _stateController.add(UnlockState.locked);
  }

  bool _listEquals(List<Gesture> a, List<Gesture> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    _resetTimer?.cancel();
    _stateController.close();
  }
}
