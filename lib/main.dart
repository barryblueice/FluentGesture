import 'dart:async';
import 'package:fluent_ui/fluent_ui.dart';
import 'data/config_store.dart';
import 'engine/gesture.dart';
import 'models/config.dart';
import 'platform/native_bridge.dart';
import 'services/gesture_runtime.dart';
import 'widgets/gesture_canvas.dart';
import 'widgets/shortcut_recorder.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_slider.dart';

void main() => runApp(const FluentGestureApp());

class FluentGestureApp extends StatefulWidget {
  const FluentGestureApp({super.key, this.store, this.bridge});
  final ConfigStore? store;
  final NativeBridge? bridge;
  @override
  State<FluentGestureApp> createState() => _FluentGestureAppState();
}

class _FluentGestureAppState extends State<FluentGestureApp> {
  late final RuleBook book;
  late final NativeBridge bridge;
  late final GestureRuntime runtime;
  @override
  void initState() {
    super.initState();
    book = RuleBook(widget.store ?? ConfigStore.local());
    bridge = widget.bridge ?? NativeBridge();
    runtime = GestureRuntime(book, bridge);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await book.load();
    if (!mounted) return;
    await runtime.initialize();
    if (!mounted || !book.ready) return;
    try {
      await bridge.setStartAtLogin(book.config.settings.startAtLogin);
    } catch (e) {
      if (mounted) {
        book.error = '登录启动设置未同步：$e';
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    runtime.dispose();
    book.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: book,
    builder: (context, _) => FluentApp(
      title: 'FluentGesture',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      theme: FluentThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xfff7f7f7),
        accentColor: Colors.blue,
        fontFamily: 'Microsoft YaHei',
      ),
      darkTheme: FluentThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff202020),
        accentColor: Colors.blue,
        fontFamily: 'Microsoft YaHei',
      ),
      themeMode: switch (book.config.settings.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: RuleWindow(book: book, runtime: runtime, bridge: bridge),
    ),
  );
}

class RuleWindow extends StatefulWidget {
  const RuleWindow({
    super.key,
    required this.book,
    required this.runtime,
    required this.bridge,
  });
  final RuleBook book;
  final GestureRuntime runtime;
  final NativeBridge bridge;
  @override
  State<RuleWindow> createState() => _RuleWindowState();
}

class _RuleWindowState extends State<RuleWindow> {
  String section = 'all', query = '';
  GestureRule? selected;
  bool _navigating = false;
  String? notice;
  final editorKey = GlobalKey<_RuleEditorState>();
  RuleBook get book => widget.book;
  GestureRuntime get runtime => widget.runtime;
  NativeBridge get bridge => widget.bridge;
  @override
  void initState() {
    super.initState();
    bridge.onCloseRequested = () => unawaited(_closeToTray());
    bridge.onOpenSettings = () => unawaited(_navigate('settings'));
    bridge.onExitRequested = () => unawaited(_exitApp());
  }

  @override
  void dispose() {
    bridge.onCloseRequested = null;
    bridge.onOpenSettings = null;
    bridge.onExitRequested = null;
    super.dispose();
  }

