import '../models/config.dart';
import 'gesture.dart';

class RuleMatch {
  const RuleMatch({
    this.rule,
    this.distance = double.infinity,
    this.conflict = false,
  });
  final GestureRule? rule;
  final double distance;
  final bool conflict;
}

class RuleMatcher {
  RuleMatch match(
    GestureSample sample,
    List<GestureRule> rules,
    String application,
    AppSettings settings, {
    int? simultaneousFingers,
  }) {
    final candidates = rules
        .where(
          (r) =>
              r.enabled &&
              r.validation(settings.minimumFingers) == null &&
              r.template != null,
        )
        .toList();
    final recognizer = GestureRecognizer()..threshold = settings.threshold;
    for (final group in [
      candidates.where((r) => r.scope.matches(application)),
      candidates.where((r) => r.scope.isGlobal),
    ]) {
      GestureRule? best;
      var distance = double.infinity;
      var conflict = false;
      for (final rule in group) {
        final fingers = simultaneousFingers ?? sample.strokes.length;
        if (fingers < settings.minimumFingers ||
            (sample.isTap
                ? (fingers != sample.strokes.length ||
                      fingers != rule.recordedFingers)
                : false)) {
          continue;
        }
        final result = recognizer.recognize(sample, [rule.template!]);
        if (!result.accepted) continue;
        final score = result.distance;
        if ((score - distance).abs() <= 1e-6) {
          conflict = true;
        } else if (score < distance) {
          best = rule;
          distance = score;
          conflict = false;
        }
      }
      if (best != null) {
        return RuleMatch(
          rule: conflict ? null : best,
          distance: distance,
          conflict: conflict,
        );
      }
    }
    return const RuleMatch();
  }
}
