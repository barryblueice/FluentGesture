import 'dart:math' as math;

class Point2 {
  const Point2(this.x, this.y);
  final double x;
  final double y;
  bool get isFinite => x.isFinite && y.isFinite;
  double distance(Point2 other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));
  Point2 lerp(Point2 other, double t) =>
      Point2(x + (other.x - x) * t, y + (other.y - y) * t);
  List<double> toJson() => [x, y];
}

class GestureSample {
  GestureSample(Iterable<Iterable<Point2>> strokes)
      : strokes =
            List.unmodifiable(strokes.map((s) => List<Point2>.unmodifiable(s)));
  final List<List<Point2>> strokes;
  bool get isValid =>
      strokes.isNotEmpty &&
      strokes.length <= 5 &&
      strokes.every((s) =>
          s.length >= 2 && s.length <= 4096 && s.every((p) => p.isFinite)) &&
      strokes.any((s) => pathLength(s) > 0.015);
  List<Object> toJson() =>
      strokes.map((s) => s.map((p) => p.toJson()).toList()).toList();

  factory GestureSample.fromJson(Object? value) {
    if (value is! List || value.isEmpty || value.length > 5) {
      throw const FormatException('手势必须包含 1–5 条轨迹');
    }
    final strokes = value.map((stroke) {
      if (stroke is! List || stroke.length < 2 || stroke.length > 4096) {
        throw const FormatException('轨迹点数无效');
      }
      return stroke.map((point) {
        if (point is! List ||
            point.length != 2 ||
            point[0] is! num ||
            point[1] is! num) {
          throw const FormatException('坐标格式无效');
        }
        final p =
            Point2((point[0] as num).toDouble(), (point[1] as num).toDouble());
        if (!p.isFinite || p.x.abs() > 1e6 || p.y.abs() > 1e6) {
          throw const FormatException('坐标超出范围');
        }
        return p;
      });
    });
    final sample = GestureSample(strokes);
    if (!sample.isValid) throw const FormatException('手势轨迹过短');
    return sample;
  }
}

double pathLength(List<Point2> points) {
  var length = 0.0;
  for (var i = 1; i < points.length; i++) {
    length += points[i - 1].distance(points[i]);
  }
  return length;
}

List<Point2> resample(List<Point2> points, [int count = 48]) {
  if (count < 2) throw ArgumentError.value(count, 'count');
  if (points.isEmpty) return [];
  final clean = <Point2>[points.first];
  for (final point in points.skip(1)) {
    if (point.distance(clean.last) > 1e-9) clean.add(point);
  }
  if (clean.length == 1) return List.filled(count, clean.first);
  final distances = <double>[0];
  for (var i = 1; i < clean.length; i++) {
    distances.add(distances.last + clean[i - 1].distance(clean[i]));
  }
  var segment = 1;
  return List.generate(count, (i) {
    final target = distances.last * i / (count - 1);
    while (segment < clean.length - 1 && distances[segment] < target) {
      segment++;
    }
    return clean[segment - 1].lerp(
        clean[segment],
        (target - distances[segment - 1]) /
            (distances[segment] - distances[segment - 1]));
  });
}

/// Normalize all fingers together, preserving relative geometry and direction.
GestureSample normalize(GestureSample sample) {
  if (!sample.isValid) throw ArgumentError('Invalid gesture');
  final points = sample.strokes.expand((s) => s);
  final minX = points.map((p) => p.x).reduce(math.min);
  final maxX = points.map((p) => p.x).reduce(math.max);
  final minY = points.map((p) => p.y).reduce(math.min);
  final maxY = points.map((p) => p.y).reduce(math.max);
  final scale = math.max(math.max(maxX - minX, maxY - minY), 1e-9);
  return GestureSample(sample.strokes.map((s) => resample(s).map((p) => Point2(
      (p.x - (minX + maxX) / 2) / scale, (p.y - (minY + maxY) / 2) / scale))));
}

/// Discrete Fréchet distance with O(m) working memory.
double frechet(List<Point2> a, List<Point2> b) {
  if (a.isEmpty || b.isEmpty) return double.infinity;
  var previous = List.filled(b.length, double.infinity);
  for (var i = 0; i < a.length; i++) {
    final row = List.filled(b.length, double.infinity);
    for (var j = 0; j < b.length; j++) {
      final distance = a[i].distance(b[j]);
      if (i == 0 && j == 0) {
        row[j] = distance;
      } else {
        row[j] = math.max(
            distance,
            math.min(
                previous[j],
                math.min(j > 0 ? previous[j - 1] : double.infinity,
                    j > 0 ? row[j - 1] : double.infinity)));
      }
    }
    previous = row;
  }
  return previous.last;
}

class GestureTemplate {
  GestureTemplate(this.name, this.sample) : normalized = normalize(sample);
  final String name;
  final GestureSample sample;
  final GestureSample normalized;
}

class Recognition {
  const Recognition(this.name, this.distance, this.accepted);
  final String? name;
  final double distance;
  final bool accepted;
  double get similarity => distance.isFinite ? (1 - distance).clamp(0, 1) : 0;
}

class GestureRecognizer {
  double threshold = 0.25;
  Recognition recognize(
      GestureSample sample, Iterable<GestureTemplate> templates) {
    if (!sample.isValid) return const Recognition(null, double.infinity, false);
    final query = normalize(sample);
    String? name;
    var best = double.infinity;
    for (final template in templates) {
      final strokes = template.normalized.strokes;
      if (strokes.length != query.strokes.length) continue;
      final costs = query.strokes
          .map((a) => strokes.map((b) => frechet(a, b)).toList())
          .toList();
      // <=5 fingers: exact assignment avoids transient contact IDs and greedy matches.
      double assign(int row, int used, double worst) {
        if (row == costs.length) return worst;
        var result = double.infinity;
        for (var col = 0; col < costs.length; col++) {
          if (used & (1 << col) == 0) {
            result = math.min(
                result,
                assign(row + 1, used | (1 << col),
                    math.max(worst, costs[row][col])));
          }
        }
        return result;
      }

      final distance = assign(0, 0, 0);
      if (distance < best) {
        best = distance;
        name = template.name;
      }
    }
    return Recognition(name, best, best <= threshold);
  }
}
