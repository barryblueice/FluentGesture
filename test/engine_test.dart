import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/engine/capture.dart';

List<Point2> line(double y, {bool reverse = false}) =>
    List.generate(30, (i) => Point2(reverse ? 1 - i / 29 : i / 29, y));
GestureSample sample(List<Point2> points) => GestureSample([points]);

void main() {
  test(
    'resampling keeps endpoints and handles duplicate or stationary points',
    () {
      final points = resample([
        const Point2(0, 0),
        const Point2(0, 0),
        const Point2(1, 0),
      ]);
      expect(points.length, 48);
      expect(points.first.x, 0);
      expect(points.last.x, 1);
      expect(points[24].x, closeTo(24 / 47, 1e-9));
      expect(resample([const Point2(2, 2)]).length, 48);
      expect(resample([]), isEmpty);
      expect(() => resample([], 1), throwsArgumentError);
    },
  );
  test('translation, scale and sampling speed do not alter matching', () {
    final original = sample(
      List.generate(
        60,
        (i) => Point2(
          math.cos(i / 59 * 2 * math.pi),
          math.sin(i / 59 * 2 * math.pi),
        ),
      ),
    );
    final transformed = sample(
      List.generate(90, (i) {
        final angle = math.pow(i / 89, 2) * 2 * math.pi;
        return Point2(10 + 3 * math.cos(angle), -7 + 3 * math.sin(angle));
      }),
    );
    final result = GestureRecognizer().recognize(transformed, [
      GestureTemplate('circle', original),
    ]);
    expect(result.accepted, isTrue);
    expect(result.distance, lessThan(0.03));
  });
  test('direction remains significant and finger count must agree', () {
    final template = GestureTemplate('right', sample(line(0)));
    expect(
      GestureRecognizer().recognize(sample(line(0, reverse: true)), [
        template,
      ]).accepted,
      isFalse,
    );
    expect(
      GestureRecognizer().recognize(GestureSample([line(0), line(1)]), [
        template,
      ]).name,
      isNull,
    );
    expect(
      GestureRecognizer().recognize(sample(line(0)), []).accepted,
      isFalse,
    );
  });
  test('finger permutation matches but relative geometry is preserved', () {
    final template = GestureTemplate(
      'parallel',
      GestureSample([line(0), line(0.5)]),
    );
    final recognizer = GestureRecognizer();
    expect(
      recognizer.recognize(GestureSample([line(0.5), line(0)]), [
        template,
      ]).distance,
      closeTo(0, 1e-9),
    );
    expect(
      recognizer.recognize(GestureSample([line(0), line(4)]), [
        template,
      ]).accepted,
      isFalse,
    );
  });
  test('contact IDs prevent crossing fingers from swapping tracks', () {
    final capture = GestureCapture();
    for (var i = 0; i < 20; i++) {
      capture.addFrame({
        9: Point2(i / 19, 0),
        2: Point2(1 - i / 19, 0),
      }, i * 16);
    }
    final gesture = capture.addFrame({}, 330)!;
    expect(gesture.strokes.length, 2);
    expect(gesture.strokes[0].last.x, greaterThan(0.9));
    expect(gesture.strokes[1].last.x, lessThan(0.1));
    expect(capture.activeCount, 0);
  });
  test(
    'partial lift waits for all fingers; stationary fingers are retained',
    () {
      final capture = GestureCapture();
      capture.addFrame({1: const Point2(0, 0), 2: const Point2(0, 1)}, 0);
      capture.addFrame({1: const Point2(0.5, 0), 2: const Point2(0, 1)}, 20);
      expect(capture.addFrame({1: const Point2(1, 0)}, 40), isNull);
      expect(capture.addFrame({}, 60)!.strokes.length, 2);
    },
  );
  test('silence and stale frames cancel while a tap completes normally', () {
    final capture = GestureCapture();
    capture.addFrame({1: const Point2(0, 0)}, 10);
    capture.addFrame({1: const Point2(1, 0)}, 30);
    expect(capture.addFrame({}, 20), isNull);
    expect(capture.activeCount, 1);
    expect(capture.expire(800), isTrue);
    expect(capture.addFrame({}, 810), isNull);
    capture.addFrame({1: const Point2(0, 0)}, 900);
    expect(capture.addFrame({}, 910)!.isTap, isTrue);
    capture.addFrame({1: const Point2(double.nan, 0)}, 1000);
    expect(capture.hasInput, isFalse);
  });
  test('excessive contacts and long sessions are discarded until release', () {
    final capture = GestureCapture();
    capture.addFrame({
      for (var i = 0; i < 6; i++) i: Point2(i.toDouble(), 0),
    }, 0);
    capture.addFrame({1: const Point2(0, 0)}, 20);
    expect(capture.addFrame({}, 40), isNull);
    for (var time = 100; time <= 16000; time += 100) {
      capture.addFrame({1: Point2(time / 16000, 0)}, time);
    }
    expect(capture.addFrame({}, 16010), isNull);
  });
  test(
    'completed samples are immutable and independent of future captures',
    () {
      final capture = GestureCapture();
      capture.addFrame({1: const Point2(0, 0)}, 0);
      capture.addFrame({1: const Point2(1, 0)}, 20);
      final result = capture.addFrame({}, 40)!;
      capture.reset();
      expect(result.isValid, isTrue);
      expect(() => result.strokes.first.clear(), throwsUnsupportedError);
    },
  );
}
