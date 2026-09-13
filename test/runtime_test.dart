import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/data/config_store.dart';
import 'package:fluent_gesture/models/config.dart';
import 'package:fluent_gesture/platform/native_bridge.dart';
import 'package:fluent_gesture/services/gesture_runtime.dart';
import 'package:fluent_gesture/engine/rule_matcher.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'fakes.dart';

void main() {
  test(
    'application precedence, case-insensitive paths, fallback and conflicts',
    () {
      final matcher = RuleMatcher();
      final global = rule('global');
      final app = rule('app', application: r'C:\Apps\Editor.exe');
      expect(
        matcher
            .match(
              twoFingerSample(),
              [global, app],
              r'c:/apps/EDITOR.exe',
              const AppSettings(),
            )
            .rule!
            .id,
        'app',
      );
      expect(
        matcher
            .match(
              twoFingerSample(),
              [
                global,
                rule(
                  'vertical',
                  application: app.scope.executable,
                  vertical: true,
                ),
              ],
              app.scope.executable,
              const AppSettings(),
            )
            .rule!
            .id,
        'global',
      );
      expect(
        matcher
            .match(
              twoFingerSample(),
              [global, rule('duplicate')],
              '',
              const AppSettings(),
            )
            .conflict,
        isTrue,
      );
      expect(
        matcher
            .match(
              twoFingerSample(),
              [app, rule('app2', application: app.scope.executable), global],
              app.scope.executable,
              const AppSettings(),
            )
            .conflict,
        isTrue,
      );
      expect(
        matcher
            .match(
              twoFingerSample(),
              [rule('off', enabled: false)],
              '',
              const AppSettings(),
            )
            .rule,
        isNull,
      );
    },
  );

  late FakeBridge bridge;
  late RuleBook book;
  late GestureRuntime runtime;
  setUp(() async {
    bridge = FakeBridge();
    book = RuleBook(MemoryConfigStore(AppConfig(rules: [rule('right')])));
    await book.load();
    runtime = GestureRuntime(book, bridge);
    await runtime.initialize();
  });
  tearDown(() {
    runtime.dispose();
    book.dispose();
  });
  test('two fingers execute once and replayed sessions are ignored', () async {
    sendGesture(bridge, 1);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.executed.length, 1);
    sendGesture(bridge, 1);
    expect(bridge.executed.length, 1);
    sendGesture(bridge, 2, fingers: 1);
    expect(bridge.executed.length, 1);
  });
  test(
    'edit captures a sample and test only reports the intended action',
    () async {
      await runtime.setMode(RuntimeMode.edit);
      runtime.armRecording();
      sendGesture(bridge, 1);
      expect(runtime.recording.sample, isNotNull);
      expect(runtime.recording.fingers, 2);
      expect(bridge.executed, isEmpty);
      await runtime.setMode(RuntimeMode.test);
      sendGesture(bridge, 2);
      expect(runtime.lastMatch!.rule!.name, 'right');
      expect(runtime.message, contains('未执行'));
      expect(bridge.executed, isEmpty);
      runtime.clear();
      expect(runtime.strokes, isEmpty);
    },
  );
  test(
    'pause restores state after editing and self-window never executes',
    () async {
      await runtime.togglePause();
      sendGesture(bridge, 1);
      expect(bridge.executed, isEmpty);
      await runtime.setMode(RuntimeMode.edit);
      runtime.armRecording();
      sendGesture(bridge, 2);
      expect(runtime.recording.sample, isNotNull);
      await runtime.setMode(RuntimeMode.monitor);
      expect(runtime.paused, isTrue);
      await runtime.togglePause();
      sendGesture(bridge, 3, self: true);
      expect(bridge.executed, isEmpty);
    },
  );
  test(
    'target changes and cancellation discard remaining contacts until release',
    () async {
      for (var i = 0; i < 10; i++) {
        bridge.onFrame!(frame(1, i));
      }
      bridge.onFrame!(frame(1, 10, application: r'C:\Apps\Other.exe'));
      for (var i = 11; i <= 24; i++) {
        bridge.onFrame!(frame(1, i));
      }
      expect(bridge.executed, isEmpty);
      bridge.onCancel!('设备断开');
      sendGesture(bridge, 2);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.executed.length, 1);
    },
  );
  test('failure feedback and bounded 100-entry history', () async {
    bridge.outcome = const ActionResult(false, '目标权限较高');
    sendGesture(bridge, 1);
    await Future<void>.delayed(Duration.zero);
    expect(runtime.message, contains('目标权限较高'));
    for (var i = 0; i < 120; i++) {
      bridge.onCancel!('断开 $i');
    }
    expect(runtime.entries.length, 100);
  });
  test('higher finger setting suppresses existing two-finger rules', () {
    book.config = AppConfig(
      rules: book.config.rules,
      settings: const AppSettings(minimumFingers: 3),
    );
    sendGesture(bridge, 1);
    expect(bridge.executed, isEmpty);
    expect(runtime.message, contains('3 指'));
  });
  test(
    'release while paused allows the very first gesture after resume',
    () async {
      bridge.onFrame!(frame(1, 0));
      bridge.onFrame!(frame(1, 1));
      await runtime.togglePause();
      bridge.onFrame!(frame(1, 24, valid: false));
      await runtime.togglePause();
      sendGesture(bridge, 2);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.executed.length, 1);
    },
  );
  test('native frame parser rejects malformed or duplicate contacts', () {
    expect(
      () => TouchpadFrame.fromMap({
        'contacts': [
          {'id': 1, 'x': double.nan, 'y': 0},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => TouchpadFrame.fromMap({
        'contacts': [
          {'id': 1, 'x': 0, 'y': 0},
          {'id': 1, 'x': 0, 'y': 0},
        ],
      }),
      throwsFormatException,
    );
  });
  test(
    'a timestamp gap cancels the entire contact cycle before timer runs',
    () async {
      for (var i = 0; i < 12; i++) {
        bridge.onFrame!(frame(1, i));
      }
      for (var i = 12; i <= 24; i++) {
        final next = frame(1, i);
        bridge.onFrame!(
          TouchpadFrame(
            device: next.device,
            timeMs: next.timeMs + 900,
            session: next.session,
            application: next.application,
            contacts: next.contacts,
          ),
        );
      }
      expect(bridge.executed, isEmpty);
      sendGesture(bridge, 3);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.executed.length, 1);
    },
  );
  test(
    'two sequential single contacts never qualify as two simultaneous fingers',
    () {
      for (var i = 0; i < 24; i++) {
        bridge.onFrame!(
          TouchpadFrame(
            device: 'pad',
            timeMs: 1000 + i * 16,
            session: 1,
            application: r'C:\Apps\Editor.exe',
            contacts: {
              i < 12 ? 1 : 2: Point2(.1 + (i % 12) / 15, i < 12 ? .2 : .5),
            },
          ),
        );
      }
      bridge.onFrame!(frame(1, 24));
      expect(runtime.lastSample!.strokes.length, 2);
      expect(runtime.message, contains('同时参与'));
      expect(bridge.executed, isEmpty);
    },
  );
  test(
    'every action kind is dispatched once through the mock executor',
    () async {
      for (final kind in ActionKind.values) {
        final action = GestureAction(
          kind,
          keys: const [17, 87],
          program: r'C:\Apps\Editor.exe',
          arguments: '--new',
          directory: r'C:\Apps',
          volumeStep: 17,
        );
        expect(action.error, isNull);
        await book.saveRule(
          GestureRule(
            id: 'right',
            name: 'right',
            sample: twoFingerSample(),
            recordedFingers: 2,
            action: action,
            enabled: true,
          ),
        );
        sendGesture(bridge, kind.index + 1);
        await Future<void>.delayed(Duration.zero);
        expect(bridge.executed.last.kind, kind);
        expect(bridge.executed.last.toJson(), action.toJson());
      }
      expect(bridge.executed.length, ActionKind.values.length);
    },
  );
}
