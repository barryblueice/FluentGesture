import 'dart:math' as math;
import 'gesture.dart';

/// Frames are complete snapshots keyed by stable contact IDs. Silence cancels.
class GestureCapture {
  final Map<int, List<Point2>> _active = {};
  final List<List<Point2>> _strokes = [];
  int? _lastTime;
  int? _started;
  bool _discarding = false;
  int get activeCount => _active.length;
  List<List<Point2>> get strokes => _strokes;
  bool get hasInput => _strokes.isNotEmpty;
  void reset() {
    _active.clear();
    _strokes.clear();
    _lastTime = null;
    _started = null;
    _discarding = false;
  }

  bool expire(int nowMs) {
    if (_lastTime != null && nowMs - _lastTime! > 700) {
      reset();
      return true;
    }
    return false;
  }

  GestureSample? addFrame(Map<int, Point2> contacts, int timeMs) {
    if (_lastTime != null && timeMs < _lastTime!) return null;
    if (contacts.length > 5 || contacts.values.any((p) => !p.isFinite)) {
      reset();
      _discarding = true;
      return null;
    }
    if (_discarding) {
      if (contacts.isEmpty) reset();
      return null;
    }
    if (_lastTime != null && timeMs - _lastTime! > 700) reset();
    final dt = _lastTime == null ? 16 : math.max(1, timeMs - _lastTime!);
    _lastTime = timeMs;
    if (contacts.isEmpty) {
      final result = GestureSample(
          _strokes.map((s) => s.length == 1 ? [s.first, s.first] : s));
      reset();
      return result.isValid ? result : null;
    }
    _started ??= timeMs;
    _active.removeWhere((id, _) => !contacts.containsKey(id));
    for (final entry in contacts.entries) {
      var stroke = _active[entry.key];
      if (stroke == null) {
        stroke = [entry.value];
        _active[entry.key] = stroke;
        _strokes.add(stroke);
      } else {
        final point = stroke.last.lerp(entry.value, 1 - math.exp(-dt / 12));
        if (point.distance(stroke.last) >= 0.0005) stroke.add(point);
      }
    }
    if (_strokes.length > 5 ||
        _strokes.any((s) => s.length > 4096) ||
        timeMs - _started! > 15000) {
      reset();
      _discarding = true;
    }
    return null;
  }
}
