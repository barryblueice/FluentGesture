import 'dart:io';
import 'dart:ui' as ui;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/main.dart';
import 'package:fluent_gesture/widgets/gesture_canvas.dart';
import 'package:fluent_gesture/models/config.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/platform/native_bridge.dart';
import 'fakes.dart';

Future<void> sendFrames(
  WidgetTester tester,
  FakeBridge bridge,
  int session,
) async {
  for (var i = 0; i <= 24; i++) {
    bridge.onFrame!(frame(session, i, self: true));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

Future<void> preview(
  WidgetTester tester,
  GlobalKey key,
  String filename,
) async {
  if (!const bool.fromEnvironment('WRITE_PREVIEW')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/$filename.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> setupView(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (const bool.fromEnvironment('WRITE_PREVIEW')) {
    await tester.runAsync(() async {
      final font = File(
        '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc',
      );
      if (await font.exists()) {
        final bytes = await font.readAsBytes();
        await (FontLoader(
          'Microsoft YaHei',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader('packages/fluent_ui/FluentIcons')..addFont(
            rootBundle.load('packages/fluent_ui/fonts/FluentIcons.ttf'),
          ))
          .load();
    });
  }
}

void main() {
  testWidgets(
    'canvas click arms recording and taps require the configured finger count',
    (tester) async {
      await setupView(tester);
      final bridge = FakeBridge();
      final store = MemoryConfigStore();
      await tester.pumpWidget(FluentGestureApp(store: store, bridge: bridge));
      await tester.pumpAndSettle();
      expect(find.text('规则预设'), findsNothing);
      await tester.tap(find.text('新建规则'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rule-name')), '点触桌面');
      final canvas = find.byType(GestureCanvas);
      await tester.tap(canvas);
      await tester.pumpAndSettle();
      expect(find.text('取消录制'), findsOneWidget);
      expect(tester.widget<GestureCanvas>(canvas).strokes, isEmpty);
      for (var fingers = 1; fingers <= 2; fingers++) {
        for (final release in [false, true]) {
          bridge.onFrame!(
            TouchpadFrame(
              device: 'pad',
              timeMs: fingers * 1000 + (release ? 16 : 0),
              session: fingers,
              application: '',
              isSelf: true,
              contacts: release
                  ? {}
                  : {
                      for (var i = 0; i < fingers; i++)
                        i: Point2(.4, .3 + i * .2),
                    },
            ),
          );
          await tester.pumpAndSettle();
          if (!release) {
            await tester.tap(canvas);
            await tester.pumpAndSettle();
            expect(
              tester.widget<GestureCanvas>(canvas).strokes.length,
              fingers,
            );
          }
        }
        if (fingers == 1) {
          expect(find.text('取消录制'), findsOneWidget);
          expect(find.text('至少需要 2 指同时参与'), findsOneWidget);
        }
      }
      expect(find.text('2 指点触'), findsOneWidget);
      expect(tester.widget<GestureCanvas>(canvas).strokes.length, 2);
      await tester.ensureVisible(find.text('键盘快捷键'));
      await tester.tap(find.text('键盘快捷键'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示桌面').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.saved.rules.single.sample!.isTap, isTrue);
      expect(store.saved.rules.single.recordedFingers, 2);
      expect(store.saved.rules.single.enabled, isTrue);
      expect(store.saved.rules.single.action!.kind, ActionKind.desktop);
      expect(bridge.executed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'create rule with touchpad only, save shortcut, test without execution',
    (tester) async {
      await setupView(tester);
      final store = MemoryConfigStore();
      final bridge = FakeBridge();
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewKey,
          child: FluentGestureApp(store: store, bridge: bridge),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建规则'));
      await tester.pumpAndSettle();
      expect(bridge.mode, 'edit');
      await tester.enterText(find.byKey(const Key('rule-name')), '关闭标签页');
      await tester.tap(find.text('录制手势'));
      await tester.pumpAndSettle();
      final canvas = find.byType(GestureCanvas);
      expect(canvas, findsOneWidget);
      for (final kind in [
        ui.PointerDeviceKind.mouse,
        ui.PointerDeviceKind.touch,
      ]) {
        final pointer = await tester.startGesture(
          tester.getCenter(canvas),
          kind: kind,
        );
        await pointer.moveBy(const Offset(60, 0));
        await pointer.up();
        await tester.pumpAndSettle();
        expect(tester.widget<GestureCanvas>(canvas).strokes, isEmpty);
      }
      await sendFrames(tester, bridge, 1);
      expect(tester.widget<GestureCanvas>(canvas).strokes.length, 2);
      await tester.ensureVisible(find.text('录入快捷键'));
      await tester.tap(find.text('录入快捷键'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Ctrl + W'), findsOneWidget);
      await preview(tester, previewKey, 'shortcut-recorder');
      await tester.tap(find.text('使用此快捷键'));
      await tester.pumpAndSettle();
      await preview(tester, previewKey, 'rules-editor');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.saved.rules.single.name, '关闭标签页');
      expect(store.saved.rules.single.enabled, isTrue);
      expect(bridge.executed, isEmpty);
      expect(bridge.mode, 'monitor');
      await tester.tap(find.text('录制与测试').first);
      await tester.pumpAndSettle();
      await sendFrames(tester, bridge, 2);
      expect(find.textContaining('测试匹配：'), findsOneWidget);
      expect(bridge.executed, isEmpty);
      expect(
        tester.widget<GestureCanvas>(find.byType(GestureCanvas)).strokes.length,
        2,
      );
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<GestureCanvas>(find.byType(GestureCanvas)).strokes,
        isEmpty,
      );
      tester.view.physicalSize = const Size(600, 900);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unsaved edit guard, theme changes, close to tray and narrow navigation',
    (tester) async {
      await setupView(tester);
      final store = MemoryConfigStore(
        AppConfig(
          rules: [
            rule('关闭标签页'),
            rule('返回上一页', application: r'C:\Apps\Browser.exe'),
          ],
        ),
      );
      final bridge = FakeBridge();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: FluentGestureApp(store: store, bridge: bridge),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭标签页'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rule-name')), '修改中');
      await tester.tap(find.text('设置').first);
      await tester.pumpAndSettle();
      expect(find.text('保存修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rule-name')), findsOneWidget);
      await tester.tap(find.text('设置').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(store.saved.rules.first.name, '关闭标签页');
      expect(find.text('设备与运行记录'), findsNothing);
      expect(find.textContaining('最后收到数据：'), findsNothing);
      expect(find.text('退出 FluentGesture'), findsOneWidget);
      await tester.tap(find.text('跟随系统'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      expect(store.saved.settings.theme, 'dark');
      expect(
        FluentTheme.of(
          tester.element(find.byType(RuleWindow)),
        ).scaffoldBackgroundColor,
        const Color(0xff202020),
      );
      await preview(tester, key, 'settings-dark');
      bridge.onCloseRequested!();
      await tester.pumpAndSettle();
      expect(bridge.hidden, isTrue);
      expect(bridge.mode, 'monitor');
      tester.view.physicalSize = const Size(600, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'app selection, launch action, disabled duplicate, search and delete',
    (tester) async {
      await setupView(tester);
      final store = MemoryConfigStore(AppConfig(rules: [rule('原规则')]));
      final bridge = FakeBridge();
      await tester.pumpWidget(FluentGestureApp(store: store, bridge: bridge));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全局').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('指定应用').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览文件'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextBox>(find.byKey(const Key('rule-application')))
            .controller!
            .text,
        r'C:\Apps\Editor.exe',
      );
      await tester.tap(find.text('运行中的应用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试编辑器'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('键盘快捷键'));
      await tester.tap(find.text('键盘快捷键'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启动程序').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择程序'));
      await tester.tap(find.text('选择程序'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('action-arguments')),
        '--new-window',
      );
      await tester.enterText(
        find.byKey(const Key('action-directory')),
        r'C:\Apps',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.saved.rules.single.scope.executable, r'C:\Apps\Editor.exe');
      expect(store.saved.rules.single.action!.kind, ActionKind.launch);
      expect(store.saved.rules.single.action!.arguments, '--new-window');
      await tester.tap(find.byKey(const ValueKey('rule-menu-原规则')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.saved.rules.length, 2);
      expect(store.saved.rules.last.enabled, isFalse);
      await tester.enterText(find.byType(TextBox).first, '副本');
      await tester.pumpAndSettle();
      expect(find.text('原规则'), findsNothing);
      final copy = store.saved.rules.last;
      await tester.tap(find.byKey(ValueKey('rule-menu-${copy.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(store.saved.rules.length, 1);
      expect(bridge.executed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('tray exit respects unsaved changes and canvas clear persists', (
    tester,
  ) async {
    await setupView(tester);
    final store = MemoryConfigStore(AppConfig(rules: [rule('清空测试')]));
    final bridge = FakeBridge();
    await tester.pumpWidget(FluentGestureApp(store: store, bridge: bridge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空测试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<GestureCanvas>(find.byType(GestureCanvas)).strokes,
      isEmpty,
    );
    bridge.onExitRequested!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(bridge.exited, isFalse);
    await tester.ensureVisible(find.text('启用此规则'));
    await tester.tap(find.byType(ToggleSwitch));
    await tester.pumpAndSettle();
    bridge.onExitRequested!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存').last);
    await tester.pumpAndSettle();
    expect(store.saved.rules.single.sample, isNull);
    expect(store.saved.rules.single.enabled, isFalse);
    expect(bridge.exited, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
