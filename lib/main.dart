import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'data/gesture_store.dart';
import 'engine/gesture.dart';
import 'studio_controller.dart';
import 'widgets/gesture_canvas.dart';

void main() => runApp(const FluentGestureApp());

const accent = Color(0xff2563eb);
const ink = Color(0xff17243b);
const muted = Color(0xff718096);

class FluentGestureApp extends StatelessWidget {
  const FluentGestureApp({super.key, this.store});
  final GestureStore? store;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'FluentGesture',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: accent,
          scaffoldBackgroundColor: const Color(0xfff3f6fb),
          fontFamily: 'Microsoft YaHei',
          textTheme: const TextTheme(bodyMedium: TextStyle(color: ink)),
          inputDecorationTheme:
              const InputDecorationTheme(border: OutlineInputBorder()),
        ),
        home: StudioPage(store: store ?? GestureStore.local()),
      );
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key, required this.store});
  final GestureStore store;
  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> with WidgetsBindingObserver {
  late final StudioController studio;
  bool dialogOpen = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    studio = StudioController(widget.store)..initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      studio.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    studio.dispose();
    super.dispose();
  }

  Future<void> nameDialog([GestureTemplate? template]) async {
    if (!studio.ready || studio.busy || dialogOpen) return;
    dialogOpen = true;
    studio.inputSuspended = true;
    studio.capture.reset();
    final controller = TextEditingController(text: template?.name ?? '');
    final key = GlobalKey<FormState>();
    final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(template == null ? '录制新手势' : '重命名手势'),
              content: SizedBox(
                  width: 360,
                  child: Form(
                      key: key,
                      child: TextFormField(
                        controller: controller,
                        autofocus: true,
                        maxLength: 60,
                        decoration: const InputDecoration(
                            labelText: '手势名称', hintText: '例如：向右滑动、画一个圆'),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return '请输入名称';
                          }
                          if (studio.templates.any(
                              (t) => t != template && t.name == value.trim())) {
                            return '这个名称已存在';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) {
                          if (key.currentState!.validate()) {
                            Navigator.pop(context, controller.text.trim());
                          }
                        },
                      ))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () {
                      if (key.currentState!.validate()) {
                        Navigator.pop(context, controller.text.trim());
                      }
                    },
                    child: Text(template == null ? '开始录制' : '保存'))
              ],
            ));
    // Wait for dialog route disposal before disposing its text controller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    dialogOpen = false;
    studio.inputSuspended = false;
    if (!mounted || name == null) return;
    if (template == null) {
      studio.arm(name);
    } else {
      await studio.rename(template, name);
    }
  }

  Future<void> deleteDialog(GestureTemplate template) async {
    dialogOpen = true;
    studio.inputSuspended = true;
    studio.clear();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('删除手势'),
              content: Text('删除“${template.name}”的录制模板？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除'))
              ],
            ));
    dialogOpen = false;
    studio.inputSuspended = false;
    if (mounted && confirmed == true) await studio.delete(template);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: studio,
      builder: (context, _) => CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyR): () {
                  if (!dialogOpen && studio.recordingName == null) nameDialog();
                },
                const SingleActivator(LogicalKeyboardKey.space): () {
                  if (!dialogOpen) {
                    studio.clear();
                  }
                },
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  if (!dialogOpen) studio.cancelRecording();
                },
              },
              child: Focus(
                  autofocus: true,
                  child: Scaffold(
                    body: SafeArea(
                        child: LayoutBuilder(builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 1050;
                      return SingleChildScrollView(
                          padding: EdgeInsets.all(wide ? 32 : 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                        color: accent,
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                    child: const Icon(Icons.gesture_rounded,
                                        color: Colors.white, size: 28)),
                                const SizedBox(width: 14),
                                const Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('FluentGesture',
                                          style: TextStyle(
                                              fontSize: 23,
                                              fontWeight: FontWeight.w700,
                                              color: ink)),
                                      Text('让每一次滑动，都有意义',
                                          style: TextStyle(
                                              color: muted, fontSize: 12)),
                                    ])),
                                if (constraints.maxWidth > 600)
                                  const Chip(
                                      label: Text('手势工作室'),
                                      avatar: Icon(Icons.auto_awesome_outlined,
                                          size: 16)),
                              ]),
                              const SizedBox(height: 32),
                              const Text('手势工作台',
                                  style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                      color: ink)),
                              const SizedBox(height: 6),
                              const Text('在触摸板上操作，录制并识别你的专属手势。',
                                  style: TextStyle(color: muted)),
                              const SizedBox(height: 24),
                              Wrap(spacing: 12, runSpacing: 12, children: [
                                _metric(Icons.fingerprint, '当前触点',
                                    '${studio.capture.activeCount}'),
                                _metric(Icons.grid_view_rounded, '已存模板',
                                    '${studio.templates.length}'),
                                _metric(
                                    Icons.radar,
                                    '工作状态',
                                    studio.paused
                                        ? '已暂停'
                                        : studio.recordingName != null
                                            ? '录制中'
                                            : '识别中'),
                              ]),
                              const SizedBox(height: 22),
                              if (wide)
                                Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: _workspace()),
                                      const SizedBox(width: 22),
                                      SizedBox(width: 320, child: _sidebar())
                                    ])
                              else ...[
                                _workspace(),
                                const SizedBox(height: 20),
                                _sidebar()
                              ],
                              const SizedBox(height: 20),
                              Text('本地存储 · ${studio.store.file.path}',
                                  style: const TextStyle(
                                      color: muted, fontSize: 11)),
                            ],
                          ));
                    })),
                  ))));

  Widget _metric(IconData icon, String label, String value) => Container(
        width: 190,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xffe4eaf3))),
        child: Row(children: [
          Icon(icon, color: accent, size: 23),
          const SizedBox(width: 14),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: muted, fontSize: 11)),
            Text(value,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 19))
          ])
        ]),
      );

  Widget _panel(Widget child) => Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xffe4eaf3))),
      child: child);

  Widget _workspace() => _panel(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.touch_app_outlined, color: accent),
            SizedBox(width: 10),
            Text('触摸板手势',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 16),
          Text(studio.deviceStatus,
              style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 10),
          const Text('保持窗口在前台，在触摸板上滑动手指。抬起所有手指后，自动完成录制或识别。',
              style: TextStyle(color: muted, fontSize: 13, height: 1.7)),
          const SizedBox(height: 16),
          GestureCanvas(
              strokes: studio.visibleStrokes,
              paused: studio.paused,
              recording: studio.recordingName != null),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.icon(
                onPressed: studio.ready &&
                        !studio.busy &&
                        (studio.templates.length < 200 ||
                            studio.recordingName != null)
                    ? () {
                        if (studio.recordingName == null) {
                          nameDialog();
                        } else {
                          studio.cancelRecording();
                        }
                      }
                    : null,
                icon: Icon(
                    studio.recordingName == null
                        ? Icons.add
                        : Icons.stop_circle_outlined,
                    size: 18),
                label: Text(studio.recordingName == null ? '录制手势  R' : '取消录制')),
            OutlinedButton.icon(
                onPressed: studio.clear,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('清空')),
            TextButton.icon(
                onPressed: studio.togglePause,
                icon: Icon(studio.paused ? Icons.play_arrow : Icons.pause,
                    size: 18),
                label: Text(studio.paused ? '继续' : '暂停')),
          ]),
          const SizedBox(height: 16),
          Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: accent.withAlpha(13),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(studio.busy ? '正在保存模板…' : studio.message,
                  style: const TextStyle(
                      color: accent, fontSize: 12, height: 1.6))),
        ],
      ));

  Widget _sidebar() => Column(children: [
        _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('识别结果',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          Text(
              studio.result == null
                  ? '等待一个手势'
                  : studio.result!.accepted
                      ? studio.result!.name!
                      : '未知手势',
              style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                  color: studio.result?.accepted == true ? accent : ink)),
          const SizedBox(height: 8),
          Text(
              studio.result?.name == null
                  ? '触摸板手势完成后，在这里查看匹配结果。'
                  : '最近模板：${studio.result!.name}\n相似度 ${(studio.result!.similarity * 100).toStringAsFixed(1)}% · 距离 ${studio.result!.distance.toStringAsFixed(3)}',
              style: const TextStyle(color: muted, fontSize: 12, height: 1.7)),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('匹配容差', style: TextStyle(fontSize: 12))),
            Text(studio.recognizer.threshold.toStringAsFixed(2),
                style: const TextStyle(color: accent))
          ]),
          Slider(
              value: studio.recognizer.threshold,
              min: 0.05,
              max: 0.45,
              divisions: 40,
              onChanged: (v) =>
                  setState(() => studio.recognizer.threshold = v)),
          const Text('越小越严格；相似度是形状评分，并非概率。',
              style: TextStyle(color: muted, fontSize: 11)),
        ])),
        const SizedBox(height: 18),
        _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Text('我的手势',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            Text('${studio.templates.length} / 200',
                style: const TextStyle(color: muted, fontSize: 12))
          ]),
          const SizedBox(height: 16),
          if (studio.templates.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 25),
                child: Center(
                    child: Column(children: [
                  Icon(Icons.bookmarks_outlined, color: muted, size: 32),
                  SizedBox(height: 12),
                  Text('还没有录制模板', style: TextStyle(color: muted)),
                  SizedBox(height: 6),
                  Text('点击“录制手势”开始学习',
                      style: TextStyle(color: muted, fontSize: 11))
                ])))
          else
            ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: studio.templates.length,
                    separatorBuilder: (_, __) => const Divider(height: 16),
                    itemBuilder: (context, index) {
                      final template = studio.templates[index];
                      return Row(children: [
                        Container(
                            width: 46,
                            height: 46,
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                                color: const Color(0xfff0f5ff),
                                borderRadius: BorderRadius.circular(9)),
                            child: CustomPaint(
                                painter: TracePainter(template
                                    .normalized.strokes
                                    .map((s) => s
                                        .map((p) => Point2(
                                            p.x * 0.8 + 0.5, p.y * 0.8 + 0.5))
                                        .toList())
                                    .toList()))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(template.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                              Text('${template.sample.strokes.length} 条轨迹',
                                  style: const TextStyle(
                                      color: muted, fontSize: 11))
                            ])),
                        PopupMenuButton<String>(
                            enabled:
                                !studio.busy && studio.recordingName == null,
                            tooltip: '管理模板',
                            onSelected: (value) {
                              if (value == 'rename') {
                                nameDialog(template);
                              } else {
                                deleteDialog(template);
                              }
                            },
                            itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'rename', child: Text('重命名')),
                                  PopupMenuItem(
                                      value: 'delete', child: Text('删除'))
                                ]),
                      ]);
                    })),
        ])),
      ]);
}
