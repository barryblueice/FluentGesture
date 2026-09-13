import 'package:flutter/gestures.dart';
import 'package:fluent_gesture/widgets/app_slider.dart';
import 'package:fluent_gesture/widgets/gesture_canvas.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fluent_gesture/main.dart';
import 'package:fluent_gesture/models/config.dart';
import '../test/fakes.dart';
import 'package:fluent_gesture/platform/native_bridge.dart';
import 'package:fluent_gesture/widgets/shortcut_recorder.dart';

void main() {
  if (!const bool.fromEnvironment('FLUENT_GESTURE_UI_TEST')) {
    throw StateError('Use tools/test_accessibility.py for the isolated host.');
  }
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Windows recording captures either Win key alone and Win combinations',
    (tester) async {
      const channel = MethodChannel('fluentgesture/ax-test');
      final bridge = NativeBridge();
      List<int>? result;
      await tester.pumpWidget(
        FluentApp(
          home: Builder(
            builder: (context) => Center(
              child: Button(
                onPressed: () async => result = await showShortcutRecorder(
                  context,
                  bridge: bridge,
                ),
                child: const Text('录入'),
              ),
            ),
          ),
        ),
      );
      Future<void> frames() async {
        for (var n = 0; n < 6; n++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await frames();
      for (var variant = 0; variant < 4; variant++) {
        await channel.invokeMethod<void>('mark', 'Win test $variant');
        var injected = false;
        for (var attempt = 0; attempt < 5 && !injected; attempt++) {
          expect(await channel.invokeMethod<bool>('focus'), isTrue);
          await frames();
          await tester.tap(find.text(attempt == 0 ? '录入' : '重新录制'));
          await frames();
          if (find.text('请松开按键后点击重新录制').evaluate().isNotEmpty ||
              find.text('录制已中断，请激活窗口后点击重新录制').evaluate().isNotEmpty) {
            continue;
          }
          try {
            // Foreground can change between the frame pump and native call.
            // The host refuses injection unless its recording hook is armed.
            await channel.invokeMethod<void>('recordWinTest', variant);
            injected = true;
          } on PlatformException catch (error) {
            if (error.code != 'not_recording') rethrow;
          }
        }
        expect(
          injected,
          isTrue,
          reason: 'The isolated recording window could not stay active',
        );
        await frames();
        expect(
          find.text('已录制'),
          findsOneWidget,
          reason: find
              .byType(Text)
              .evaluate()
              .map((element) => (element.widget as Text).data)
              .join(' | '),
        );
        expect(await channel.invokeMethod<bool>('foreground'), isTrue);
        await tester.tap(find.text('使用此快捷键'));
        await frames();
        expect(result, [variant.isEven ? 91 : 92, if (variant >= 2) 124]);
      }
      await tester.pumpWidget(const SizedBox());
      await frames();
    },
  );
  testWidgets(
    'Windows AXTree stays valid across editor, dialogs, menus and pages',
    (tester) async {
      // Fixed advances avoid waiting on real-time text cursor blink timers.
      Future<void> frames() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(String text) async {
        await const MethodChannel(
          'fluentgesture/ax-test',
        ).invokeMethod<void>('mark', text);
        await tester.ensureVisible(find.text(text).last);
        await tester.tap(find.text(text).last);
        await frames();
      }

      final bridge = FakeBridge();
      final store = MemoryConfigStore(
        AppConfig(rules: [rule('关闭标签页'), rule('第二条规则')]),
      );
      await tester.pumpWidget(FluentGestureApp(store: store, bridge: bridge));
      await frames();
      expect(tester.binding.platformDispatcher.semanticsEnabled, isTrue);
      for (var iteration = 0; iteration < 3; iteration++) {
        await tap('关闭标签页');
        await tap('Ctrl + W');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await frames();
        expect(find.text('Ctrl + K'), findsOneWidget);
        await tap('取消');
        await tap('第二条规则');
        await tester.enterText(find.byKey(const Key('rule-name')), '临时修改');
        await frames();
        await tap('设置');
        await tap('放弃修改');
        await tap(iteration == 0 ? '2 指及以上' : '3 指及以上');
        await tap('3 指及以上');
        final slider = find.byType(AppSlider);
        await tester.ensureVisible(slider);
        final position = tester.getCenter(slider);
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: Offset.zero);
        await pointer.moveTo(position);
        await frames();
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: position,
            scrollDelta: const Offset(0, 60),
          ),
        );
        await frames();
        await pointer.moveTo(const Offset(8, 8));
        await pointer.removePointer();
        await tester.drag(slider, const Offset(35, 0));
        await frames();
        await tap(
          iteration == 0
              ? '跟随系统'
              : iteration == 1
              ? '深色'
              : '浅色',
        );
        await tap(iteration.isEven ? '深色' : '浅色');
        expect(find.text('设备与运行记录'), findsNothing);
        await tap('录制与测试');
        await tap('清空');
        await tap('全部规则');
        // Exercise the changing canvas and recording controls with real AXTree.
        await tap('新建规则');
        for (var cycle = 0; cycle < 3; cycle++) {
          await const MethodChannel(
            'fluentgesture/ax-test',
          ).invokeMethod<void>('mark', '点击画布录制');
          await tester.ensureVisible(find.byType(GestureCanvas));
          await tester.tap(find.byType(GestureCanvas));
          await frames();
          expect(find.text('取消录制'), findsOneWidget);
          for (var step = 0; step <= 12; step++) {
            bridge.onFrame!(
              TouchpadFrame(
                device: 'pad',
                timeMs: 2000 + cycle * 300 + step * 16,
                session: 20 + iteration * 3 + cycle,
                application: '',
                isSelf: true,
                contacts: step == 12
                    ? {}
                    : {
                        for (var finger = 0; finger < 3; finger++)
                          finger: Point2(.15 + step * .03, .2 + finger * .15),
                      },
              ),
            );
            await tester.pump(const Duration(milliseconds: 16));
          }
          await frames();
        }
        await tap('取消');
        await tap('放弃修改');
      }
      expect(bridge.executed, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await frames();
    },
  );
}
