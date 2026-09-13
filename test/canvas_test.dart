import 'dart:ui' as ui;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/widgets/gesture_canvas.dart';

void main() {
  testWidgets(
    'canvas keeps one AX node and clicks never supply gesture points',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var starts = 0;
        Widget view(bool recording, List<List<Point2>> strokes) => FluentApp(
          home: GestureCanvas(
            strokes: strokes,
            paused: false,
            recording: recording,
            onStartRecording: recording ? null : () => starts++,
          ),
        );
        await tester.pumpWidget(view(false, []));
        final canvas = find.byType(GestureCanvas);
        final node = tester.getSemantics(canvas);
        final id = node.id;
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isTrue,
        );
        var children = 0;
        node.visitChildren((child) {
          children++;
          return true;
        });
        expect(children, 0);
        await tester.drag(canvas, const Offset(40, 10));
        expect(starts, 0);
        await tester.tap(canvas);
        expect(starts, 1);
        expect(tester.widget<GestureCanvas>(canvas).strokes, isEmpty);
        for (final recording in [true, false, true, false]) {
          await tester.pumpWidget(
            view(
              recording,
              recording
                  ? []
                  : [
                      [const Point2(.2, .4)],
                    ],
            ),
          );
          expect(tester.getSemantics(canvas).id, id);
          expect(
            tester.getSemantics(canvas).getSemanticsData().value,
            recording ? '正在录制' : '已保留 1 条触摸轨迹',
          );
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}
