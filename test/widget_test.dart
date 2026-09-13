import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/main.dart';
import 'package:fluent_gesture/data/gesture_store.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/widgets/gesture_canvas.dart';

class MemoryStore extends GestureStore {
  MemoryStore() : super(File('test-gestures.json'));
  List<GestureTemplate> saved = [];
  @override
  Future<List<GestureTemplate>> load() async => List.of(saved);
  @override
  Future<void> save(List<GestureTemplate> templates) async {
    saved = List.of(templates);
  }
}

void main() {
  testWidgets(
      'touchpad-only studio records native frames at desktop and narrow widths',
      (tester) async {
    final store = MemoryStore();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluentgesture/input'),
        (call) async => call.method == 'start' ? 'Test device' : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dev.fluentgesture/input'), null));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (const bool.fromEnvironment('WRITE_PREVIEW')) {
      await tester.runAsync(() async {
        final font = File(
            '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc');
        if (await font.exists()) {
          final bytes = await font.readAsBytes();
          await (FontLoader('Microsoft YaHei')
                ..addFont(Future.value(ByteData.sublistView(bytes))))
              .load();
        }
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
    }
    final previewKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: previewKey, child: FluentGestureApp(store: store)));
    await tester.pumpAndSettle();
    final recordButton = find.byWidgetPredicate((w) => w is FilledButton);
    expect(
        tester.widget<FilledButton>(recordButton.first).onPressed, isNotNull);
    expect(find.text('FluentGesture'), findsOneWidget);
    expect(find.text('还没有录制模板'), findsOneWidget);
    await tester.tap(find.text('录制手势  R'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '向右滑动');
    await tester.tap(find.text('开始录制'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('画布输入'), findsNothing);
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    final canvas = find.byType(GestureCanvas);
    expect(canvas, findsOneWidget);
    // Neither mouse nor touchscreen drags on the canvas create strokes.
    for (final kind in [
      ui.PointerDeviceKind.mouse,
      ui.PointerDeviceKind.touch
    ]) {
      final pointer =
          await tester.startGesture(tester.getCenter(canvas), kind: kind);
      await pointer.moveBy(const Offset(80, 0));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(tester.widget<GestureCanvas>(canvas).strokes, isEmpty);
    }
    expect(store.saved, isEmpty);
    // Exercise the actual native channel callback with complete HID frames.
    for (var i = 0; i <= 20; i++) {
      tester.binding.channelBuffers.push(
        'dev.fluentgesture/input',
        const StandardMethodCodec().encodeMethodCall(MethodCall(
            'frame',
            i == 20
                ? []
                : [
                    {'id': 7, 'x': i / 19, 'y': 0.5}
                  ])),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 16));
      if (i == 10) {
        expect(tester.widget<GestureCanvas>(canvas).strokes.single.length,
            greaterThan(1));
      }
    }
    await tester.pumpAndSettle();
    expect(find.text('向右滑动'), findsOneWidget);
    expect(store.saved.single.name, '向右滑动');
    expect(tester.widget<GestureCanvas>(canvas).strokes.single.length,
        greaterThan(1));
    if (const bool.fromEnvironment('WRITE_PREVIEW')) {
      final boundary = previewKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/studio-preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(tester.widget<GestureCanvas>(canvas).strokes, isEmpty);
    expect(store.saved.single.name, '向右滑动');
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
