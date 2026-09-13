import 'package:fluent_ui/fluent_ui.dart';

/// Wait for the dialog's overlay to leave before changing the underlying page.
/// Navigator.push completes at pop, while the reverse transition still owns
/// semantics nodes. Replacing an editor in that interval can leave Windows
/// with updates for nodes whose parents have already been removed.
Future<T?> showAppDialog<T extends Object?>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissWithEsc = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = FluentDialogRoute<T>(
    context: context,
    builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: false,
    dismissWithEsc: dismissWithEsc,
    transitionDuration: FluentTheme.of(context).fastAnimationDuration,
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  // Publish the restored page's semantics before callers replace that page.
  // Overlay disposal and the corresponding AXTree update are separate steps.
  await WidgetsBinding.instance.endOfFrame;
  return result;
}
