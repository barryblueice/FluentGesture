import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/data/config_store.dart';
import 'package:fluent_gesture/engine/capture.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/engine/rule_matcher.dart';
import 'package:fluent_gesture/models/config.dart';
import 'package:fluent_gesture/platform/native_bridge.dart';
import 'package:fluent_gesture/services/gesture_runtime.dart';
import 'fakes.dart';

GestureSample tap(int fingers, [double x = .2]) => GestureSample([
  for (var i = 0; i < fingers; i++) [Point2(x, .2 + i * .1)],
]);
GestureRule tapRule(String id, int fingers, {String app = ''}) => GestureRule(
  id: id,
  name: id,
  sample: tap(fingers),
  recordedFingers: fingers,
  scope: ApplicationScope(app),
  enabled: true,
  action: const GestureAction(ActionKind.desktop),
);

void main() {
  test(
    'tap recording and execution honor every minimum from two to five fingers',
    () async {
      for (var minimum = 2; minimum <= 5; minimum++) {
        final book = RuleBook(
          MemoryConfigStore(
            AppConfig(
              settings: AppSettings(minimumFingers: minimum),
              rules: [tapRule('below', minimum - 1), tapRule('exact', minimum)],
            ),
          ),
        );
        await book.load();
        final bridge = FakeBridge();
        final runtime = GestureRuntime(book, bridge);
        await runtime.initialize();
        try {
          void contact(int session, int count) {
            runtime.feed(
              TouchpadFrame(
                device: 'pad',
                timeMs: session * 100,
                session: session,
                application: r'C:\App.exe',
                contacts: {
                  for (var i = 0; i < count; i++) i: Point2(.3, .1 + i * .15),
                },
              ),
            );
            runtime.feed(
              TouchpadFrame(
                device: 'pad',
                timeMs: session * 100 + 16,
                session: session,
                application: r'C:\App.exe',
                contacts: {},
              ),
            );
          }

          await runtime.setMode(RuntimeMode.edit);
          runtime.armRecording();
          contact(1, minimum - 1);
          expect(runtime.recording.armed, isTrue);
          expect(runtime.recording.sample, isNull);
          contact(2, minimum);
          expect(runtime.recording.armed, isFalse);
          expect(runtime.recording.fingers, minimum);
          await runtime.setMode(RuntimeMode.test);
          contact(3, minimum - 1);
          expect(runtime.lastMatch!.rule, isNull);
          await runtime.setMode(RuntimeMode.monitor);
          contact(4, minimum - 1);
          expect(bridge.executed, isEmpty);
          contact(5, minimum);
          await Future<void>.delayed(Duration.zero);
          expect(bridge.executed.length, 1);
        } finally {
          runtime.dispose();
          book.dispose();
        }
      }
    },
  );
  test('single-point contacts finish as valid immutable tap samples', () {
    final capture = GestureCapture();
    capture.addFrame({1: const Point2(.2, .3)}, 0);
    final result = capture.addFrame({}, 16)!;
    expect(result.isValid, isTrue);
    expect(result.isTap, isTrue);
    expect(result.strokes.single.length, 1);
    expect(capture.activeCount, 0);
    expect(() => result.strokes.single.clear(), throwsUnsupportedError);
    expect(GestureSample.fromJson(result.toJson()).isTap, isTrue);
    expect(GestureSample([]).isValid, isFalse);
    expect(GestureSample([<Point2>[]]).isValid, isFalse);
    expect(
      GestureSample([
        [const Point2(double.nan, 0)],
      ]).isValid,
      isFalse,
    );
  });

  test(
    'tap matching ignores location but separates count, motion and conflicts',
    () {
      final matcher = RuleMatcher();
      const settings = AppSettings();
      final rules = [tapRule('two', 2), tapRule('three', 3)];
      expect(matcher.match(tap(1, .8), rules, '', settings).rule, isNull);
      expect(matcher.match(tap(2, .7), rules, '', settings).rule?.id, 'two');
      expect(
        matcher.match(tap(2), rules, '', settings, simultaneousFingers: 1).rule,
        isNull,
      );
      expect(
        matcher
            .match(tap(2), [...rules, tapRule('duplicate', 2)], '', settings)
            .conflict,
        isTrue,
      );
      expect(
        matcher
            .match(
              tap(2),
              [...rules, tapRule('app', 2, app: r'C:\App.exe')],
              r'c:\app.exe',
              settings,
            )
            .rule
            ?.id,
        'app',
      );
      final recognizer = GestureRecognizer();
      expect(
        recognizer.recognize(tap(2), [
          GestureTemplate('swipe', twoFingerSample()),
        ]).accepted,
        isFalse,
      );
      expect(
        recognizer.recognize(twoFingerSample(), [
          GestureTemplate('tap', tap(2)),
        ]).accepted,
        isFalse,
      );
      final jitter = GestureSample([
        [const Point2(.2, .3), const Point2(.201, .301)],
        [const Point2(.2, .5)],
      ]);
      expect(jitter.isTap, isTrue);
      expect(matcher.match(jitter, rules, '', settings).rule?.id, 'two');
    },
  );

  test(
    'legacy single-finger taps load disabled without losing the template or action',
    () {
      final config = AppConfig(
        settings: const AppSettings(minimumFingers: 5),
        rules: [tapRule('tap', 1)],
      );
      final loaded = ConfigStore.decode(jsonEncode(config.toJson()));
      expect(loaded.rules.single.enabled, isFalse);
      expect(loaded.rules.single.sample!.isTap, isTrue);
      expect(loaded.rules.single.copy(enabled: true).validation(5), isNotNull);
      expect(loaded.rules.single.action!.kind, ActionKind.desktop);
      expect(
        GestureRule(
          id: 'bad',
          name: 'bad',
          sample: tap(2),
          recordedFingers: 1,
          enabled: true,
          action: const GestureAction(ActionKind.desktop),
        ).validation(2),
        isNotNull,
      );
    },
  );

  test(
    'taps record and test without executing; monitoring executes once on lift',
    () async {
      final book = RuleBook(
        MemoryConfigStore(AppConfig(rules: [tapRule('tap', 2)])),
      );
      await book.load();
      final bridge = FakeBridge();
      final runtime = GestureRuntime(book, bridge);
      await runtime.initialize();
      addTearDown(() {
        runtime.dispose();
        book.dispose();
      });
      void feed(int session, int time, Map<int, Point2> contacts) =>
          runtime.feed(
            TouchpadFrame(
              device: 'pad',
              timeMs: time,
              session: session,
              application: r'C:\App.exe',
              contacts: contacts,
            ),
          );
      await runtime.setMode(RuntimeMode.edit);
      runtime.armRecording();
      feed(1, 0, {1: const Point2(.2, .3), 2: const Point2(.2, .5)});
      feed(1, 16, {});
      expect(runtime.recording.armed, isFalse);
      expect(runtime.recording.sample!.isTap, isTrue);
      expect(runtime.recording.fingers, 2);
      expect(runtime.message, contains('2 指点触'));
      expect(bridge.executed, isEmpty);
      await runtime.setMode(RuntimeMode.test);
      feed(2, 32, {1: const Point2(.7, .8), 2: const Point2(.7, .6)});
      feed(2, 48, {});
      expect(runtime.lastMatch!.rule?.id, 'tap');
      expect(bridge.executed, isEmpty);
      await runtime.setMode(RuntimeMode.monitor);
      feed(3, 64, {1: const Point2(.7, .8), 2: const Point2(.7, .6)});
      expect(bridge.executed, isEmpty);
      feed(3, 80, {});
      feed(3, 96, {});
      await Future<void>.delayed(Duration.zero);
      expect(bridge.executed.length, 1);
      feed(4, 112, {1: const Point2(.7, .8), 2: const Point2(.7, .6)});
      runtime.cancel();
      feed(4, 128, {});
      expect(bridge.executed.length, 1);
    },
  );
}
