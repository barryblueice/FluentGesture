import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/widgets/shortcut_recorder.dart';

void main() {
  Future<void> openRecorder(
    WidgetTester tester,
    ValueChanged<List<int>?> onResult,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        home: Builder(
          builder: (context) => Center(
            child: Button(
              onPressed: () async =>
                  onResult(await showShortcutRecorder(context)),
              child: const Text('录入'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('录入'));
    await tester.pumpAndSettle();
    expect(find.text('正在录制，请按下需要的组合键。'), findsOneWidget);
  }

  testWidgets(
    'modifiers display live, release retains result, accept returns VKs',
    (tester) async {
      List<int>? result;
      await openRecorder(tester, (value) => result = value);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
      await tester.pump();
      expect(find.text('Ctrl + Shift'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Ctrl + Shift + W'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('使用此快捷键'));
      // The editor must not rebuild while the outgoing dialog owns AX nodes.
      await tester.pump();
      expect(result, isNull);
      expect(find.byType(ShortcutRecorder), findsOneWidget);
      await tester.pumpAndSettle();
      expect(result, [17, 16, 87]);
      expect(find.byType(ShortcutRecorder), findsNothing);
    },
  );

  testWidgets('rerecord clears pending keys and cancel returns no change', (
    tester,
  ) async {
    List<int>? result = [17, 87];
    await openRecorder(tester, (value) {
      if (value != null) result = value;
    });
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    await tester.tap(find.text('重新录制'));
    await tester.pump();
    expect(find.text('等待按键…'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(find.text('Alt'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(find.text('等待按键…'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, [17, 87]);
    expect(find.byType(ShortcutRecorder), findsNothing);
  });

  for (final entry in {
    LogicalKeyboardKey.escape: 27,
    LogicalKeyboardKey.tab: 9,
    LogicalKeyboardKey.enter: 13,
  }.entries) {
    testWidgets(
      '${entry.key.keyLabel} records without dismissing or activating dialog',
      (tester) async {
        List<int>? result;
        await openRecorder(tester, (value) => result = value);
        await tester.sendKeyEvent(entry.key);
        await tester.pumpAndSettle();
        expect(find.byType(ShortcutRecorder), findsOneWidget);
        expect(find.text('已录制'), findsOneWidget);
        expect(result, isNull);
        await tester.tap(find.text('使用此快捷键'));
        await tester.pumpAndSettle();
        expect(result, [entry.value]);
      },
    );
  }
  for (final entry in {
    LogicalKeyboardKey.metaLeft: 91,
    LogicalKeyboardKey.metaRight: 92,
  }.entries) {
    testWidgets(
      '${entry.key.keyLabel} can be recorded alone or with a main key',
      (tester) async {
        List<int>? result;
        await openRecorder(tester, (value) => result = value);
        await tester.sendKeyDownEvent(entry.key);
        await tester.pump();
        expect(find.text('Win'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.sendKeyUpEvent(entry.key);
        await tester.pump();
        expect(find.text('已录制'), findsOneWidget);
        await tester.tap(find.text('使用此快捷键'));
        await tester.pumpAndSettle();
        expect(result, [entry.value]);
        await tester.tap(find.text('录入'));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(entry.key);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(entry.key);
        await tester.pumpAndSettle();
        expect(find.text('Win + K'), findsOneWidget);
        await tester.tap(find.text('使用此快捷键'));
        await tester.pumpAndSettle();
        expect(result, [entry.value, 75]);
      },
    );
  }
}
