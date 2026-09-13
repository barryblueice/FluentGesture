import 'package:flutter/material.dart';
import '../engine/gesture.dart';

/// Displays touchpad frames without accepting mouse or touchscreen strokes.
class GestureCanvas extends StatelessWidget {
  const GestureCanvas({
    super.key,
    required this.strokes,
    required this.paused,
    required this.recording,
  });

  final List<List<Point2>> strokes;
  final bool paused;
  final bool recording;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '触摸板实时轨迹画布，仅用于显示',
        child: IgnorePointer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 360,
              width: double.infinity,
              child: ColoredBox(
                color: const Color(0xfff7f9fd),
                child: Stack(children: [
                  Positioned.fill(
                      child: CustomPaint(
                          painter: TracePainter(strokes, grid: true))),
                  if (strokes.isEmpty)
                    Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(paused ? Icons.pause_circle_outline : Icons.gesture,
                          size: 56,
                          color: const Color(0xff2563eb).withAlpha(64)),
                      const SizedBox(height: 14),
                      Text(
                          paused
                              ? '手势采集已暂停'
                              : recording
                                  ? '请在触摸板上完成手势'
                                  : '等待触摸板手势',
                          style: const TextStyle(color: Color(0xff718096))),
                      const SizedBox(height: 8),
                      const Text('轨迹将在这里显示 · Space 清空',
                          style: TextStyle(
                              color: Color(0xff718096), fontSize: 11)),
                    ])),
                  Positioned(
                      top: 12,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                            color: Colors.white.withAlpha(230),
                            borderRadius: BorderRadius.circular(7)),
                        child: Text(
                            paused
                                ? '●  已暂停'
                                : recording
                                    ? '●  正在录制'
                                    : '●  触摸板实时轨迹',
                            style: TextStyle(
                                color: recording
                                    ? Colors.red
                                    : const Color(0xff2563eb),
                                fontSize: 10,
                                fontWeight: FontWeight.w600)),
                      )),
                ]),
              ),
            ),
          ),
        ),
      );
}

class TracePainter extends CustomPainter {
  TracePainter(this.strokes, {this.grid = false});
  final List<List<Point2>> strokes;
  final bool grid;
  static const _colors = [
    Color(0xff2563eb),
    Color(0xff0d9488),
    Color(0xff8b5cf6),
    Color(0xffea580c),
    Color(0xffdb2777)
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (grid) {
      final dot = Paint()..color = const Color(0xffdce4f1);
      for (var x = 16.0; x < size.width; x += 24) {
        for (var y = 16.0; y < size.height; y += 24) {
          canvas.drawCircle(Offset(x, y), 0.8, dot);
        }
      }
    }
    for (var i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      if (stroke.isEmpty) continue;
      Offset position(Point2 p) => Offset(p.x * size.width, p.y * size.height);
      final path = Path()
        ..moveTo(position(stroke.first).dx, position(stroke.first).dy);
      for (final point in stroke.skip(1)) {
        path.lineTo(position(point).dx, position(point).dy);
      }
      final color = _colors[i % _colors.length];
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = grid ? 3 : 2
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
      canvas.drawCircle(position(stroke.first), grid ? 4 : 2,
          Paint()..color = color.withAlpha(128));
      if (grid) {
        canvas.drawCircle(
            position(stroke.last), 8, Paint()..color = color.withAlpha(31));
        canvas.drawCircle(position(stroke.last), 3, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant TracePainter oldDelegate) => true;
}
