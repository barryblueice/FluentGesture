import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/data/gesture_store.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/studio_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('record, persist, restart, recognize, rename and delete', () async {
    const channel = MethodChannel('dev.fluentgesture/input');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel,
            (call) async => call.method == 'start' ? 'Test device' : null);
    final directory =
        await Directory.systemTemp.createTemp('fluentgesture_flow_');
    final store = GestureStore(File('${directory.path}/gestures.json'));
    var controller = StudioController(store);
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await controller.initialize();
    controller.arm('向右');
    void draw() {
      for (var i = 0; i < 30; i++) {
        controller.feed({1: Point2(i / 29, 0.5)});
      }
      controller.feed({});
    }

    draw();
    for (var i = 0; i < 100 && controller.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.templates.single.name, '向右');
    controller.dispose();
    controller = StudioController(store);
    await controller.initialize();
    draw();
    expect(controller.result!.accepted, isTrue);
    expect(controller.result!.name, '向右');
    controller.inputSuspended = true;
    controller.clear();
    draw();
    expect(controller.lastSample, isNull);
    controller.inputSuspended = false;
    await controller.rename(controller.templates.single, '右滑');
    expect((await store.load()).single.name, '右滑');
    await controller.delete(controller.templates.single);
    expect(await store.load(), isEmpty);
  });
}