  Future<bool> _confirmDraft() async {
    if (editorKey.currentState?.dirty != true) return true;
    final choice = await showAppDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('保存修改？'),
        content: const Text('当前规则有未保存的修改。'),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('继续编辑'),
          ),
          Button(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'cancel') return false;
    return choice == 'discard' ||
        await editorKey.currentState!.save(notifyParent: false);
  }

  Future<void> _navigate(String target) async {
    if (_navigating) return;
    _navigating = true;
    try {
      if (!await _confirmDraft() || !mounted) return;
      setState(() {
        section = target;
        selected = null;
        notice = null;
      });
      await runtime.setMode(
        target == 'test' ? RuntimeMode.test : RuntimeMode.monitor,
      );
    } finally {
      _navigating = false;
    }
  }

  Future<void> _edit(GestureRule rule) async {
    if (!book.ready || book.saving || _navigating) return;
    _navigating = true;
    try {
      if (!await _confirmDraft() || !mounted) return;
      if (!await runtime.setMode(RuntimeMode.edit) || !mounted) return;
      // Dispose the previous editor even when a different rule is selected.
      setState(() {
        selected = null;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        setState(() {
          selected =
              book.config.rules.where((r) => r.id == rule.id).firstOrNull ??
              rule;
        });
      }
    } finally {
      _navigating = false;
    }
  }

  void _new() {
    if (book.config.rules.length >= 200) {
      setState(() {
        notice = '最多支持 200 条规则';
      });
      return;
    }
    _edit(
      GestureRule(
        id: newRuleId(),
        name: '',
        scope: ApplicationScope(
          section.startsWith('app:') ? section.substring(4) : '',
        ),
      ),
    );
  }

  Future<void> _finishEditor() async {
    if (!mounted) return;
    setState(() {
      selected = null;
      if (section.startsWith('app:') &&
          !applications.contains(section.substring(4))) {
        section = 'all';
      }
    });
    await runtime.setMode(RuntimeMode.monitor);
  }

  Future<void> _cancelEditor() async {
    if (await _confirmDraft()) await _finishEditor();
  }

  Future<void> _exitApp() async {
    if (_navigating || book.saving) return;
    _navigating = true;
    try {
      if (!await _confirmDraft() || !mounted) return;
      await bridge.quit();
    } catch (e) {
      if (mounted) setState(() => notice = '退出失败：$e');
    } finally {
      _navigating = false;
    }
  }

  Future<void> _closeToTray() async {
    if (_navigating) return;
    _navigating = true;
    try {
      if (!await _confirmDraft() || !mounted) return;
      if (!await runtime.setMode(RuntimeMode.monitor)) return;
      setState(() {
        selected = null;
        section = 'all';
      });
      await bridge.hide();
    } catch (e) {
      if (mounted) {
        setState(() {
          notice = '$e';
        });
      }
    } finally {
      _navigating = false;
    }
  }

  Future<void> _remove(GestureRule rule) async {
    if (!await _confirmDraft() || !mounted) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('删除规则'),
        content: Text('删除“${rule.name}”？'),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && await book.remove(rule.id)) await _finishEditor();
  }

  Future<void> _toggle(GestureRule rule, bool value) async {
    if (!await _confirmDraft() || !mounted) return;
    final current = book.config.rules.where((r) => r.id == rule.id).firstOrNull;
    if (current == null) return;
    await _finishEditor();
    await book.saveRule(current.copy(enabled: value));
  }

  Future<void> _settings(AppSettings settings) async {
    if (book.saving) return;
    final old = book.config.settings;
    try {
      if (settings.startAtLogin != old.startAtLogin) {
        await bridge.setStartAtLogin(settings.startAtLogin);
      }
      final success = await book.commit(
        AppConfig(rules: book.config.rules, settings: settings),
      );
      if (!success && settings.startAtLogin != old.startAtLogin) {
        await bridge.setStartAtLogin(old.startAtLogin);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          notice = '设置未保存：$e';
        });
      }
    }
  }

  List<String> get applications =>
      ({
          for (final rule in book.config.rules.where((r) => !r.scope.isGlobal))
            normalizeExe(rule.scope.executable): rule.scope.executable,
        }.values.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
  List<GestureRule> get rules => book.config.rules.where((r) {
    final matchesScope =
        section == 'all' ||
        (section == 'global' && r.scope.isGlobal) ||
        (section.startsWith('app:') && r.scope.matches(section.substring(4)));
    return matchesScope &&
        '${r.name} ${r.scope.label} ${r.action?.summary ?? ''}'
            .toLowerCase()
            .contains(query.toLowerCase());
  }).toList();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([book, runtime]),
    builder: (context, _) {
      final theme = FluentTheme.of(context);
      return ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 1040;
              final small = constraints.maxWidth < 760;
              return Column(
                children: [
                  if (book.error != null || notice != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: InfoBar(
                        title: Text(notice ?? book.error!),
                        severity: InfoBarSeverity.error,
                      ),
                    ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!small) SizedBox(width: 190, child: _navigation()),
                        if (!small) const Divider(direction: Axis.vertical),
                        Expanded(
                          child: Column(
                            children: [
                              if (small)
                                Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: ComboBox<String>(
                                    isExpanded: true,
                                    value: section,
                                    items: [
                                      const ComboBoxItem(
                                        value: 'all',
                                        child: Text('全部规则'),
                                      ),
                                      const ComboBoxItem(
                                        value: 'global',
                                        child: Text('全局规则'),
                                      ),
                                      ...applications.map(
                                        (p) => ComboBoxItem(
                                          value: 'app:$p',
                                          child: Text(
                                            ApplicationScope(p).label,
                                          ),
                                        ),
                                      ),
                                      const ComboBoxItem(
                                        value: 'test',
                                        child: Text('录制与测试'),
                                      ),
                                      const ComboBoxItem(
                                        value: 'settings',
                                        child: Text('设置'),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value != null) _navigate(value);
                                    },
                                  ),
                                ),
                              Expanded(
                                child: Semantics(
                                  key: ValueKey(
                                    section == 'settings' || section == 'test'
                                        ? section
                                        : 'rules',
                                  ),
                                  container: true,
                                  explicitChildNodes: true,
                                  child: section == 'settings'
                                      ? _settingsPage()
                                      : section == 'test'
                                      ? _testPage()
                                      : narrow && selected != null
                                      ? _editor()
                                      : Row(
                                          children: [
                                            Expanded(
                                              flex: 5,
                                              child: _ruleList(),
                                            ),
                                            if (!narrow) ...[
                                              const Divider(
                                                direction: Axis.vertical,
                                              ),
                                              Expanded(
                                                flex: 6,
                                                child: selected == null
                                                    ? const Center(
                                                        child: Text(
                                                          '选择规则进行编辑，或新建规则',
                                                        ),
                                                      )
                                                    : _editor(),
                                              ),
                                            ],
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );

  Widget _navigation() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(10, 0, 8, 20),
          child: Text(
            'FluentGesture',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
          ),
        ),
        _navItem('all', '全部规则', FluentIcons.list),
        _navItem('global', '全局规则', FluentIcons.globe),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 20, 8, 8),
          child: Text('应用', style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: ListView(
            children: applications
                .map(
                  (p) => _navItem(
                    'app:$p',
                    ApplicationScope(p).label,
                    FluentIcons.app_icon_default,
                  ),
                )
                .toList(),
          ),
        ),
        const Divider(),
        const SizedBox(height: 8),
        _navItem('test', '录制与测试', FluentIcons.touch),
        _navItem('settings', '设置', FluentIcons.settings),
      ],
    ),
  );
  Widget _navItem(String key, String title, IconData icon) =>
      ListTile.selectable(
        leading: Icon(icon, size: 16),
        title: Text(title, overflow: TextOverflow.ellipsis),
        selected: section == key,
        onPressed: () => _navigate(key),
        onSelectionChange: (_) => _navigate(key),
      );

  Widget _ruleList() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    section == 'all'
                        ? '全部规则'
                        : section == 'global'
                        ? '全局规则'
                        : ApplicationScope(section.substring(4)).label,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: book.ready && !book.saving ? _new : null,
                  child: const Text('新建规则'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextBox(
              placeholder: '搜索名称、应用或动作',
              onChanged: (value) => setState(() {
                query = value;
              }),
            ),
          ],
        ),
      ),
      if (book.store.migrated)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: InfoBar(
            title: Text('配置已更新'),
            content: Text('已保留迁移前备份。请检查规则，未配置完成的规则需录制手势并绑定动作。'),
          ),
        ),
      Expanded(
        child: !book.ready && book.error == null
            ? const Center(child: ProgressRing())
            : rules.isEmpty
            ? const Center(child: Text('暂无规则，点击“新建规则”开始配置'))
            : ListView.builder(
                itemCount: rules.length,
                itemBuilder: (context, index) {
                  final rule = rules[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: ListTile.selectable(
                      selected: selected?.id == rule.id,
                      onPressed: () => _edit(rule),
                      onSelectionChange: (_) => _edit(rule),
                      leading: SizedBox(
                        width: 66,
                        child: Row(
                          children: [
                            Checkbox(
                              checked: rule.enabled,
                              onChanged: book.saving
                                  ? null
                                  : (value) => _toggle(rule, value ?? false),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: rule.template == null
                                  ? const Icon(FluentIcons.touch, size: 20)
                                  : CustomPaint(
                                      painter: TracePainter(
                                        rule.template!.normalized.strokes
                                            .map(
                                              (s) => s
                                                  .map(
                                                    (p) => Point2(
                                                      p.x * .8 + .5,
                                                      p.y * .8 + .5,
                                                    ),
                                                  )
                                                  .toList(),
                                            )
                                            .toList(),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                      title: Text(rule.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${rule.scope.label} · ${rule.recordedFingers == 0 ? '待重新录制' : '${rule.recordedFingers} 指'}\n${rule.action?.summary ?? '未配置动作'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: DropDownButton(
                        key: ValueKey('rule-menu-${rule.id}'),
                        leading: const Icon(FluentIcons.more, size: 15),
                        items: [
                          MenuFlyoutItem(
                            text: const Text('复制'),
                            onPressed: () => _edit(
                              rule.copy(
                                id: newRuleId(),
                                name: '${rule.name} 副本',
                                enabled: false,
                              ),
                            ),
                          ),
                          MenuFlyoutItem(
                            text: const Text('删除'),
                            onPressed: () => _remove(rule),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '${rules.length} 条规则',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    ],
  );

  Widget _editor() => RuleEditor(
    key: editorKey,
    rule: selected!,
    book: book,
    runtime: runtime,
    bridge: bridge,
    onSaved: _finishEditor,
    onCancel: _cancelEditor,
  );

  Widget _testPage() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '录制与测试',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text('在触摸板上完成手势。此页面只显示匹配结果，不执行动作。'),
            const SizedBox(height: 18),
            InfoLabel(
              label: '模拟适用应用',
              child: ComboBox<String>(
                isExpanded: true,
                value: runtime.testApplication,
                items: [
                  const ComboBoxItem(value: '', child: Text('仅全局规则')),
                  ...applications.map(
                    (p) => ComboBoxItem(value: p, child: Text(p)),
                  ),
                ],
                onChanged: (value) => setState(() {
                  runtime.testApplication = value ?? '';
                  runtime.clear();
                }),
              ),
            ),
            const SizedBox(height: 16),
            GestureCanvas(
              strokes: runtime.strokes,
              paused: false,
              recording: true,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Button(onPressed: runtime.clear, child: const Text('清空')),
                const SizedBox(width: 14),
                Text('当前触点：${runtime.capture.activeCount}'),
              ],
            ),
            const SizedBox(height: 16),
            Text(runtime.message),
            if (runtime.lastMatch?.distance.isFinite == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '匹配距离：${runtime.lastMatch!.distance.toStringAsFixed(3)}',
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _settingsPage() {
    final settings = book.config.settings;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '设置',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              InfoLabel(
                label: '录制手势的最少手指数（点触和滑动）',
                child: ComboBox<int>(
                  value: settings.minimumFingers,
                  items: [2, 3, 4, 5]
                      .map(
                        (v) => ComboBoxItem(value: v, child: Text('$v 指及以上')),
                      )
                      .toList(),
                  onChanged: book.saving
                      ? null
                      : (value) {
                          if (value != null) {
                            _settings(settings.copy(minimumFingers: value));
                          }
                        },
                ),
              ),
              const SizedBox(height: 18),
              InfoLabel(
                label: '匹配容差（越小越严格）',
                child: Row(
                  children: [
                    Expanded(
                      child: AppSlider(
                        value: settings.threshold,
                        min: .05,
                        max: .45,
                        divisions: 40,
                        onChanged: book.saving
                            ? null
                            : (v) => _settings(settings.copy(threshold: v)),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(settings.threshold.toStringAsFixed(2)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              InfoLabel(
                label: '外观',
                child: ComboBox<String>(
                  value: settings.theme,
                  items: const [
                    ComboBoxItem(value: 'system', child: Text('跟随系统')),
                    ComboBoxItem(value: 'light', child: Text('浅色')),
                    ComboBoxItem(value: 'dark', child: Text('深色')),
                  ],
                  onChanged: book.saving
                      ? null
                      : (v) {
                          if (v != null) {
                            _settings(settings.copy(theme: v));
                          }
                        },
                ),
              ),
              const SizedBox(height: 18),
              ToggleSwitch(
                checked: settings.startAtLogin,
                content: const Text('登录 Windows 后启动并驻留托盘'),
                onChanged: book.saving
                    ? null
                    : (value) => _settings(settings.copy(startAtLogin: value)),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 18),
              const Text(
                'Windows 系统手势',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '本软件不独占触摸板。双指滚动和缩放仍会交给系统处理，可能与自定义动作同时发生。使用三指或四指手势前，可在 Windows 设置中将对应的滑动和点击操作设为“无”。',
                style: TextStyle(height: 1.6),
              ),
              const SizedBox(height: 12),
              Button(
                onPressed: () async {
                  try {
                    await bridge.openTouchpadSettings();
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        notice = '$e';
                      });
                    }
                  }
                },
                child: const Text('打开 Windows 触摸板设置'),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 18),
              Button(
                onPressed: _exitApp,
                child: const Text('退出 FluentGesture'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RuleEditor extends StatefulWidget {
  const RuleEditor({
    super.key,
    required this.rule,
    required this.book,
    required this.runtime,
    required this.bridge,
    required this.onSaved,
    required this.onCancel,
  });
  final GestureRule rule;
  final RuleBook book;
  final GestureRuntime runtime;
  final NativeBridge bridge;
  final Future<void> Function() onSaved, onCancel;
  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  late final TextEditingController name,
      application,
      program,
      arguments,
      directory;
  late ActionKind kind;
  late List<int> keys;
  late int volumeStep, scrollStep;
  late bool enabled, appSpecific;
  bool dirty = false;
  bool sampleCleared = false;
  String? error;
  GestureRuntime get runtime => widget.runtime;
  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    name = TextEditingController(text: rule.name);
    application = TextEditingController(text: rule.scope.executable);
    program = TextEditingController(text: rule.action?.program ?? '');
    arguments = TextEditingController(text: rule.action?.arguments ?? '');
    directory = TextEditingController(text: rule.action?.directory ?? '');
    kind = rule.action?.kind ?? ActionKind.shortcut;
    keys = List.of(rule.action?.keys ?? []);
    volumeStep = rule.action?.volumeStep ?? 10;
    scrollStep = rule.action?.scrollStep ?? 3;
    enabled =
        rule.enabled ||
        (rule.name.isEmpty &&
            !widget.book.config.rules.any((r) => r.id == rule.id));
    appSpecific = !rule.scope.isGlobal;
    for (final controller in [
      name,
      application,
      program,
      arguments,
      directory,
    ]) {
      controller.addListener(_changed);
    }
    runtime.addListener(_recorded);
  }

  void _changed() {
    if (mounted) {
      setState(() {
        dirty = true;
      });
    }
  }

  void _recorded() {
    if (runtime.recording.sample != null && mounted) {
      setState(() {
        dirty = true;
      });
    }
  }

  @override
  void dispose() {
    runtime.removeListener(_recorded);
    for (final c in [name, application, program, arguments, directory]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<bool> save({bool notifyParent = true}) async {
    if (widget.book.saving) return false;
    if (runtime.recording.armed) {
      setState(() => error = '请完成录制，或先取消录制');
      return false;
    }
    final action = GestureAction(
      kind,
      keys: List.unmodifiable(keys),
      program: program.text.trim(),
      arguments: arguments.text,
      directory: directory.text.trim(),
      volumeStep: volumeStep,
      scrollStep: scrollStep,
    );
    final rule = GestureRule(
      id: widget.rule.id,
      name: name.text.trim(),
      scope: ApplicationScope(appSpecific ? application.text.trim() : ''),
      sample:
          runtime.recording.sample ??
          (sampleCleared ? null : widget.rule.sample),
      recordedFingers: runtime.recording.sample == null
          ? (sampleCleared ? 0 : widget.rule.recordedFingers)
          : runtime.recording.fingers,
      action: action.error == null ? action : null,
      enabled: enabled,
    );
    final issue = rule.validation(widget.book.config.settings.minimumFingers);
    if (issue != null || (enabled && action.error != null)) {
      setState(() {
        error = issue ?? action.error;
      });
      return false;
    }
    if (!await widget.book.saveRule(rule)) {
      if (mounted) {
        setState(() {
          error = widget.book.error;
        });
      }
      return false;
    }
    dirty = false;
    if (notifyParent) await widget.onSaved();
    return true;
  }

  Future<void> _pick(TextEditingController controller) async {
    try {
      final value = await widget.bridge.pickProgram();
      if (mounted && value != null) controller.text = value;
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    }
  }

  Future<void> _running() async {
    try {
      final apps = await widget.bridge.applications();
      if (!mounted) return;
      final value = await showAppDialog<String>(
        context: context,
        builder: (context) => ContentDialog(
          title: const Text('选择运行中的应用'),
          content: SizedBox(
            height: 340,
            child: apps.isEmpty
                ? const Text('没有可选应用')
                : ListView(
                    children: apps
                        .map(
                          (a) => ListTile(
                            title: Text(
                              a.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              a.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () => Navigator.pop(context, a.path),
                          ),
                        )
                        .toList(),
                  ),
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (mounted && value != null) application.text = value;
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    }
  }

  Future<void> _recordShortcut() async {
    final recorded = await showShortcutRecorder(context, bridge: widget.bridge);
    if (!mounted || recorded == null) return;
    setState(() {
      keys = recorded;
      dirty = true;
    });
  }

  void _beginRecording() {
    if (runtime.recording.armed) return;
    runtime.armRecording();
    setState(() => dirty = true);
  }

  @override
  Widget build(BuildContext context) {
    final recorded =
        runtime.recording.sample ?? (sampleCleared ? null : widget.rule.sample);
    final fingers = runtime.recording.sample == null
        ? (sampleCleared ? 0 : widget.rule.recordedFingers)
        : runtime.recording.fingers;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.book.config.rules.any((r) => r.id == widget.rule.id)
                      ? '编辑规则'
                      : '新建规则',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
              ),
              if (dirty) const Text('未保存', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: InfoBar(
                      title: Text(error!),
                      severity: InfoBarSeverity.error,
                    ),
                  ),
                InfoLabel(
                  label: '名称',
                  child: TextBox(
                    key: const Key('rule-name'),
                    controller: name,
                    maxLength: 60,
                    placeholder: '例如：关闭标签页',
                  ),
                ),
                const SizedBox(height: 14),
                InfoLabel(
                  label: '适用范围',
                  child: ComboBox<bool>(
                    isExpanded: true,
                    value: appSpecific,
                    items: const [
                      ComboBoxItem(value: false, child: Text('全局')),
                      ComboBoxItem(value: true, child: Text('指定应用')),
                    ],
                    onChanged: (value) => setState(() {
                      appSpecific = value ?? false;
                      dirty = true;
                    }),
                  ),
                ),
                if (appSpecific) ...[
                  const SizedBox(height: 10),
                  TextBox(
                    key: const Key('rule-application'),
                    controller: application,
                    placeholder: '应用程序完整路径',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Button(
                        onPressed: () => _pick(application),
                        child: const Text('浏览文件'),
                      ),
                      Button(onPressed: _running, child: const Text('运行中的应用')),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '手势',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      fingers == 0
                          ? (recorded == null ? '尚未录制' : '旧模板，需重新录制')
                          : '$fingers 指${recorded?.isTap == true ? '点触' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                GestureCanvas(
                  onStartRecording: !runtime.recording.armed
                      ? _beginRecording
                      : null,
                  height: 200,
                  strokes: (runtime.recording.armed || runtime.capture.hasInput
                      ? runtime.strokes
                      : recorded?.strokes ?? []),
                  paused: false,
                  recording: runtime.recording.armed,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Button(
                      onPressed: _beginRecording,
                      child: Text(recorded == null ? '录制手势' : '重新录制'),
                    ),
                    Button(
                      onPressed: () {
                        runtime.recording.reset();
                        runtime.clear();
                        setState(() {
                          sampleCleared = true;
                          dirty = true;
                        });
                      },
                      child: const Text('清空'),
                    ),
                    if (runtime.recording.armed)
                      Button(
                        onPressed: () {
                          runtime.recording.armed = false;
                          runtime.clear();
                        },
                        child: const Text('取消录制'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(runtime.message, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 18),
                InfoLabel(
                  label: '动作',
                  child: ComboBox<ActionKind>(
                    isExpanded: true,
                    value: kind,
                    items: ActionKind.values
                        .map(
                          (k) => ComboBoxItem(
                            value: k,
                            child: Text(actionLabels[k]!),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() {
                      kind = value!;
                      dirty = true;
                    }),
                  ),
                ),
                const SizedBox(height: 10),
                if (kind == ActionKind.shortcut)
                  Button(
                    onPressed: _recordShortcut,
                    child: Text(
                      keys.isEmpty ? '录入快捷键' : keys.map(keyName).join(' + '),
                    ),
                  ),
                if (kind == ActionKind.launch) ...[
                  InfoLabel(
                    label: '程序',
                    child: TextBox(
                      key: const Key('action-program'),
                      controller: program,
                      placeholder: r'C:\Path\Application.exe',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Button(
                    onPressed: () => _pick(program),
                    child: const Text('选择程序'),
                  ),
                  const SizedBox(height: 10),
                  InfoLabel(
                    label: '参数',
                    child: TextBox(
                      key: const Key('action-arguments'),
                      controller: arguments,
                    ),
                  ),
                  const SizedBox(height: 10),
                  InfoLabel(
                    label: '工作目录（可留空）',
                    child: TextBox(
                      key: const Key('action-directory'),
                      controller: directory,
                    ),
                  ),
                ],
                if (kind == ActionKind.volumeUp ||
                    kind == ActionKind.volumeDown)
                  InfoLabel(
                    label: '音量步长',
                    child: Row(
                      children: [
                        Expanded(
                          child: AppSlider(
                            value: volumeStep.toDouble(),
                            min: 1,
                            max: 100,
                            divisions: 99,
                            onChanged: (v) => setState(() {
                              volumeStep = v.round();
                              dirty = true;
                            }),
                          ),
                        ),
                        Text('$volumeStep%'),
                      ],
                    ),
                  ),
                if ([
                  ActionKind.scrollLeft,
                  ActionKind.scrollRight,
                  ActionKind.scrollUp,
                  ActionKind.scrollDown,
                ].contains(kind))
                  InfoLabel(
                    label: '每次滚动量（格，作用于指针所在的目标窗口区域）',
                    child: Row(
                      children: [
                        Expanded(
                          child: AppSlider(
                            value: scrollStep.toDouble(),
                            min: 1,
                            max: 20,
                            divisions: 19,
                            onChanged: (v) => setState(() {
                              scrollStep = v.round();
                              dirty = true;
                            }),
                          ),
                        ),
                        Text('$scrollStep'),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                ToggleSwitch(
                  checked: enabled,
                  content: const Text('启用此规则'),
                  onChanged: (v) => setState(() {
                    enabled = v;
                    dirty = true;
                  }),
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Button(
                onPressed: widget.book.saving ? null : widget.onCancel,
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: widget.book.saving ? null : () => save(),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
